# Implementation Prompt: In-Flash Computing Emulation on **SwarmIO** (IOPS-scalable NVMeVirt)

> **Use this file as the task specification.** It supersedes the NVMeVirt-based
> `INFLASH_COMPUTE_EMULATION_PROMPT.md` for the *frontend-scalability* regime. It is
> self-contained: goal, the analytic model, why we switched to SwarmIO, the verified
> SwarmIO internals (with file/line refs), the exact implementation tasks (the main one is
> *porting SwarmIO to run without Intel DSA on this consumer CPU*), the experiment plan,
> and the report to produce.

---

## 0. One-paragraph summary

We want to **validate an analytic latency model of in-flash computing** by emulating it on
a **software-defined virtual NVMe device** driven by a host benchmark, and comparing the
model against the emulator's end-to-end latency **as a function of the number of
concurrent requests**. Our first attempt used stock **NVMeVirt** with a "1 request = 1
plane" mapping (the `INFLASH_PIM` profile). It worked functionally but **refuted the
model's convergence hypothesis for a structural reason**: NVMeVirt has a **single
dispatcher thread** that serializes command *issue* at ~1 µs/command, so a 512-request
parallel "round" took ~557 µs instead of the modeled ~38 µs (see §1.2 for the data).
**SwarmIO** (a drop-in successor to NVMeVirt, in `./SwarmIO/`) was built specifically to
remove this frontend bottleneck via a **distributed multi-dispatcher architecture**,
reaching tens of MIOPS. This prompt re-runs the same in-flash-compute experiment on
SwarmIO so the scalable frontend can actually present the parallel round to the device,
letting us test whether the emulated latency now **converges to the analytic model**.

---

## 1. Why switch to SwarmIO

### 1.1 The bottleneck we hit on NVMeVirt (measured)

With the `INFLASH_PIM` profile (16 ch × 32 LUNs = 512 LUNs, tR=30 µs, compute read path
that omits page-data transfer) and an io_uring host issuing `N` concurrent 4 KB reads
striped across all 512 LUNs, we measured (median end-to-end, host wall-clock):

| N (qdepth=N) | NVMeVirt e2e | `T_model = 38µs·⌈N/512⌉` | rel err |
|--------------|--------------|--------------------------|---------|
| 1            | ~36 µs       | 38 µs                    | ~−5 %   |
| 4            | ~40 µs       | 38 µs                    | +4 %    |
| 8            | ~45 µs       | 38 µs                    | +17 %   |
| 64           | ~116 µs      | 38 µs                    | +206 %  |
| 512          | ~557 µs      | 38 µs                    | +1366 % |
| 4096         | ~4240 µs     | 304 µs                   | +1295 % |

Shape: `e2e(N) ≈ 30 µs floor + N × ~1.0 µs`. The single sanity checks pass (1 req ≈ tR;
2 reads to the **same** LUN ≈ 2·tR ≈ 67 µs), so the per-plane timeline is correct. The
divergence is **not** a timing-model error — it is NVMeVirt's **single dispatcher** (one
thread polling all SQ doorbells, fetching one SQ's commands before moving on) serializing
command issue. With "1 request = 1 plane," you cannot present 512 plane-commands to the
device as one parallel round, so latency grows linearly with N.

### 1.2 What SwarmIO fixes (confirmed from the paper, §III–IV)

SwarmIO ("Towards 100 Million IOPS SSD Emulation", `SwarmIO/SwarmIO_paper.pdf`) identifies
*exactly* this problem (§III-A "Frontend Scalability Bottleneck": *"NVMeVirt relies on a
single dispatcher thread that sequentially polls the emulated doorbells of all SQs … thereby
serializing I/O request processing"*; Fig 3: NVMeVirt frontend plateaus at ~4.6 MIOPS). It
removes it with:

- **Distributed dispatch** — NVMe SQ/CQ pairs partitioned across multiple **service units**,
  each a dedicated dispatcher thread + worker(s). (§IV-B)
- **Coalesced request fetching** — one dispatcher fetches many SQ entries per transfer
  (sets the NVMe CQR bit). (§IV-B)
- **DSA-accelerated data copy** — offloads worker/dispatcher data movement to Intel DSA.
  (§IV-C) **← hardware-dependent; see §4.**
- **Aggregated timing-model updates** — amortizes the shared timing-model lock across a
  batch of requests. (§IV-D)

Result: up to **40 MIOPS** (≈300× NVMeVirt). Crucially for us, **CPU-centric** runs
(fio, no GPU) with distributed+coalesced dispatch reach **~6.5 MIOPS** even *without* DSA
(paper Fig 13a, D+C). The distributed frontend and the timing model are **independent of
DSA**; DSA only accelerates *data copy*, which **in-flash compute does not need** (we
return results, not page data). This is why SwarmIO is the right tool here.

---

## 2. The analytic model and how it maps onto SwarmIO

### 2.1 Model under test (unchanged)

- Each **plane** has its own compute unit; computation is hidden behind the next page read
  via double buffering. One "read-a-page-and-compute" round across **all planes in
  parallel** costs `t_round = tR + t_cmd = 30 µs + 8 µs = 38 µs`.
- With `P` rounds per plane and all 512 planes saturated in parallel:
  `T_model(end-to-end) = 38 µs · P`.
- For the request sweep with **1 request = 1 page = 1 plane**, perfectly balanced across
  512 planes: `T_model(N) = 38 µs · ⌈N / 512⌉`.

### 2.2 SwarmIO's timing model (verified — `src/simple_timing_model.c`)

SwarmIO replaced NVMeVirt's detailed per-channel/LUN NAND model with a **simple Tmax/Lmin
model** built on **scheduling instances** (the abstraction for parallel device units). In
`__sched_io_units()` ([simple_timing_model.c:16-88](SwarmIO/src/simple_timing_model.c#L16)):

```
unit_id   = (lba >> (io_unit_shift - LBA_BITS)) % num_sched_insts   // request → instance
io_stime  = max(inst[unit_id].t_next_available, nsecs_start)         // serialize per instance
io_etime  = io_stime + sched_delay                                   // instance occupied sched_delay
inst[unit_id].t_next_available = io_etime
nsecs_target = io_etime + min_delay                                  // + fixed latency floor
```

This is the **same structure** as NVMeVirt's per-LUN timeline, but with a single tunable
`sched_delay` (instance occupancy → throughput cap) and `min_delay` (latency floor):

- **Single request** → `nsecs_target = nsecs_start + sched_delay + min_delay`.
- **Two requests to the same instance** → second pays `2·sched_delay + min_delay`.
- **N requests to N distinct instances at the same time** → all complete in
  `sched_delay + min_delay` (fully parallel).
- Aggregate throughput cap `Tmax = num_sched_insts / sched_delay`.

### 2.3 Parameter mapping (this is the key calibration)

`scripts/load.sh` derives the module params from the config:

```
read_sched_delay = round(1000 / target_miops * num_sched_insts)   # ns
read_min_delay   = target_latency - read_sched_delay              # ns
io_unit_shift    = log2(block_size)                               # 12 for 4 KB
```

To emulate **512 planes, each round = 38 µs, rounds serialize per plane** (faithful to
`T_model = 38 µs · ⌈N/512⌉`):

- `num_sched_insts = 512`   (must be a power of two — 512 ✓; = our 512 planes)
- `block_size = 4096`       (→ `io_unit_shift = 12`; with `LBA_BITS=9`,
  `unit_id = (lba>>3) % 512 = lpn % 512` — consecutive LPNs stripe across all 512 instances,
  identical to the LUN-as-plane mapping)
- **`read_sched_delay = 38000`, `read_min_delay = 0`** → single req = 38 µs; 2 reqs/instance
  = 76 µs; `Tmax = 512 / 38 µs ≈ 13.5 MIOPS`.
  - Set these **directly** via `modprobe` (load.sh passes `read_min_delay`/`read_sched_delay`
    to modprobe at [load.sh:176-179](SwarmIO/scripts/load.sh#L176)). Do **not** rely on
    `target_latency`/`target_miops` rounding alone — at `target_miops≈13.47` the derived
    `read_min_delay` can round slightly **negative**. Either pass the two delays directly,
    or use `target_latency=38000` with `target_miops` chosen so `read_sched_delay ≤ 38000`
    (e.g. `13.5`) and clamp `read_min_delay` to ≥ 0.
- **Alternative split to also try (pipelined, compute-hidden):** `read_min_delay = 30000`
  (tR as a pipelined latency floor) + `read_sched_delay = 8000` (t_cmd as per-plane
  occupancy → `Tmax = 512/8 µs = 64 MIOPS`). Single req still 38 µs, but 2 reqs/instance =
  46 µs (only the 8 µs command serializes; tR pipelines). Report both and discuss which
  matches the double-buffering assumption better.

### 2.4 In-flash compute semantics = `skip_io`

In-flash compute returns only a tiny result, **not** the page. SwarmIO's build option
**`skip_io=1`** (`CONFIG_SWARMIO_WORKER_SKIP_IO`) makes workers **skip data movement
entirely**; the timing path then just returns `nsecs_start + min_delay`
([simple_timing_model.c:42](SwarmIO/src/simple_timing_model.c#L42),
[:313-318](SwarmIO/src/simple_timing_model.c#L313)). This is the faithful, DSA-free model
of compute, and it removes the only reason DSA existed. **Build with `skip_io=1`.**

> NOTE: with `skip_io=1` the `#ifndef CONFIG_SWARMIO_WORKER_SKIP_IO` block that consumes
> `sched_delay`/scheduling-instance state is compiled **out**, so `nsecs_target` becomes
> `nsecs_start + min_delay` with **no per-plane serialization**. That models infinite plane
> parallelism (every request = 38 µs regardless of N), which tests the *frontend* but not
> per-plane contention. **Decide explicitly (Task B):** if you want per-plane serialization
> preserved (2 reqs/plane = 76 µs), either (a) keep `skip_io=0` and instead disable DSA in
> the worker data path another way (Task A), or (b) modify the `skip_io` timing path to
> still run `__sched_io_units` (timing only, no copy). Recommended: **(b)** — a tiny edit so
> compute mode keeps the scheduling-instance timeline while skipping the data copy. This is
> the most faithful in-flash-compute model.

---

## 3. Verified SwarmIO internals (confirm before coding)

- **Architecture / entry**: `src/main.c`, `nvmev/nvme_vdev.{c,h}`, `src/dispatcher.c`,
  `src/worker.c`, `src/proc.c` (exposes `/proc/swarmio/stat`). Service units & params in
  [src/common.h:103-113](SwarmIO/src/common.h#L103) (`num_service_units`, `num_sched_insts`,
  `io_unit_shift`, `read_min_delay`, `read_sched_delay`).
- **Timing model**: `src/simple_timing_model.c` (per-request `simple_sched_nvme_cmd`, and
  aggregated `simple_sched_nvme_cmd_aggregated` under `CONFIG_SWARMIO_AGGREGATED_TIMING_UPDATE`).
- **DSA dependency (the porting problem)**: `dsa/dsa.c` **unconditionally**
  `#include <linux/idxd.h>` and `#include <idxd.h>` and uses private idxd internals
  (`struct idxd_device`, `confdev_to_idxd_dev`, `idxd->max_wqs`, `groups[i]->rdbufs_allowed`
  — [dsa/dsa.c:10-22,191-204](SwarmIO/dsa/dsa.c#L10)). `Kbuild` **always** compiles
  `dsa/*.o` and adds `-I.../drivers/dma/idxd`
  ([Kbuild:31-35](SwarmIO/Kbuild#L31)). The build configs `CONFIG_SWARMIO_DMA_DISPATCHER`/
  `CONFIG_SWARMIO_DMA_WORKER` default **y** ([Kbuild:16-17](SwarmIO/Kbuild#L16)). README
  §"Build dependencies" requires fetching idxd headers and notes idxd **symbol-export**
  requirements even on kernel 6.8.
- **Build/load/run scripts**: `scripts/build.sh` (`make install` with `skip_io`,
  `coalesce_sqe`, `use_disp_dma`, … flags), `scripts/load.sh` (`modprobe` with the params
  above; `--unload` to remove), `scripts/run_fio.sh` (fio randread sweep over io-depth ×
  num-threads, reads `/proc/swarmio/stat`). Default `cpus="48-95"`, `memmap 132G/124G` are
  for the paper's 86-core Xeon — **must be changed for this machine (§4).**

---

## 4. Environment constraints — THIS machine (verified)

- **CPU: 13th-Gen Intel Core i9-13900F** — a *consumer desktop* CPU. **No Intel DSA**
  (`/dev/dsa` absent, no `idxd` driver, DSA is Xeon-Scalable-only). idxd headers are **not**
  installed. ⇒ **SwarmIO cannot use DSA here and, as written, will not even build/load.**
- **Cores**: 32 logical CPUs = 8 P-cores (HT → 0–15) + 16 E-cores (16–31), 24 physical cores.
- **RAM**: ~94 GiB. **Reserved memmap regions already in the kernel cmdline**:
  `memmap=16G$64G` and `memmap=16G$96G`. Use **`memmap_start=96G memmap_size=16G`** for
  SwarmIO. `isolcpus` is **not** set (clean timing would want it — see Task D).
- **Currently loaded**: our `nvmev` (INFLASH_PIM) module with `/dev/nvme1n1`. **Unload it
  (`sudo rmmod nvmev`) before loading SwarmIO** — they contend for the device/memmap.
- **Host tooling**: `fio 3.28` present; `liburing-dev` installed; no SPDK; system
  `matplotlib`/`numpy` broken and no `pip3` (plotting must be fixed separately or use
  gnuplot/CSV). Passwordless `sudo` only inside a fresh `sudo -v` window — request the user
  for privileged steps (Slack `notify.sh` exists but webhook returned HTTP 000; surface
  inline).
- **Our io_uring host app** `host/inflash_bench.c` (4 KB O_DIRECT reads striped over LPNs,
  per-request + batch-e2e latency, CSV) **works unmodified against SwarmIO's block device**
  because SwarmIO's `unit_id = lpn % num_sched_insts` matches our striping. Reuse it for an
  apples-to-apples NVMeVirt-vs-SwarmIO comparison.

---

## 5. Implementation tasks (in order; keep authoring and verification separate passes)

### Task A — Port SwarmIO to build **and load** without DSA  *(the central task)*

Goal: a `swarmio.ko` that builds with no idxd headers and loads with **no unresolved idxd
symbols**, running the distributed frontend with CPU-side / skipped data movement.

1. **Gate DSA out of the build.** In `Kbuild`: make `dsa/*.o` and the
   `-I.../drivers/dma/idxd` include **conditional** on
   `CONFIG_SWARMIO_DMA_DISPATCHER`/`CONFIG_SWARMIO_DMA_WORKER` (i.e. compile `dsa/config.o
   dsa/dsa.o dsa/batch.o dsa/single.o` and add the idxd include **only** when either DMA
   config is `y`). Build with both **off** (`use_disp_dma=n use_worker_dma=n`).
2. **Stub the DSA call sites.** In `src/dispatcher.c` / `src/worker.c` (and anywhere
   `dsa/*.h` is used), confirm every DSA call is already under `#ifdef
   CONFIG_SWARMIO_DMA_DISPATCHER`/`_WORKER`; where not, guard it. When DMA is off, the
   dispatcher must fetch SQEs with plain CPU reads and workers must use CPU `memcpy` (or be
   skipped under `skip_io`). Verify `dsa_init`/config (`dsa/config.c`, `dsa/dsa.c`) is
   **never called** when both DMA flags are off.
3. **Build config for this machine** (build with `scripts/build.sh -i <conf> --clean`):
   - `skip_io = 1` (compute mode — but see §2.4 NOTE / Task B for keeping per-plane timing)
   - `coalesce_sqe = 1` (frontend scaling — keep)
   - `use_agg_timing_update = 1`, `use_cas_timing_update = 1` (scalable timing — keep)
   - `use_disp_dma = 0`, `use_worker_dma = 0`, `batch_worker_dma = 0`
   - `max_queues = 256`, `max_fetch_sqes = 1024`, `worker_queue_size = 32768`
4. **Verify**: `swarmio.ko` builds clean; `sudo modprobe swarmio …` (via `load.sh`) loads
   with **no unresolved symbols**, `dmesg` shows multiple
   `swarmio_dispatcher_<k> assigned sq […]` lines and `SwarmIO: Virtual NVMe device created`,
   and a new `/dev/nvmeXn1` appears. If link fails on idxd symbols, step 1/2 missed a path.

### Task B — Timing-model parameterization for in-flash compute

Implement §2.3 + §2.4. Decide and document the per-plane-serialization question:
- **Recommended**: edit the `skip_io` timing path so compute mode **still runs
  `__sched_io_units`** (timing/scheduling-instance update) but **skips the data copy** in
  the worker. This keeps per-plane serialization (2 reqs/plane = 76 µs) while modeling
  "results only." (Touches `src/simple_timing_model.c` `#ifndef …SKIP_IO` guards and the
  worker copy path.)
- Set, at load time: `num_sched_insts=512`, `block_size=4096`,
  `read_sched_delay=38000`, `read_min_delay=0` (faithful 38 µs round). Also produce a second
  configuration `read_min_delay=30000, read_sched_delay=8000` (pipelined variant).
- Provide a `configs/inflash_pim.conf` capturing the build + load params.

### Task C — Load / run harness for this machine

1. `scripts/load.sh` invocation (or a wrapper `scripts/load_inflash.sh`):
   `memmap_start=96G memmap_size=16G num_sched_insts=512 block_size=4096
   read_sched_delay=38000 read_min_delay=0 num_service_units=<S>
   num_workers_per_service_unit=1 cpus=<isolated range> use_disp_dma=0 use_worker_dma=0`.
   - **Cores**: reserve a contiguous P-core range for service units, e.g. `cpus=2-9`
     (`S=8` service units, 1 dispatcher each) and leave other cores for fio/host. Sweep
     `num_service_units ∈ {1, 2, 4, 8}` to show frontend scaling (1 ≈ NVMeVirt-like).
   - First runs may omit `isolcpus`; for low-noise timing, **recommend** a GRUB change
     `isolcpus=2-15` + reboot (a user action — request it). Document whichever was used.
2. Pre-flight: `sudo rmmod nvmev` (our INFLASH_PIM) if loaded; `lsmod | grep -E
   'nvmev|swarmio'`; confirm the SwarmIO device name (`lsblk`/`dmesg`) and set it in
   `run_fio.sh` `VDEV_DEV_NAME` and for `inflash_bench --dev`.

### Task D — Measurement (two harnesses, both)

1. **Reuse `host/inflash_bench`** (unchanged) for the **same metric as the NVMeVirt
   baseline**: issue `N` concurrent 4 KB reads (qdepth=N) striped over LPNs `[0,N)`, record
   **batch end-to-end** (first submit → last completion). Directly overlay
   SwarmIO-vs-NVMeVirt vs `T_model(N)`. (No prepopulation needed in compute/`skip_io`
   mode; just keep offsets < device size.)
2. **Native `scripts/run_fio.sh`** for steady-state IOPS + clat and the
   `/proc/swarmio/stat` breakdown: sweep `--io-depths` and `--num-threads` (concurrency),
   record MIOPS and clat(µs). Expectation: clat stays ≈ 38 µs until aggregate IOPS
   approaches `Tmax` (≈13.5 MIOPS for the faithful config), where NVMeVirt capped far lower.
3. Emit machine-readable CSV per run: `harness, num_service_units, N_or_iodepth, qdepth,
   threads, T_model_ns, measured_e2e_ns (or clat_ns), measured_MIOPS, abs_err, rel_err`.
4. **Core isolation**: pin `inflash_bench`/fio threads to cores **disjoint** from the
   SwarmIO `cpus=` set (`--cpu` / `taskset` / fio `cpus_allowed`).

### Task E — Calibration & validation microtests

- **Single request** → ≈ 38 µs (= `read_sched_delay + read_min_delay`).
- **Two requests to the same instance** (LPN 0 and LPN `num_sched_insts` = 512) → ≈ 76 µs
  (faithful config) or ≈ 46 µs (pipelined config). Confirms per-plane serialization is
  preserved through `skip_io` (Task B).
- **One saturated round** (512 reqs, one per instance, qdepth 512) → should now be **≈ 38 µs
  ± frontend overhead**, *not* ~557 µs. This is the headline check that SwarmIO removed the
  bottleneck.
- Sweep `num_service_units = 1` to reproduce the NVMeVirt-like single-dispatcher curve as a
  control, then 2/4/8 to show convergence.

---

## 6. Experiment design

### 6.1 Independent variables
- **Concurrency** `N` (qdepth for `inflash_bench`; `iodepth × numjobs` for fio):
  `{1,2,4,8,16,32,64,128,256,512,1024,2048,4096}`.
- **`num_service_units`** `{1,2,4,8}` (frontend parallelism; 1 ≈ NVMeVirt control).
- Hold fixed per sweep: `num_sched_insts=512`, 4 KB, the chosen delay split.

### 6.2 Model side
`T_model(N) = 38 µs · ⌈N / 512⌉` (faithful config). For the pipelined config, also report
the per-request floor 38 µs and the throughput cap.

### 6.3 Metrics & hypotheses (now expected to be **confirmed**)
- Abs/rel error `|measured − T_model| / T_model`; p50/p99 over trials; plot **latency vs N**
  (NVMeVirt baseline, SwarmIO at each `num_service_units`, and `T_model` overlaid) and
  **relative error vs N**, and **achieved MIOPS vs N**.
- H1: SwarmIO with `S≥4` keeps e2e ≈ 38 µs out to N≈512 (one round), i.e. **converges** to
  the model where NVMeVirt diverged.
- H2: convergence improves with `num_service_units` (frontend parallelism).
- H3: SwarmIO's achievable MIOPS approaches `Tmax = num_sched_insts/sched_delay`, bounded on
  this consumer CPU by core count and host-side submission (a threat to validity, not a
  model error). Quantify the residual gap and attribute it (frontend cores vs host driver).

---

## 7. Deliverable: the report (`report_swarmio.md` + CSV/figures)

1. **Setup**: machine (i9-13900F, no DSA), SwarmIO no-DSA port summary, build/load params,
   `num_sched_insts/sched_delay/min_delay` derivation, core pinning, memmap, device name.
2. **Why SwarmIO**: the NVMeVirt single-dispatcher result (§1.1 data) and the fix.
3. **Model recap**: `38 µs · ⌈N/512⌉` and the Tmax/Lmin mapping (both delay splits).
4. **Results**: tables + figures — latency vs N (NVMeVirt vs SwarmIO×{1,2,4,8} vs model),
   rel error vs N, MIOPS vs N; microtest results (single / same-instance / saturated round).
5. **Analysis**: does SwarmIO converge to the model, and in what N / num_service_units
   regime; residual gap attribution (frontend cores, host submission, no DSA, no isolcpus).
6. **Threats to validity**: no DSA (CPU-copy/`skip_io` path), consumer CPU core count,
   host-side fio/io_uring submission ceiling, no `isolcpus`, the Tmax/Lmin abstraction vs a
   detailed NAND model, `skip_io` per-plane-timing edit.
7. **Conclusion**: is the in-flash-computing analytic model consistent with a *frontend-
   scalable* emulator, and what the NVMeVirt→SwarmIO comparison reveals about where
   emulator architecture (not the timing model) governs fidelity at high request rates.

---

## 8. Acceptance criteria

- [ ] SwarmIO **builds with no idxd headers** and **loads with no unresolved symbols** on
      this DSA-less machine (`use_disp_dma=0 use_worker_dma=0`); `dmesg` shows multiple
      dispatchers and a virtual NVMe device.
- [ ] Timing configured to `num_sched_insts=512`, single-req ≈ 38 µs, same-instance 2-req ≈
      76 µs (faithful) — verified by microtest.
- [ ] **Saturated round (512 concurrent reqs) ≈ 38 µs**, vs NVMeVirt's ~557 µs — the
      headline convergence result, with `num_service_units` sweep showing the trend.
- [ ] `inflash_bench` and `run_fio.sh` sweeps executed; CSV + plots produced; NVMeVirt
      baseline overlaid.
- [ ] `report_swarmio.md` compares analytic vs SwarmIO vs NVMeVirt and characterizes the
      convergence regime and residual gaps.
- [ ] memmap `96G/16G` used cleanly; our `nvmev` unloaded first; `lsmod`/`dmesg` checked
      before each (re)load.

## 9. Key code references (SwarmIO tree)

- Timing model: `SwarmIO/src/simple_timing_model.c` (`__sched_io_units`
  [:16](SwarmIO/src/simple_timing_model.c#L16); aggregated [:142](SwarmIO/src/simple_timing_model.c#L142);
  `SKIP_IO` guards [:42](SwarmIO/src/simple_timing_model.c#L42), [:313](SwarmIO/src/simple_timing_model.c#L313)).
- Params: `SwarmIO/src/common.h:103-113`; module params set in `scripts/load.sh:158-192`.
- DSA (to gate out): `SwarmIO/dsa/dsa.c`, `dsa/config.c`; `SwarmIO/Kbuild:16-35`.
- Build/load/run: `SwarmIO/scripts/build.sh`, `scripts/load.sh`, `scripts/run_fio.sh`;
  README `SwarmIO/README.md` (build deps, GRUB/memmap/isolcpus, usage).
- Paper: `SwarmIO/SwarmIO_paper.pdf` §III-A (bottleneck), §IV-B (distributed dispatch +
  coalesced fetch), §IV-C (DSA — what we omit), §IV-D (aggregated timing), Fig 3 & 13.
- Host benchmark (reuse): `host/inflash_bench.c`; prior NVMeVirt baseline + design:
  `INFLASH_PIM_DESIGN.md`, `INFLASH_COMPUTE_EMULATION_PROMPT.md`.
