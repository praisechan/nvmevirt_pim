# Follow-up Experiment Prompt: Beating the Host-Submission Ceiling on SwarmIO In-Flash Compute

> **Use this file as the task specification.** It is a follow-up to
> `prompts/SWARMIO_INFLASH_COMPUTE_EMULATION_PROMPT.md` and the completed run documented in
> `reports/report_swarmio.md`. It is self-contained: it restates the relevant verified state,
> the *reason the previous run did not converge*, two new experiments to try (in order), the
> exact mechanics/file refs, the analytic model adjustments, and the deliverables.

---

## 0. One-paragraph summary

The first SwarmIO run validated the **device timing model** (single 4 KB read ≈ 38 µs;
two reads to the same scheduling instance ≈ 76 µs — per-plane serialization preserved) but
**refuted H1** (a 512-wide "saturated round" did **not** converge to ≈ 38 µs end-to-end). The
root cause was **host-side submission serialization**, *not* the emulator frontend or the timing
model: `host/inflash_bench` uses a **single io_uring ring → one NVMe SQ → one dispatcher**, and a
single host thread cannot deposit 512 separate 4 KB commands into the device within one 38 µs
round (it takes ≈ 512 × 2.2 µs ≈ 1.1 ms). This follow-up attacks that ceiling two ways, in order:
**(1)** make each request **span many planes** (multi-page / large requests, and/or a larger
MDTS) so that **far fewer host submissions** present a full 512-instance round; **(2)** *if (1)
is insufficient*, drive concurrency from a **many-queue / many-thread host** (fio `numjobs ≫ 8`,
or SPDK) so that submission throughput, not a single ring, feeds the distributed frontend. The
goal is to find a host strategy under which the emulated end-to-end latency for one saturated
round **converges to ≈ 38 µs**, confirming that the timing model is consistent with a
frontend-scalable emulator once the host is no longer the bottleneck.

---

## 1. Verified state to build on (do not re-derive)

### 1.1 Machine & module (already done)
- **CPU**: i9-13900F, 32 logical (P-cores → 0–15, E-cores → 16–31), **no Intel DSA**.
- **SwarmIO is ported to build/load without DSA.** `swarmio.ko` builds with `use_disp_dma=0
  use_worker_dma=0 skip_io=1` and **no idxd symbols** (see `SwarmIO/PORT_NOTES.md`). It loads
  with **8 distributed dispatchers** and creates **`/dev/nvme1n1`** (12 GiB).
- **Two `skip_io` bugs were fixed** (documented in `SwarmIO/PORT_NOTES.md`):
  (a) timing math de-guarded from `CONFIG_SWARMIO_WORKER_SKIP_IO` in
  `src/simple_timing_model.c`; (b) the completion-deadline gate `if (w->nsecs_target <=
  curr_nsecs)` in `src/worker.c:__swarmio_complete()` made **unconditional** so `skip_io` honors
  `nsecs_target`. **Keep both fixes.**
- **Faithful timing config** (Config A): `num_sched_insts=512`, `block_size=4096`
  (`io_unit_shift=12`), `read_sched_delay=38000`, `read_min_delay=0`. `unit_id = (lba>>3) %
  512 = lpn % 512`. T_max = 512 / 38 µs ≈ 13.47 MIOPS.
- **Reserved memmap**: `memmap=16G$96G` → `memmap_start=96G memmap_size=16G`. Unload our
  `nvmev` (`sudo rmmod nvmev`) before loading swarmio. Privileged steps need a fresh `sudo -v`
  window.

### 1.2 Harness (already built — reuse)
- `SwarmIO/configs/inflash_pim.conf` — build+load config (faithful).
- `SwarmIO/scripts/load_inflash.sh` — loads with `cpus=0..(2S-1)` (service units on P-cores
  0–15; fio/bench on E-cores 16–31), `NUM_SERVICE_UNITS` env (sweep 1/2/4/8), `PIPELINED=1`
  env for the pipelined config, `RUN=1` to actually load. `unload_inflash.sh` to unload.
- `SwarmIO/scripts/swarmio_microtest.sh` — single / same-instance / saturated-round microtests.
- `SwarmIO/scripts/run_fio.sh` — fio sweep (FIO_CPUS default 16-31, VDEV_DEV_NAME overridable).
- `scripts/swarmio_sweep_driver.sh` — full inflash_bench N-sweep + fio S×numjobs matrix → CSV.
- `scripts/swarmio_model.py` — enrich raw CSV with `T_model_ns`/`abs_err`/`rel_err`
  (`--pipelined` flag; stdlib only). `scripts/swarmio_plot.sh` — gnuplot figures.
- `scripts/swarmio_csv_schema.md` — CSV contract:
  `harness,num_service_units,N_or_iodepth,qdepth,threads,T_model_ns,measured_e2e_ns,measured_MIOPS,abs_err,rel_err`.
- `host/inflash_bench.c` — io_uring 4 KB O_DIRECT reads, LPN-striped. **Hardcodes `PAGE_SIZE`
  (4096) per read** (`io_uring_prep_read(..., PAGE_SIZE, lpn*PAGE_SIZE)` at ~line 252; AIO path
  at ~line 146). Has `--requests N --qdepth Q --trials T --cpu C --csv --prepopulate
  --maxpages --samelun`. Needs a new `--reqsize` option (Experiment 1).

### 1.3 Why the previous run did not converge (the thing we are fixing)
A single io_uring ring serializes submission. The device *can* honor a 512-instance parallel
round (each distinct instance completes at `nsecs_start + 38 µs`), but the **host never presents
512 commands simultaneously** through one ring. The previous fio result already showed the cure
in throughput terms: IOPS scaled **near-linearly with queues** (1→8 rings: 0.38→2.97 MIOPS) at
**flat ~82 µs latency**. This follow-up tests whether we can get a **single-round latency** near
38 µs by reducing the number of host submissions per round (Exp 1) or parallelizing them (Exp 2).

---

## 2. The key device constraint: MDTS caps how many planes one request spans

- `SwarmIO/src/common.h:68` defines `#define MDTS (5)`, applied at
  `SwarmIO/nvmev/nvme_vdev.c:87` (`vdev->mdts = MDTS`). With a 4 KB min page, **MDTS=5 ⇒ max
  128 KB per NVMe command = 32 pages = 32 scheduling instances per command.** Confirmed on the
  live device: `/sys/block/nvme1n1/queue/max_hw_sectors_kb = 128`.
- A request of `length` bytes occupies `DIV_ROUND_UP(length, 4096)` consecutive instances
  starting at `lpn % 512`, each charged one `sched_delay` (verified in `__sched_io_units`,
  `simple_timing_model.c:16-88`, and in the aggregated path
  `simple_sched_nvme_cmd_aggregated`, `:175-320`, which is the **active** path under
  `coalesce_sqe=1 + use_agg_timing_update=1`).
- **Consequence**: to cover all 512 instances in one round you need at least
  `512 / 32 = 16` requests of 128 KB (vs. 512 requests of 4 KB) — a **32× reduction in host
  submissions**. To cover 512 instances with **one** command you must **raise MDTS** (see §3.B).
- **Note on host-side splitting**: a single `pread`/io_uring read larger than 128 KB is split by
  the Linux block layer into 128 KB NVMe commands automatically. That reduces *io_uring
  submission count* but still produces multiple device commands on one SQ. Raising MDTS (§3.B)
  is the only way to make **one NVMe command** span more than 32 instances.

---

## 3. Experiment 1 (primary): multi-page / large requests

**Hypothesis**: presenting a full 512-instance round with far fewer (larger) requests removes
enough host-submission serialization that end-to-end latency for one round approaches ≈ 38 µs.

Try the two sub-levers; **3.A needs no rebuild, 3.B is the cleanest single-round test.**

### 3.A — Multi-page requests up to the 128 KB MDTS cap (no rebuild)
1. **Add `--reqsize BYTES` (or `--pages-per-req K`) to `host/inflash_bench.c`.** Each request
   reads `reqsize` bytes (multiple of 4 KB, ≤ 128 KB for MDTS=5) at offset `lpn*4096`, with
   `lpn` advancing by `reqsize/4096` per request so requests tile distinct instance ranges.
   Update both the io_uring path (~line 252) and the libaio path (~line 146); `posix_memalign`
   buffers to `reqsize`; keep offsets `< device size`. Preserve the existing 4 KB default.
2. **Saturated-round layout**: with `K = reqsize/4096` pages/req and `R = 512/K` requests at
   offsets `i*reqsize` (`i=0..R-1`), the R requests cover instances `[0,511]` exactly once.
   Issue all R at `qdepth=R`. Sweep `K ∈ {1,2,4,8,16,32}` ⇒ `R ∈ {512,256,128,64,32,16}`.
   **Expectation**: measured e2e falls toward ≈ 38 µs as R shrinks; identify the R (host
   submission count) at which |rel_err| < 10 %.
3. **Throughput-with-depth sweep**: also vary total pages (multiple rounds) at fixed `K=32` to
   confirm `T_model = 38 µs × ⌈total_pages / 512⌉` still holds with large requests.
4. **Microtests**: (i) one 128 KB request (32 instances) → expect ≈ 38 µs; (ii) 16×128 KB
   covering all 512 → expect ≈ 38 µs (the saturated-round headline check with only 16
   submissions); (iii) two 128 KB requests to the **same** 32-instance range → expect ≈ 76 µs.

### 3.B — Raise MDTS so one command spans all 512 instances (rebuild)
1. In `SwarmIO/src/common.h`, raise `#define MDTS (5)` to e.g. **`9`** (2⁹ = 512 pages = 2 MB
   max per command). Rebuild + reinstall (see §5). Confirm `max_hw_sectors_kb` grows (≈ 2048).
2. **Cleanest single-round test**: issue **one** 2 MB request (`--reqsize $((512*4096))`) at
   `lpn 0` → spans all 512 instances in one command at **qdepth=1** → expect e2e ≈ 38 µs.
   This most directly realizes the user's idea ("bigger requests, fewer requests fully utilize
   all planes") and isolates the device timing from host submission entirely.
3. Sweep `reqsize ∈ {128 KB, 256 KB, 512 KB, 1 MB, 2 MB}` at `qdepth=1` and small qdepths;
   record e2e vs `T_model = 38 µs × ⌈pages_per_req / 512⌉`. Document the MDTS change clearly
   (it deviates from the 128 KB-realistic SSD; justify as a frontend-isolation probe).

### 3.A/3.B acceptance
- A 512-instance round is presented with ≤ 16 (3.A) or **1** (3.B) host submission(s) and
  measured e2e ≈ **38 µs ± host overhead** (vs. 1115 µs for the 512×4 KB single-ring case).
- The page-count model `T_model = 38 µs × ⌈total_pages/512⌉` holds across request sizes.
- If 3.A/3.B achieve convergence, **H1 is confirmed** under a realizable host strategy and the
  previous divergence is conclusively attributed to host submission count.

---

## 4. Experiment 2 (fallback, only if Experiment 1 is insufficient): many-queue / many-thread host

Run only if large requests cannot present a full round near 38 µs (e.g., block-layer splitting
or single-SQ fetch still serializes). Goal: supply submission concurrency from **many queues**.

1. **fio many-thread sweep**: `numjobs ∈ {8,16,24,32}` (multiple io_uring rings = multiple NVMe
   SQs = multiple dispatchers), small `iodepth` (e.g. 1–4) so each ring presents few in-flight,
   `--cpus_allowed` spanning the E-cores and any P-cores not used by service units. Sweep
   `num_service_units ∈ {1,2,4,8}`. Record IOPS, clat p50/p99, `/proc/swarmio/stat`. Test
   whether aggregate submission across rings lets a 512-wide round complete near 38 µs and
   whether MIOPS now climbs toward T_max (13.47) as both host queues **and** service units grow.
   (Previous run was bounded by 8 fio threads on E-cores; push past that and add P-cores.)
2. **Optional SPDK**: if installed/installable, `spdk/perf` with many qpairs from few cores
   bypasses the kernel block layer and can present many commands fast. Note SPDK was absent
   previously; treat as optional and document if used.
3. **Core budget**: with service units on 0–15 and host threads needing cores too, consider
   `num_service_units=4` (cores 0–7) leaving 8–31 for the host, or run host on P-cores while
   service units use fewer. Document the pinning used; pin host threads disjoint from SUs.

### Experiment 2 acceptance
- Identify the (num_service_units, host-queue) combination that maximizes MIOPS and minimizes
  single-round latency; report peak MIOPS vs. T_max and attribute the residual gap (host cores,
  kernel submission path, no isolcpus).

---

## 5. Build / run mechanics (this machine)

```bash
cd /home/juchanlee/nvmevirt_pim
# rebuild after editing inflash_bench.c (host side, no sudo):
make -C host            # or: cc -O2 host/inflash_bench.c -luring -o host/inflash_bench

# rebuild swarmio after an MDTS change (Exp 3.B). build.sh's `make install` only copies the .ko
# if absent, so force-replace:
sudo rmmod swarmio 2>/dev/null
cd SwarmIO && make clean && make skip_io=y coalesce_sqe=y use_agg_timing_update=y \
  use_cas_timing_update=y use_disp_dma=n use_worker_dma=n \
  max_queues=256 max_fetch_sqes=1024 worker_queue_size=32768
sudo rm -f /lib/modules/$(uname -r)/extra/swarmio.ko
sudo cp swarmio.ko /lib/modules/$(uname -r)/extra/ && sudo depmod -a ; cd ..

# load + verify (faithful, S=8); device = /dev/nvme1n1
RUN=1 NUM_SERVICE_UNITS=8 bash SwarmIO/scripts/load_inflash.sh
dmesg | tail -20 | grep -i swarmio ; lsblk | grep nvme1n1

# inflash_bench needs root for O_DIRECT on the block device; pin to E-cores:
sudo taskset -c 16-31 host/inflash_bench --dev /dev/nvme1n1 --reqsize 131072 \
     --requests 16 --qdepth 16 --trials 15
```

Constraints: keep authoring and verification as separate passes. Do **not** run sudo from
non-interactive contexts without a fresh `sudo -v`. Faithful config params are fixed
(`num_sched_insts=512`, `read_sched_delay=38000`, `read_min_delay=0`); also produce the
pipelined variant (`PIPELINED=1`, `read_sched_delay=8000 read_min_delay=30000`) where useful.

---

## 6. Model adjustments

- **Page-count model (both experiments)**: `T_model = 38000 × ⌈total_pages / 512⌉` ns, where
  `total_pages = Σ_requests (reqsize / 4096)`. One full round (512 pages) = 38 µs regardless of
  how the pages are packed into requests. The independent variable becomes **host submission
  count** (requests/queues), not page count, for the convergence test.
- Reuse `scripts/swarmio_model.py` (the formula is page/`N`-based; for multi-page rows set the
  CSV `N_or_iodepth` column to **total_pages** so `T_model` is computed correctly). Extend the
  model script only if a per-request-size breakdown is needed; otherwise keep it as-is.
- Pipelined variant: `T_model = 30000 + 8000 × ⌈total_pages/512⌉` ns.

---

## 7. Deliverables

1. **Code**: `host/inflash_bench.c` extended with `--reqsize`/`--pages-per-req` (Exp 1); if Exp
   3.B is run, the `MDTS` change in `SwarmIO/src/common.h` (clearly commented + reverted or
   gated so the default stays realistic). Update `SwarmIO/PORT_NOTES.md` if module source changes.
2. **Harness**: a sweep script (extend `scripts/swarmio_sweep_driver.sh` or add
   `scripts/swarmio_reqsize_sweep.sh`) emitting the existing CSV schema; for Exp 2 a
   many-thread fio driver (extend `run_fio.sh`). Keep `RUN=1`-guarded sudo and core pinning
   disjoint from service units.
3. **Data + figures**: `results_reqsize_raw.csv` → enriched via `swarmio_model.py` →
   figures via `swarmio_plot.sh` (latency vs submission-count, MIOPS vs concurrency). gnuplot
   5.4 is installed.
4. **Report**: append a new section to `reports/report_swarmio.md` (or a sibling
   `reports/report_swarmio_followup.md`) covering: the host-submission-ceiling recap, Exp 1
   design + results (does e2e converge to ≈ 38 µs as submissions drop? at what request size /
   submission count?), Exp 2 results if run, and a final verdict on **H1 under a realizable host
   strategy**. If `report_swarmio.md` figure links broke when it moved into `reports/`, fix the
   relative image paths (`fig_*.png` are at the repo root) as housekeeping.

## 8. Acceptance criteria
- [ ] `inflash_bench` supports multi-page requests; a 512-instance round is presented with ≤ 16
      (Exp 3.A) or 1 (Exp 3.B) host submission(s).
- [ ] Measured e2e for one saturated round is reported vs. the 38 µs model and the prior
      1115 µs single-ring result; the submission-count at which |rel_err| < 10 % is identified
      — or, if convergence still fails, Exp 2 is run and its limiting factor quantified.
- [ ] CSV (existing schema) + figures produced; faithful and (where useful) pipelined configs.
- [ ] `reports/` report updated with an honest verdict on whether reducing/parallelizing host
      submissions lets the in-flash-compute model converge end-to-end on this consumer CPU.

## 9. Key code references
- Timing (multi-unit spread): `SwarmIO/src/simple_timing_model.c:16-88` (`__sched_io_units`),
  `:175-320` (aggregated, active path).
- MDTS: `SwarmIO/src/common.h:68`, `SwarmIO/nvmev/nvme_vdev.c:87`.
- Host bench (add `--reqsize`): `host/inflash_bench.c` (io_uring read ~`:252`, libaio ~`:146`,
  options ~`:357-395`).
- skip_io completion gate (keep fixed): `SwarmIO/src/worker.c:__swarmio_complete()`.
- Prior results + root cause: `reports/report_swarmio.md` §4–§5; `SwarmIO/PORT_NOTES.md`.
