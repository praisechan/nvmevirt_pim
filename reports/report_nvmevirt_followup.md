# NVMeVirt INFLASH_PIM — Follow-up: Multi-Page In-Flash Compute and Emergent t_cmd

> Follow-up to `reports/report.md` and the task spec
> `prompts/NVMEVIRT_MULTIPAGE_FOLLOWUP_PROMPT.md`. Machine: i9-13900F (32 logical,
> P-cores 0–15 / E-cores 16–31), `nvmev.ko` (`INFLASH_PIM` profile), memmap `96G/16G`,
> device `/dev/nvme1n1`, NVMeVirt threads pinned `cpus=7,8` (1 dispatcher + 1 io_worker),
> host bench pinned `taskset -c 16-31`. **Default knobs preserved for all headline numbers**
> (`COMPUTE_RESULT_SIZE=64`, `FW_CH_XFER_LATENCY=0`, `NAND_CHANNEL_BANDWIDTH=800 MB/s`).
> Measurements: `host/inflash_bench` (O_DIRECT, io_uring), 15 trials, median e2e.
> Device latency read off the model via `dmesg | grep inflash_dev_lat`
> (`nsecs_target − nsecs_start`, instrumented in `conv_read`). MDTS=6 (256 KB cap) for
> Exp 4.A; MDTS=9 (2 MB cap) for the Exp 4.B probe (reverted to 6 afterwards).

---

## 0. Verdict (TL;DR)

The faithful emulator splits cleanly into **two separate latencies that the analytic model and
the SwarmIO leg conflate**, and the result is more nuanced than H1 anticipated:

1. **The device timing model already converges — and stays converged.** The reported device
   latency (`nsecs_target − nsecs_start`) is a **flat ≈ 30.15 µs** for a full 512-LUN round,
   *independent* of command count, request size, and active-LUNs-per-channel. That is tR (30 µs)
   plus a single channel-transfer unit (~152 ns). The emulator's own per-round device time needs
   **no** convergence fix — it is already at the floor, and even **below** the 38 µs analytic
   reference.

2. **Host-observed e2e does *not* converge via multi-page packing**, and this refutes the
   prompt's stated mechanism. Packing 512 pages into 8 commands instead of 512 only drops e2e
   from **~778 µs → ~358 µs** (≈ 2.2×), and a *single* 2 MB command (Exp 4.B, one dispatch,
   zero command-count serialization) still costs **~538 µs**. The binding constraint is **not**
   the per-command dispatcher cost the prompt assumed, **nor data transfer, nor the io_worker
   memcpy, nor the dispatcher's `conv_read` simulation** (all ruled out experimentally — see §5.5).
   Two-ended instrumentation shows NVMeVirt's **device-observed latency is 30,162 ns — the modeled
   time, delivered 10 ns late** — so the emulator imitates LUN-level parallelism *faithfully*. The
   inflation is **entirely host-side and outside NVMeVirt**: the Linux **O_DIRECT** path pins/unpins
   pages, builds the PRP list, and reaps the IRQ at **≈ 1 µs per 4 KB page of the request**, which
   is why host e2e tracks total pages in flight. The fix is not in NVMeVirt; it is to issue **one
   small request** that internally triggers all-plane sensing (true in-flash-compute command shape).

3. **The emergent `t_cmd` at default knobs is ≈ 152 ns and flat** — far smaller than the 2.6 µs
   analytic estimate and the 8 µs original guess — because a 64 B compute result is one
   128 B-rounded transfer unit, well under the channel's 26-credit / 4 µs budget, so it never
   queues. A single permitted knob-sensitivity run (`COMPUTE_RESULT_SIZE=4096`) shows the channel
   model **is** faithful and load-dependent: `t_cmd` then scales **4.9 µs → 105 µs** as
   active-LUNs/channel rises 1 → 32. So the flatness at 64 B is a *faithful consequence of the
   tiny result size*, not a dead model.

**Bottom line:** on the faithful emulator the *device* is perfectly converged (≈ 30 µs);
the *host wall-clock* is gated by single-threaded per-page simulation throughput, which
multi-page packing cannot overcome. This is the opposite finding from the SwarmIO leg, where
multi-page packing *did* converge host e2e (its bottleneck was host-side ring submission).

> **UPDATE (Exp 5, §11): the predicted fix is now implemented and measured.** Decoupling the
> on-device sensing extent from the host transfer size (one 1-page `--compute` request that
> internally senses all 512 planes) converges all-plane host e2e from **538 µs → ~48 µs (≈ 11×)** —
> the all-plane device latency (~34 µs, refined below) plus a fixed ~14 µs O(1) host floor. dmesg
> proves the single-page request senses 512 pages. The ~77 µs host term was O(request-pages) and was
> *eliminated*, not parallelized.

> **UPDATE (Exp S, §12): the remaining ~14 µs host residual is now *removed*, not just argued away.**
> Re-issuing the same 1-page compute command through **SPDK** (kernel-bypass: pre-pinned hugepage DMA,
> userspace doorbell, polled completion) drops host e2e **48 µs → 34.84 µs** — only **0.68 µs** above
> the modeled 34,152 ns device floor — with the jitter collapsing from a 46→200 µs spread to a <1 µs
> band, while dmesg confirms the device is **unchanged** (`inflash_dev_lat 34152 ns (sensed 512
> pages)`). Feasibility verdict: SPDK drives the emulated device via **`uio_pci_generic`** (`vfio-pci`
> is structurally blocked — the software PCI root bus has no IOMMU group). So the host residual was a
> commodity-stack artifact and is removable: **end-to-end latency itself now matches `tR + control`.**

> **UPDATE (§13): a single-plane mode is added alongside all-plane (runtime `compute_sense_pages`
> module param; default = all-plane, fully backward-compatible).** At `compute_sense_pages=1` one NVMe
> request senses one plane (`30152 ns, sensed 1 pages` — pure tR), so activating all 512 planes takes
> 512 requests and costs **~144 µs** (qd512) vs the all-plane primitive's **34.8 µs** for the same work
> in **one** command — **~4.2× faster**. Per command single-plane is cheaper (30.8 vs 34.8 µs, it dodges
> the ~4 µs full-load `t_cmd`), but the device-side all-plane primitive wins decisively by collapsing
> 512 host/dispatcher round-trips into one. Quantitative case for keeping "sense all planes" device-side.

> **UPDATE (§14): scaling NVMeVirt's controller cores does *not* rescue single-plane — it makes it
> worse, which hardens the O(1)-vs-O(512) argument.** A faithful `nr_dispatchers=N` knob was added (N
> dispatcher kthreads over disjoint SQ subsets `(sqid-1)%N`; admin+BARs on dispatcher 0; the shared
> per-channel/LUN flash-timing state serialized under a **per-channel spinlock**; the flash array
> itself unchanged). `N=1` reproduces §13 (regression: 30.8 µs/op, ~152 µs/512-set floor). Sweeping
> `N∈{1,2,4,8}` with host queues matched (`inflash_bench_spdk --threads N`, one SPDK qpair = one SQ =
> one dispatcher), the single-plane amortized floor **rises 152 → 308 µs** rather than falling toward
> the ~30 µs flash round, while **all-plane stays a flat 34.8 µs / `34152 ns` for every N** and the
> single-plane per-op device latency stays `30152 ns` (flash array provably untouched). A control
> (N=1 placed on N=8's working cores) isolates the cause: the extra dispatchers' polling of the shared
> doorbell region plus the faithful media lock add contention faster than they add intake parallelism.
> So single-plane O(512) cannot approach the floor by spending N controller cores; all-plane reaches it
> with **one** command on **one** core/queue. The command-count argument survives — indeed defeats —
> aggressive parallelization. (Discovered & fixed en route: a multi-dispatcher data race on the
> io_worker free-lists; now a per-io_worker lock.)

> **UPDATE (Exp A, §15): the per-channel media lock is *not* the single-plane limiter — confirmed by
> direct measurement, hardening §14.** §14 attributed the multi-dispatcher rise partly to per-channel
> media-lock contention but never isolated that term. A **host-side-only** routing change
> (`inflash_bench_spdk --chan-affine`: worker `t` issues only LPNs on channels `{c: c%N==t}`, so each
> per-channel `ch->lock` has a single owning dispatcher) removes *all* cross-dispatcher lock contention
> at matched N, with the module config (dispatchers, cores, io_workers, locks) held identical. A new
> in-module trylock counter (`/proc/nvmev/chstat`; `CONFIG_LOCK_STAT` is off in this kernel) proves it:
> contended `ch->lock` acquisitions go **spread → affine = {660,584,586} → 0** at N={4,8,16}, and the
> per-(cpu,channel) matrix confirms each channel is touched by **exactly one** dispatcher under affine
> (vs all N under spread). Yet the single-plane amortized µs/512-set **barely moves** (N=4: 228.9→230.2;
> N=8: 292.6→269.4, a modest −8%; N=16: dominated by the io_worker-oversubscription confound). So the
> lock was contended but *rarely* (≈1.5% of acquisitions) and was **not** the bottleneck — the
> turbo/LLC/io_worker-funnel terms dominate, exactly as §14 argued. dmesg stays `30152`/`34152 ns`.

> **UPDATE (Exp B, §16): NVMeVirt's *serial* dispatcher is not the wall either — one dispatcher
> activating N single-plane commands stays at the flash floor, and *beats* N parallel dispatchers.**
> Setting planes = dispatchers (`--planes N`, 1 channel-affine command per controller core) the
> "parallel" e2e *rises* 30.8 → 126.5 µs (N=1→8; N=16 confounded), because N host threads + N
> busy-spinning P-cores add fan-out skew and contention faster than parallelism. The **serial baseline**
> — the *same* N planes on **one** dispatcher / one queue / N commands — instead stays flat at
> **30.8 → 34.97 µs** for N=1→16 (≈ the 34.8 µs all-plane primitive!), giving a directly-measured
> per-command serial-intake cost of **t_cmd ≈ 0.28 µs/cmd** — negligible below hundreds of commands.
> So §14's 512-set cost is **host-throughput-bound, not per-dispatcher-serial-intake-bound**; multi-core
> controller scaling makes single-plane worse, not better, on both axes (lock contention *and* serial
> intake). dmesg per-op `30152 ns` for every N and P; affinity verified; no lockdep splat.

---

## 1. Recap: the prior single-dispatcher framing

`reports/report.md` validated the per-LUN timing model (lone 4 KB ≈ 30 µs ≈ tR; two reads to the
**same** LUN ≈ 2·tR) but found a 512-wide round diverged badly from 38 µs, and attributed it to
NVMeVirt's **single dispatcher** serializing command issue at ≈ 1 µs/command.

### 1.1 Prior divergence table (from `reports/report.md` / `results_enriched.csv`)

| N (qdepth=N) | NVMeVirt e2e | T_model = 38 µs·⌈N/512⌉ | rel err |
|:---:|:---:|:---:|:---:|
| 1 | ~36 µs | 38 µs | ~−5 % |
| 8 | ~45 µs | 38 µs | +17 % |
| 64 | ~116 µs | 38 µs | +206 % |
| 512 | **~557 µs** | 38 µs | **+1366 %** |
| 4096 | ~4240 µs | 304 µs | +1295 % |

Shape: `e2e(N) ≈ 30 µs floor + N × ~1.0 µs`. In the `1 req = 1 page = 1 LUN` mapping the number
of **pages** equals the number of **commands**, so that ~1 µs/op term could be read *either* as
per-command dispatch *or* per-page processing. **This follow-up's multi-page experiment is exactly
the test that separates the two** — and the answer (below) is that the dominant term is **per-page**,
not per-command.

### 1.2 NVMeVirt geometry (INFLASH_PIM defaults) — verified live this run

| Parameter | Value (confirmed from `dmesg` / sysfs) |
|---|---|
| Channels | 16 |
| LUNs / channel | 32 |
| Total LUNs (planes) | **512** (`Init FTL instance with 16 channels (4194304 pages)`) |
| Flash page size | 4 KB |
| MDTS (Exp 4.A) | 6 → `max_hw_sectors_kb=256` → 64 pages/command |
| MDTS (Exp 4.B probe) | 9 → `max_hw_sectors_kb=2048` → 512 pages/command |
| NAND read latency tR | 30,000 ns |
| Threads | 1 dispatcher (cpu 7) + 1 io_worker (cpu 8) |
| Channel model | `UNIT_XFER_SIZE=128 B`, `xfer_lat≈152 ns`, `max_credits≈26` per `UNIT_TIME_INTERVAL=4 µs` |

---

## 2. What changed

| Area | Change | File |
|---|---|---|
| Host bench | **Unchanged** — `--reqsize`/`--pages-per-req` already present | `host/inflash_bench.c` |
| Sweep harness | New `scripts/nvmevirt_reqsize_sweep.sh` — RUN=1-guarded, shared CSV schema, host cores disjoint from `cpus=`. **Adds a prepopulate step** (see §2.1) | `scripts/nvmevirt_reqsize_sweep.sh` |
| Microtests | New `scripts/nvmevirt_microtest.sh` (Exp 4.A.4), prepopulating | `scripts/nvmevirt_microtest.sh` |
| Device-latency observer | `printk_ratelimited` of `(nsecs_target − nsecs_start)` in `conv_read` under `#if defined(INFLASH_COMPUTE)`; read via `dmesg \| grep inflash_dev_lat` | `conv_ftl.c` |
| In-flash-compute data path (§5.5) | Under `INFLASH_COMPUTE`, `__do_perform_io` copies only `COMPUTE_RESULT_SIZE` bytes for **reads** (page data is reduced on-device; only the negligible result returns to host). FTL still senses the full range, so timing is unchanged. | `io.c` |
| Loader bugfix | `load.sh` reload was broken (`grep -q` + `pipefail` SIGPIPE → "File exists"); changed to `grep …>/dev/null` | `scripts/load.sh` |
| Exp 4.B / §5 probes | `MDTS (6)→(9)` and a one-off `COMPUTE_RESULT_SIZE (64)→(4096)` — **both reverted** to defaults after the probe | `ssd_config.h` |
| Plots | Rewritten `scripts/nvmevirt_plot.sh` to reflect actual findings (host-e2e floor + device-latency `t_cmd` curve) | `scripts/nvmevirt_plot.sh` |

`conv_read`'s compute-path structure and `nsecs_target = max` logic are **not altered**.
`COMPUTE_RESULT_SIZE`/`FW_CH_XFER_LATENCY`/`NAND_CHANNEL_BANDWIDTH` are **not retuned** for any
headline number (the 4096 B run is an explicitly-labelled §5 sensitivity side-run only).

### 2.1 Correctness note — prepopulation is mandatory on NVMeVirt

`conv_read` (`conv_ftl.c:889`) **skips unmapped/invalid LPNs** (`continue`), charging *zero* NAND
latency. SwarmIO has no maptbl, so its sweep can read cold pages and still get the modeled delay;
on NVMeVirt, reading never-written LPNs returns instantly and fabricates false "convergence." The
sweep/microtest scripts therefore **prepopulate** (sequential writes) so every read hits a valid
mapping and charges tR. This was the one NVMeVirt-specific fix the SwarmIO port had missed.

---

## 3. Experiment 4.A — multi-page requests up to the MDTS=6 cap

### 3.1 Design
`K = reqsize/4096` pages/command, `R = 512/K` commands tiling all 512 LUNs once, issued at
`qdepth=R`. MDTS=6 → K ∈ {1,2,4,8,16,32,64} → R ∈ {512,256,128,64,32,16,8}.

### 3.2 Saturated-round results (512 LUNs / total_pages=512 in every row) — **measured**

| layout | R (commands) | reqsize | **host e2e** | device latency | T_model (38 µs ref) | rel_err vs 38 µs |
|---|---:|---:|---:|---:|---:|---:|
| 512 × 4 KB | 512 | 4 KB | **778.5 µs** | 30.15 µs | 38 µs | +1950 % |
| 256 × 8 KB | 256 | 8 KB | 559.7 µs | 30.15 µs | 38 µs | +1373 % |
| 128 × 16 KB | 128 | 16 KB | 434.9 µs | 30.15 µs | 38 µs | +1045 % |
| 64 × 32 KB | 64 | 32 KB | 374.9 µs | 30.15 µs | 38 µs | +887 % |
| 32 × 64 KB | 32 | 64 KB | **283.7 µs** (min) | 30.15 µs | 38 µs | +647 % |
| 16 × 128 KB | 16 | 128 KB | 369.3 µs | 30.15 µs | 38 µs | +872 % |
| 8 × 256 KB | **8** | 256 KB | 358.3 µs | 30.15 µs | 38 µs | +843 % |

**Findings:**
- **Device latency is a flat 30.15 µs** for every layout (read off `inflash_dev_lat`). The
  emulator's modeled per-round time is already at the floor and *below* the 38 µs reference.
- **Host e2e falls only ~2.2×** (778 → 358 µs) for a 64× reduction in command count, and is
  **non-monotonic** (min ≈ 284 µs at R=32, not at the smallest R). It never comes within an order
  of magnitude of the 30 µs device latency.
- **No K/R brings host e2e within 10 % of the 30 µs device floor** — the acceptance question is
  answered in the negative for the host metric, and trivially yes for the device metric (always
  within ~0.5 %).

### 3.3 Throughput-with-depth sweep (fixed K=64) — host e2e scales with *total pages*

| R per round | total_pages | rounds | host e2e | e2e / page |
|---:|---:|---:|---:|---:|
| 8 | 512 | 1 | 348.7 µs | 0.68 µs |
| 16 | 1024 | 2 | 749.0 µs | 0.73 µs |
| 32 | 2048 | 4 | 1553.0 µs | 0.76 µs |
| 64 | 4096 | 8 | 3477.9 µs | 0.85 µs |
| 128 | 8192 | 16 | 7338.9 µs | 0.90 µs |

Host e2e is **linear in total_pages at ≈ 0.7–0.9 µs/page**, regardless of how pages are packed
into commands. This is the signature of the single io_worker processing each per-page NAND op
serially in wall-clock — *not* the modeled `⌈total_pages/512⌉ × 38 µs` round behavior.

### 3.4 Microtests (Exp 4.A.4) — measured

| test | reqsize | LUNs | host e2e | device latency |
|---|---|---:|---:|---:|
| 1 × 256 KB (64 LUNs, 4/ch) | 256 KB | 64 | ~90 µs | 30.15 µs |
| 8 × 256 KB (512 LUNs, saturated) | 256 KB ×8 | 512 | ~358 µs | 30.15 µs |
| 2 × 256 KB same 64-LUN range | 256 KB ×2 | 64 (same) | ~192–290 µs | (2·tR at device — same-LUN serialization, per §1 prior) |

Same-LUN reads serialize on `next_lun_avail_time` (host e2e roughly doubles vs the single 256 KB
case), reproducing plane-level sensing serialization through the multi-page path.

---

## 4. Experiment 4.B — one command spanning all 512 LUNs (MDTS=9)

### 4.1 Design & result
Raised `MDTS (6)→(9)` (`max_hw_sectors_kb` confirmed 2048), prepopulated, issued single commands
at qdepth=1. This eliminates command-count serialization entirely (one dispatch per request).

| reqsize | pages | LUNs/ch | commands | **host e2e** | device latency |
|---:|---:|---:|---:|---:|---:|
| 4 KB | 1 | 1 | 1 | 43.5 µs | 30.15 µs |
| 256 KB | 64 | 4 | 1 | 117.1 µs | 30.15 µs |
| 512 KB | 128 | 8 | 1 | 176.4 µs | 30.15 µs |
| 1 MB | 256 | 16 | 1 | 381.2 µs | 30.15 µs |
| **2 MB** | **512** | **32** | **1** | **538.0 µs** | **30.15 µs** |

**This is the decisive result.** One 2 MB command — a *single* dispatcher fetch, *zero*
command-count serialization, all 512 LUNs addressed in one shot (the most direct realization of
"bigger requests, fewer requests fully utilize all planes") — still costs **538 µs** host e2e
while the device model reports **30.15 µs**. Host e2e even *exceeds* the 8×256 KB case (358 µs),
because a single qdepth-1 command gives the io_worker no inter-command overlap. **Command count is
not the host bottleneck; per-page simulation work is.**

---

## 5. Emergent t_cmd: measured, not tuned (the crux)

### 5.1 What the channel model actually produces at default knobs
With `COMPUTE_RESULT_SIZE=64 B`: each per-LUN result is `DIV_ROUND_UP(64, 128) = 1` transfer unit
= one `xfer_lat` ≈ 152 ns. A channel holds 26 credits per 4 µs slot, so even 32 such transfers in
one round never exhaust the budget → **no queuing delay** → device latency = tR + 152 ns,
**flat across load**:

| probe (single command, MDTS=9) | active LUNs/ch | device latency | emergent t_cmd |
|---|---:|---:|---:|
| 4 KB | 1 | 30,152 ns | 152 ns |
| 256 KB | 4 | 30,152 ns | 152 ns |
| 512 KB | 8 | 30,152 ns | 152 ns |
| 1 MB | 16 | 30,152 ns | 152 ns |
| 2 MB | 32 | 30,152 ns | 152 ns |

So the **measured emergent `t_cmd` ≈ 152 ns** — *not* the 2.6 µs analytic estimate (which assumed
the 80 ns/transfer figures serialize) and *not* the 8 µs original guess. Reported **as observed**.

### 5.2 The channel model *is* faithful — knob-sensitivity side-run (§5-permitted, one knob)
To confirm the flatness is a property of the tiny result size and not a dead model, a single run
with `COMPUTE_RESULT_SIZE=4096 B` (= 32 transfer units, enough to exhaust the 26-credit budget,
MDTS=9, then reverted) makes the emergent `t_cmd` appear and **scale with active-LUNs/channel**:

| active LUNs/ch | device latency (4096 B) | emergent t_cmd |
|---:|---:|---:|
| 1 | 34,864 ns | 4.86 µs |
| 4 | 46,864 ns | 16.86 µs |
| 8 | 66,864 ns | 36.86 µs |
| 16 | 102,864 ns | 72.86 µs |
| 32 | 134,864 ns | **104.86 µs** |

This is the load-dependent, physics-faithful behaviour SwarmIO's flat `sched_delay` cannot
reproduce — it just doesn't manifest at the default 64 B compute-result size, where the per-LUN
channel cost is genuinely negligible. (See `fig_nvmevirt_tcmd_vs_lunsperch.png`.)

### 5.3 Read-back procedure (device latency)
```bash
sudo dmesg -C                      # clear; printk is rate-limited (~10 msgs / 5 s)
sudo taskset -c 16-31 host/inflash_bench --dev /dev/nvme1n1 \
     --reqsize 262144 --requests 8 --qdepth 8 --trials 5     # saturated round
dmesg | grep inflash_dev_lat       # → "NVMeVirt: inflash_dev_lat 30152 ns"
```
(Prepopulate first — see §2.1 — or reads hit unmapped LPNs and report ~0.)

---

## 5.5 Follow-up: removing host data transfer — and the *true* host-side floor

A natural objection: in real in-flash compute, partial results are reduced/accumulated **on-device**
and only a negligible final output is returned — the host should never wait for page data. The
original harness violated this: the host posted a full `reqsize` O_DIRECT read and NVMeVirt
memcpy'd the full `reqsize` from the backing store (`io.c:__do_perform_io`, no compute guard). So
we added the §2 in-flash-compute guard (reads copy only `COMPUTE_RESULT_SIZE`; FTL still senses the
full range) and re-measured.

**Result: removing the data transfer barely moved host e2e (~5–12 %).** This *rules out* data
movement (and the io_worker memcpy) as the bottleneck:

| layout (512-LUN round) | host e2e — full copy | host e2e — copy capped to 64 B | Δ |
|---|---:|---:|---:|
| 512 × 4 KB (R=512) | 778 µs | 776 µs | ~0 % |
| 8 × 256 KB (R=8) | 358 µs | 322 µs | −10 % |
| 1 × 2 MB (MDTS=9, R=1) | 538 µs | 638 µs | none (within run-to-run variance) |

The single 2 MB command is decisive: **one dispatch, all 512 LUNs, only 64 B copied to host —
still ~638 µs** while the device model reports 30,152 ns. With data transfer *and* command count
*and* the io_worker memcpy all eliminated, the floor is unchanged.

**Root cause (measured at both ends, not inferred): NVMeVirt models the parallelism *correctly*;
the inflation is host-side.** Temporary probes (since removed) on the dispatch and completion paths
settle it definitively:

| quantity | measured | meaning |
|---|---:|---|
| `conv_read` wall-clock (dispatcher), 64-LUN command | **~1.5–2.4 µs** | per-LUN sim is *cheap* (~30 ns/LUN), not the floor |
| modeled `nsecs_target − nsecs_start` | 30,152 ns | the model |
| **device-observed latency** (NVMeVirt receive → CQ fill) | **30,162 ns (late 10 ns)** | io_worker delivers at the modeled time |
| host e2e (one 256 KB / 64-LUN command) | ~107 µs | model + host-side overhead |

So **the `io_worker` and timing model imitate LUN-level parallelism faithfully**: a command sensing
64 LUNs is device-observed to complete in 30 µs — the modeled time — delivered *10 ns* late. My
three earlier hypotheses (io_worker memcpy, dispatcher `conv_read` cost, command count) were **all
wrong**; the device side is correct end to end.

The remaining gap (107 µs host e2e − 30 µs device-observed ≈ 77 µs) is **entirely host-side and
outside NVMeVirt**: the Linux **O_DIRECT** path pins/unpins the request's pages, builds the PRP
list, and reaps the completion/IRQ — ≈ **1 µs per 4 KB page of the request**, on the submitting CPU.
This is why the floor tracks total pages in flight, and why capping the device-side copy (above)
barely helped: it never touched the host's per-page pinning.

**Implication for your assumption:** all-plane activation converges to ~30 µs, and NVMeVirt both
**computes and delivers** that (device-observed = 30 µs, late 10 ns). The host cannot *observe*
~30 µs only because it issues a *large* request and the kernel's O_DIRECT bookkeeping is O(pages).
The correct change is therefore **not** in NVMeVirt (its parallelism is faithful) but in the
request shape: a true in-flash-compute command has the host submit **one small request** (a few
pages) that internally triggers all-plane sensing — then host-side O_DIRECT cost is O(1) and host
e2e ≈ device-observed ≈ 30 µs. That is a host-protocol / bench change, not an `io_worker`
modification.

---

## 6. Where the latency goes (corrected unified model)

The host end-to-end latency decomposes as:

```
host_e2e ≈ T_device(≈30.15 µs, hidden — fully overlapped across LUNs)
         + c_page × total_pages        (single io_worker per-page NAND-op simulation, ≈0.7–0.9 µs/page)
         + c_cmd  × R                   (per-command / per-submission overhead, ≈0.4–0.8 µs/command)
         + host_overhead (io_uring, O_DIRECT)
```

- `T_device` is **not** additive with the per-page term — it is the *modeled* completion time, and
  it is dwarfed by and hidden behind the wall-clock simulation cost.
- Multi-page packing zeroes the `c_cmd × R` term (512 → 8 commands saves ≈ 420 µs) but leaves the
  dominant `c_page × total_pages` floor (≈ 358 µs for 512 pages) untouched.
- Exp 4.B (R=1) confirms: with the per-command term eliminated entirely, e2e is still
  `c_page × 512 ≈ 538 µs`.

| strategy | R | pages | c_cmd×R term | c_page×pages floor | measured e2e |
|---|---:|---:|---:|---:|---:|
| 512 × 4 KB (baseline) | 512 | 512 | ~large | ~358 µs | 778 µs |
| 8 × 256 KB (MDTS=6 best) | 8 | 512 | ~small | ~358 µs | 358 µs |
| 1 × 2 MB (MDTS=9) | 1 | 512 | ~0 | ~538 µs* | 538 µs |

\* qdepth=1 single command gives no io_worker overlap, so its per-page cost is higher than the
8-command pipelined case — the per-page floor is real either way.

**Caveat / lever:** this per-page wall-clock cost is a function of `cpus=` (here 1 io_worker on
cpu 8). More io_workers would parallelize per-page simulation and lower the host floor; it is a
property of NVMeVirt's *simulator throughput*, not of the modeled SSD.

---

## 7. Final verdict

- **Device model: already converged, and below the analytic reference.** A full 512-LUN round
  reports a flat **30.15 µs** device latency regardless of command count or request size — tR plus
  one ~152 ns channel-transfer unit. There is nothing to "fix"; the faithful model is at its floor.
- **Host e2e: does not converge via multi-page packing**, refuting the prompt's per-command
  mechanism. The min host e2e for a 512-LUN round is ~284 µs (R=32) and a single 2 MB command is
  ~538–638 µs — both an order of magnitude above the 30 µs device latency. Ruling out the
  alternatives experimentally (§5.5): it is **not** command count (1×2 MB still ~638 µs), **not**
  data transfer or io_worker memcpy (capping the read copy to 64 B changed e2e by ~5–12 %), and
  **not** the dispatcher's `conv_read` simulation (~1.5–2.4 µs for a 64-LUN command). NVMeVirt's
  **device-observed latency is the modeled 30 µs, delivered 10 ns late** — its LUN parallelism is
  faithful. The binding constraint is **host-side Linux O_DIRECT** page pinning/PRP/IRQ at
  ≈ 1 µs per 4 KB page of the request — outside NVMeVirt. Exposing ~30 µs host-side requires a
  small-request in-flash-compute command shape, not an emulator change.
- **Emergent `t_cmd` measured as ≈ 152 ns (flat) at default knobs** — smaller than every prior
  estimate — and shown to be a faithful consequence of the 64 B result size: the channel model
  *does* produce a load-dependent `t_cmd` (4.9 → 105 µs over 1 → 32 LUNs/ch) once results are large
  enough to exhaust the credit budget.
- **The prior 557 µs divergence is per-page simulation cost, not dispatcher command count** — the
  multi-page experiment is precisely what disambiguates the two, and it lands on per-page.

---

## 8. NVMeVirt vs SwarmIO comparison

| dimension | NVMeVirt (faithful) | SwarmIO (parameterized) |
|---|---|---|
| **Plane-level sensing** | Real: `tR=pg_rd_lat` per LUN vs `next_lun_avail_time` in `ssd_advance_nand()`; same-LUN ≈ 2·tR. | Abstracted occupancy; no explicit tR. |
| **t_cmd source** | **Emergent** from channel model. At default 64 B result it is ~152 ns (flat); it *scales* with LUNs/ch only when results exhaust the 26-credit/4µs budget (shown: 4.9→105 µs at 4096 B). | **Parameterized** flat `sched_delay≈38 µs`, constant. |
| **Device round latency (default)** | ≈ **30.15 µs**, flat (tR + 1 transfer unit). | ≈ 38 µs flat. |
| **Host-side bottleneck** | **Single io_worker per-page NAND-op simulation (~0.7–1.0 µs/page)** — scales with total pages. | **Single io_uring ring / SQ submission (~0.9 µs/page)** — scales with submissions. |
| **Does multi-page packing converge host e2e?** | **No.** 778→358 µs (≈2.2×); 1×2 MB still 538 µs. Per-page sim floor dominates. | **Yes (largely).** Fewer submissions → e2e fell toward the modeled round. |
| **Convergence at R=8 / K=64** | host 358 µs vs 30 µs device (≈ 12× above); device itself 30.15 µs. | ~397 µs vs 38 µs (min near R=32). |
| **Convergence at R=1 / single cmd** | host 538 µs (Exp 4.B 2 MB); device 30.15 µs. | ~479 µs (Exp 3.B 2 MB; ~0.9 µs/page host cost). |

**Key distinction.** NVMeVirt cleanly separates a *converged device-timing model* (≈ 30 µs, with a
genuinely emergent, load-dependent — if at default knobs negligible — `t_cmd`) from a
*host-simulation throughput wall* (single io_worker, per-page). SwarmIO folds the whole round into
one tuned `sched_delay` and its host wall is the submission ring. The faithful leg's lesson is that
the **device physics is not the limiter at all** at default knobs — the modeled round is ~30 µs —
and the real ceiling on *observed* latency is simulator-internal per-page processing, which neither
multi-page packing nor MDExpansion can remove (only more io_workers can).

---

## 9. Reproduce

```bash
cd /home/juchanlee/nvmevirt_pim
bash scripts/build.sh                              # instrumented module, default knobs
sudo rmmod swarmio 2>/dev/null; sudo rmmod nvmev 2>/dev/null
# Exp 4.A (loads, prepopulates 8192 pages, sweeps; MDTS=6):
RUN=1 TRIALS=15 bash scripts/nvmevirt_reqsize_sweep.sh results_nvmevirt_reqsize_raw.csv
RUN=1 bash scripts/nvmevirt_microtest.sh           # Exp 4.A.4 microtests
dmesg | grep inflash_dev_lat                       # device latency ≈ 30152 ns

# Exp 4.B: set #define MDTS (9) in ssd_config.h, rebuild, reload, prepopulate, then:
sudo taskset -c 16-31 host/inflash_bench --dev /dev/nvme1n1 \
     --reqsize 2097152 --requests 1 --qdepth 1 --trials 15   # one 2 MB command
# REVERT MDTS to (6), rebuild, reload. (max_hw_sectors_kb back to 256.)

# Enrich + plot:
python3 scripts/swarmio_model.py results_nvmevirt_reqsize_raw.csv results_nvmevirt_reqsize_enriched.csv
bash scripts/nvmevirt_plot.sh
```

---

## 10. Data & figures

- `results_nvmevirt_reqsize_raw.csv` / `_enriched.csv` — Exp 4.A saturated-round + throughput sweep (MDTS=6, host e2e).
- `results_nvmevirt_tcmd_raw.csv` — device-latency / emergent-`t_cmd` characterization (default 64 B + 4096 B §5 side-run).
- `results_nvmevirt_mdts9_raw.csv` — Exp 4.B single-command sweep (device latency vs LUNs/ch, default 64 B).
- `fig_nvmevirt_e2e_vs_cmdcount.png` — host e2e vs R (saturated round) with the flat ~30 µs device floor and 38 µs reference.
- `fig_nvmevirt_tcmd_vs_lunsperch.png` — emergent `t_cmd` vs active-LUNs/channel: flat at 64 B, scaling at 4096 B.
- `fig_nvmevirt_vs_swarmio.png` — NVMeVirt vs SwarmIO host-e2e-vs-R overlay.

Final module state: **MDTS reverted to (6)** (256 KB, realistic default); `COMPUTE_RESULT_SIZE=64`,
`FW_CH_XFER_LATENCY=0`, `NAND_CHANNEL_BANDWIDTH=800 MB/s` preserved. The instrumented module
(`inflash_dev_lat` observer) remains loaded.

---

## 11. Experiment 5 — the fix: decouple the on-device sensing extent from the host transfer size

§5.5 concluded that the host-side inflation is **O(pages-in-request)** Linux O_DIRECT bookkeeping,
outside NVMeVirt, and that the correct remedy is a *true in-flash-compute command shape*: the host
submits **one small request** that internally triggers all-plane sensing. This section **implements
that command shape and measures it.** The result confirms the prediction: all-plane host e2e drops
from **538 µs (old 2 MB shape) → ~48 µs (new 1-page compute shape)**, an **≈ 11× reduction**, while
the device still senses **all 512 planes** (verified, not assumed).

### 11.1 What changed (the decoupling)

| Area | Change | File |
|---|---|---|
| Sensing-extent knob | New `#define COMPUTE_SENSE_PAGES (512)` — the on-device sensing extent for a compute command, **independent of NLB** | `ssd_config.h` |
| `conv_read` | Under `INFLASH_COMPUTE`, a **single-page** read (`start_lpn == end_lpn`) is interpreted as a compute trigger: `end_lpn`/`nr_lba` are expanded to sense `COMPUTE_SENSE_PAGES` consecutive LPNs (all-plane activation). NLB (`cmd->rw.length`) governs **only** the host DMA; the sensed range is set device-side. Multi-page reads keep their natural range (Exp 4.A/4.B unaffected). | `conv_ftl.c` |
| Device observer | `inflash_dev_lat` line now also prints `(sensed <N> pages)` — so the on-device extent is **provable from dmesg**, not inferred (the latency number alone cannot distinguish 1 vs 512 LUNs at a 64 B result). | `conv_ftl.c` |
| Host bench | New `--compute` flag: forces `reqsize=4096` (host pins **one** page); self-documents the command shape. | `host/inflash_bench.c` |

**Design choice — why a device-side extent register and not a per-command NVMe CDW.** A real vendor
opcode would carry the sense-extent in a command dword, but that forces the host onto the NVMe
**passthrough ioctl** path, whose page-pinning behaviour differs from the O_DIRECT block path this
entire report measures — it would confound the comparison. Putting the extent device-side keeps the
host on the **unchanged io_uring / O_DIRECT path**, isolating exactly the variable of interest:
**host transfer pages 512 → 1, on-device sensing stays 512 planes.**

### 11.2 Measured (default knobs, MDTS=6, same build) — `results_nvmevirt_compute_raw.csv`

| layout | host shape | host pages pinned | planes sensed | **host e2e (median)** | device latency |
|---|---|---:|---:|---:|---:|
| E1 — one 256 KB command | OLD multi-page | 64 | 64 | **~74 µs** | 30,152 ns *(sensed 64 pages)* |
| E2 — one 1-page `--compute` | **NEW compute** | **1** | **512** | **~48 µs** | 34,152 ns *(sensed 512 pages)* |
| 2 MB command (Exp 4.B, prior) | OLD multi-page | 512 | 512 | **538 µs** | 30,152 ns |

Plus scaling sanity (NEW compute shape):
- **E3a** 8 compute commands, qdepth 1 (sequential): e2e ≈ 337 µs, **per-op p50 ≈ 42 µs** (≈ E2).
- **E3b** 8 compute commands, qdepth 8 (pipelined): e2e ≈ **52 µs** — the commands share one device
  round, so issuing 8 all-plane computes back-to-back costs barely more than one.

### 11.3 Findings

1. **The decoupling works and is verified end to end.** dmesg proves a **1-page** host request makes
   the device **sense 512 pages** (`inflash_dev_lat 34152 ns (sensed 512 pages)`). The host pinned a
   single page; the device activated every plane.

2. **All-plane host e2e converged from 538 µs → ~48 µs (≈ 11×).** The per-page O_DIRECT wall that
   §5.5 identified is **gone**, because it was O(request-pages) and the request is now O(1) pages.
   The clinching evidence that the host cost is now plane-independent: **E2 senses 8× more planes
   than E1 (512 vs 64) yet costs *less* host e2e (~48 µs vs ~74 µs)** — because it pins 1 page
   instead of 64. Host overhead now tracks *host pages*, which is fixed at 1, not *planes sensed*.

3. **The residual ~14 µs (≈ 48 µs e2e − 34 µs device) is the irreducible O(1) host floor** — one
   `io_uring` submit/complete, one syscall, one IRQ reap, one page pin/unpin. It does **not** grow
   with planes or request size. Driving it below this would require kernel-bypass (SPDK) or polled
   completion (`IORING_SETUP_IOPOLL`) to remove the IRQ/syscall cost — diminishing returns well past
   the point of the exercise.

4. **Refinement to the device floor: a single command sensing all 512 planes costs 34,152 ns, not
   30,152 ns.** The extra ~4 µs is the **emergent channel `t_cmd` at full 32-LUN/channel load**: 32
   per-LUN 64 B results = 32 transfer units against the 26-credit / 4 µs budget, so one extra credit
   slot (~4 µs) is incurred — exactly the load-dependent behaviour §5.2 predicted. The prior Exp 4.B
   "2 MB → 30,152 ns" figure most plausibly reflects the block layer **splitting** the 2 MB transfer
   into sub-512-LUN commands (each <26 transfers/channel → no queuing); the new path is a *single*
   verified 512-LUN command, so it exposes the true full-load device latency. **tR (30 µs) still
   dominates; the all-plane device floor is ≈ 34 µs.**

### 11.4 Answer to the driving question

> *"How do I make end-to-end latency of in-flash computing converge to ~30 µs per all-plane
> activation? The report says host-side latency (~77 µs) is the problem — how to reduce it? Can I
> parallelize it?"*

- **The ~77 µs was not a thing to parallelize — it was O(request-pages) and had to be *eliminated*,
  not spread across cores.** Parallelizing (more submitter threads / more `io_workers`) would only
  distribute the same aggregate per-page work across CPUs and would contradict the single-command,
  all-plane model. The fix is to stop sending the pages at all.
- **Doing so (one small request + device-side all-plane sensing) converges host e2e to ~48 µs**,
  i.e. the all-plane **device latency (~34 µs) plus a fixed ~14 µs host O(1) floor**. The page-scaling
  term is eliminated; your original assumption holds: **all-plane activation is a ~30 µs (tR-bound)
  device event**, and the host now observes it within a small constant rather than ~11× inflated.
- The change is a **host-protocol / command-shape change** (now implemented), **not** an `io_worker`
  or timing-model modification — NVMeVirt's LUN parallelism was faithful all along.

### 11.5 Reproduce

```bash
cd /home/juchanlee/nvmevirt_pim
bash scripts/build.sh                              # COMPUTE_SENSE_PAGES=512, default knobs, MDTS=6
sudo bash scripts/run_compute_exp.sh               # reload + prepopulate + E1/E2/E3, prints dmesg
# Key line proving the decoupling:
#   NVMeVirt: inflash_dev_lat 34152 ns (sensed 512 pages)   ← 1-page host request, all planes sensed
```

### 11.6 Updated module state

`COMPUTE_SENSE_PAGES=512` (single-page reads now trigger all-plane compute — note this redefines the
lone-4 KB read from a 1-LUN op into a 512-LUN compute op); MDTS=(6); `COMPUTE_RESULT_SIZE=64`,
`FW_CH_XFER_LATENCY=0`, `NAND_CHANNEL_BANDWIDTH=800 MB/s` preserved. Observer (`inflash_dev_lat …
(sensed N pages)`) remains loaded.

---

## 12. Experiment S — SPDK (kernel-bypass) host path

§11 converged the 1-page in-flash-compute command to **~48 µs host e2e** and attributed the residual
**~14 µs (48 − 34 µs device)** to an *O(1)*, removable host-stack cost — page pinning, the
`io_uring_enter` syscall, and IRQ→softirq→wakeup→context-switch reaping — arguing it would fall to
~1–3 µs under kernel-bypass. **This section removes that residual at the source with SPDK and measures
the result, turning the argument into a curve.** SPDK pre-registers hugepage DMA buffers (no
`get_user_pages` per I/O), issues zero hot-path syscalls (userspace MMIO doorbell + CQ read), and
busy-polls completions (no interrupt). The device timing model is **not** touched — same NVMeVirt,
same `COMPUTE_SENSE_PAGES`, same `conv_read`; only the host I/O path changes.

### 12.1 Feasibility gate (Phase 0) — **PASS, via `uio_pci_generic`**

The one real risk was whether SPDK can bind and enumerate NVMeVirt's *software-emulated* PCIe
controller. Settled empirically (no benchmark code), with an explicit verdict:

| Bind path | Result | Evidence |
|---|---|---|
| **`vfio-pci`** (preferred) | ❌ **structurally impossible** | `vfio-pci: probe of 0001:11:00.0 failed with error -22`. The device has **no IOMMU group** — NVMeVirt registers a *software* PCI root bus (`pci_bus_add_devices(virt_bus)`, `main.c`) on synthetic domain `0001:`, which the hardware DMAR never enumerates. **A GRUB `intel_iommu=on` + reboot would not help** — there is no DMAR unit behind a software root bus to place it in a group. |
| **`uio_pci_generic`** (fallback) | ✅ **binds** | `0001:10:00.0 (0c51 0110): nvme -> uio_pci_generic`; creates `/dev/uio0`. (Despite the device declaring no INTx pin — config 0x3d = 0x00, MSI-X-only — the kernel accepts it; SPDK reads BAR0 via the `resource0` sysfs mmap and never needs the interrupt because it polls.) |
| **no-IOMMU DMA model** | ✅ **compatible** | NVMeVirt resolves PRP entries as **physical addresses** — `kmap_atomic_pfn(PRP_PFN(paddr))` / `memremap(paddr,…)` then `memcpy` (`io.c:95–128`). This is exactly what the kernel `nvme` driver already feeds it in no-IOMMU mode, so SPDK's `IOVA=PA` hugepages (physical addresses programmed straight into the PRPs) are resolved identically. |

**Gate criterion met (both halves):**
- `spdk_nvme_identify` fully enumerates the controller: `NVMe Controller at PCIE (0001:10:00.0)
  [0c51:0110]`, Model `CSL_Virt_MN_01`, **Max Data Transfer Size 262144** (= 256 KB, the MDTS=6 build),
  1 namespace, 4 KB page, NVM command set supported.
- `hello_world` **writes a page and reads it back** (`Hello world!`) over SPDK + `uio_pci_generic` +
  physical-address DMA — proving the no-IOMMU DMA path works in both directions on the emulated device.

> **Verdict: SPDK *can* drive the emulated NVMeVirt device — over `uio_pci_generic`, not `vfio-pci`.**
> The VFIO route is blocked by a fundamental property of software PCI emulation (no IOMMU group), which
> is itself a reportable finding; the uio route sidesteps it because polled SPDK needs neither an
> interrupt nor IOMMU translation. Binding requires no GRUB/reboot/BIOS change.

### 12.2 S1a (primary) — the 1-page compute command, measured

`results_nvmevirt_spdk_raw.csv`, default knobs, MDTS=6, Option-1 build, 15 trials, host on one E-core
(SPDK core mask `0x10000`), NVMeVirt on `cpus=7,8`, 1024×2 MB hugepages, device prepopulated.

| host stack | host e2e (median) | min – max | host residual (e2e − 34,152 ns) | device latency (dmesg) |
|---|---:|---:|---:|---:|
| io_uring / `O_DIRECT` (§11 E2) | ~48 µs | ~46 – 200 µs | **~13.8 µs** | 34,152 ns *(sensed 512)* |
| **SPDK (uio, polled)** | **34.84 µs** | **34.78 – 35.67 µs** | **0.68 µs** | **34,152 ns *(sensed 512)*** |

Three results, all verified:

1. **The device model is untouched.** dmesg under SPDK shows `NVMeVirt: inflash_dev_lat 34152 ns
   (sensed 512 pages)` for the isolated command — *byte-identical* to the io_uring leg. The single-page
   SPDK read still triggers all-plane sensing; SPDK is a host-stack change only, exactly as designed.
2. **Host e2e collapses onto the device floor.** 34.84 µs median is **0.68 µs above** the modeled
   34,152 ns — the ~14 µs io_uring residual is **gone** (≈ 20× smaller; the host term is now ~2 % of
   the device floor, not ~40 %). The end-to-end number the *host* measures now **equals** `tR +
   emergent t_cmd` without asking the reader to subtract anything. (Figure: `fig_nvmevirt_spdk_e2e.png`.)
3. **Variance collapses.** SPDK holds a **0.9 µs band** (34.78–35.67 µs, p99 = 35.67 µs, p99−p50 ≈
   0.7 µs) across 15 trials; the io_uring run swung 46→200 µs cold/warm. Polling eliminates the
   scheduler/IRQ cold-start outliers entirely. (Figure: `fig_nvmevirt_spdk_variance.png`.)

### 12.3 S1b / S1c (scaling) — and a correction to §11's E3b

| run | shape | SPDK e2e | SPDK per-op p50 | io_uring (§11) |
|---|---|---:|---:|---:|
| S1c | 8 compute cmds, **qd1** (sequential) | ~278 µs | **34.7 µs** | E3a: 337 µs, ~42 µs/op |
| S1b | 8 compute cmds, **qd8** (pipelined) | **~245 µs** | 154.7 µs (p99 244.7 µs) | E3b: ~52 µs |

- **S1c is clean and confirms S1a:** eight sequential all-plane computes cost 8 × 34.7 µs ≈ 278 µs, and
  the *per-op* p50 (34.7 µs) is the S1a number — each is an independent 34 µs device event with ~0 host
  cost. SPDK is faster per op than io_uring (34.7 vs ~42 µs).
- **S1b corrects §11's E3b.** §11 reported ~52 µs for 8 pipelined computes ("device round shared"). The
  SPDK polled path, which submits all 8 commands near-simultaneously, exposes a different — and
  physically correct — truth: **concurrent all-plane computes serialize on the device, because each one
  senses *every* plane.** The dmesg ladder is unambiguous:
  ```
  inflash_dev_lat 34152 ns (sensed 512 pages)    ← op 1
  inflash_dev_lat 43166 ns (sensed 512 pages)    ← op 2
  inflash_dev_lat 61171 / 79843 / 98890 / 117577 / 136706 / 157441 ns   ← ops 3–8
  ```
  Each command's modeled completion is pushed later because the LUNs are still busy sensing the prior
  command's range — so qd8 does **not** help all-plane ops (they contend for the same 512 planes), and
  e2e ≈ the 8th command's ~157 µs device-time plus tail ≈ 245 µs. §11's "~52 µs / shared round" most
  plausibly reflects io_uring **not** achieving true device-concurrency at qd8 (kernel submission gaps);
  it does not survive a stack that submits all eight at once. **This sharpens the model: pipelining wins
  for distinct-plane commands but cannot for all-plane compute — the planes are the serial resource.**
  (S1a, the single command, is the headline and is unaffected.)

### 12.4 S2 — decomposing what SPDK removed (~13.8 µs → 0.68 µs)

SPDK removes three io_uring costs at once; the **aggregate** is measured (residual 13.8 µs → 0.68 µs),
and the split is bounded/reasoned (a precise per-term split would need the §6 in-kernel variants, see
12.6):

1. **IRQ → softirq → wakeup → context-switch (dominant).** Removed by CQ busy-poll. This term carries
   the **cold-start tail**: the io_uring max was 200 µs, SPDK's is 35.67 µs — the ~165 µs of cold
   outlier is almost entirely scheduler/IRQ wakeup latency, which polling deletes. In steady state it is
   the largest part of the ~13 µs median gap.
2. **`io_uring_enter` syscall (per submit + per reap).** Removed: SPDK rings the SQ doorbell with a
   userspace MMIO write and reads the CQ from memory — **zero hot-path syscalls**. Bounded at a few µs;
   the closest in-kernel analog is io_uring SQPOLL (§6).
3. **Per-I/O page pinning + PRP build.** Removed: SPDK buffers are `spdk_zmalloc`'d once and pre-
   registered. **This term is ~0 at one page** — which is the whole point of Option-1 (§11) — and is the
   reason the residual could reach 0.68 µs rather than merely a few µs. It would grow for multi-page
   requests; at the 1-page compute shape it does not.

The 0.68 µs SPDK residual is the irreducible cost of *one* CQ poll iteration + command dispatch — i.e.
the host is now essentially free, and e2e is the device.

### 12.5 Answer to the §11 open question ("would kernel-bypass remove the residual?")

**Yes, and completely.** §11 left the ~14 µs as "removable in principle." It is removable in practice:
under SPDK the 1-page in-flash-compute command's **end-to-end latency itself (34.84 µs) — not just the
device-internal number — matches the `tR + control` assumption**, within 0.68 µs, with sub-µs jitter.
The ~14 µs io_uring residual was an **artifact of the commodity Linux O_DIRECT/io_uring path**, not of
in-flash compute, and it is gone the moment the host stack is bypassed. For the paper this means the
reviewer no longer has to mentally subtract host overhead: the measured host number *is* the device
event. The device model (34,152 ns, 512 planes) and the emergent `t_cmd` are unchanged across both host
stacks — two host stacks, one faithful device, a clean two-point validation curve over a flat floor.

### 12.6 Notes, fallback status, and reproduce

- **The §6 fallback (in-kernel polling) was not needed** — the SPDK gate passed. For the record,
  full io_uring `IORING_SETUP_IOPOLL` is **not currently available** on this device anyway: NVMeVirt
  advertises **0 poll queues** (`dmesg: nvme nvme1: 1/0/0 default/read/poll queues`), so a clean
  IRQ-vs-poll in-kernel split would require adding poll-queue support to NVMeVirt. SPDK sidesteps this
  entirely by polling the CQ in userspace.
- **Driver restored.** The device is bound back to the kernel `nvme` driver (`setup.sh reset`);
  `/dev/nvme1n1` is present, so the io_uring bench works again. Binding to SPDK removes `/dev/nvme1n1`,
  so the two host stacks must run in separate phases (the harness does this and restores on exit).

```bash
cd /home/juchanlee/nvmevirt_pim
bash scripts/build.sh && make -C host && make -C host spdk SPDK_DIR=/home/juchanlee/spdk
# Phase 0 gate + S1a/b/c + dmesg read-back + restore (binds ONLY the NVMeVirt BDF):
sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk BDF=0001:10:00.0 bash scripts/nvmevirt_spdk_exp.sh
# Key lines proving device model is untouched under SPDK:
#   NVMe Controller at PCIE (0001:10:00.0) [0c51:0110]      ← identify enumerates the emulated dev
#   NVMeVirt: inflash_dev_lat 34152 ns (sensed 512 pages)   ← single-page SPDK read, all planes sensed
python3 scripts/plot_spdk.py    # fig_nvmevirt_spdk_e2e.png, fig_nvmevirt_spdk_variance.png
```

**Artifacts:** `host/inflash_bench_spdk.c` (+ `make -C host spdk`), `scripts/nvmevirt_spdk_exp.sh`,
`results_nvmevirt_spdk_raw.csv` (schema + `host_stack` column), `fig_nvmevirt_spdk_e2e.png`,
`fig_nvmevirt_spdk_variance.png`, `reports/spdk_dmesg_proof.txt`. No changes to `conv_read`'s compute
path, `COMPUTE_SENSE_PAGES`, or device knobs. SPDK v25.05.1 built at `/home/juchanlee/spdk`.

---

## 13. Single-plane mode — one NVMe request senses one plane (and all-plane vs single-plane)

Everything above uses **all-plane** activation: a single 1-page NVMe read triggers the device to sense
all 512 planes at once (§11's `COMPUTE_SENSE_PAGES` expansion). This section adds the **opposite**
mode — *one NVMe request senses exactly one page/plane*, so activating all 512 planes takes **512
separate NVMe requests** — and compares the two head to head through the SPDK host path. Both modes
coexist; the prior behaviour is the default.

### 13.1 What changed (a runtime toggle, backward-compatible)

The on-device sensing extent is now a **module parameter** instead of a compile-time constant, so the
mode is selected at `insmod` with **no rebuild** and the old behaviour is the default:

| Area | Change | File |
|---|---|---|
| Sensing extent | New `module_param compute_sense_pages` (uint, 0644), default initialised to `COMPUTE_SENSE_PAGES` (512). `512` → all-plane; `1` → single-plane. | `main.c` |
| `conv_read` | The single-page compute expansion now tests/uses the runtime `compute_sense_pages` (`extern`) instead of the `COMPUTE_SENSE_PAGES` macro: `if (start_lpn==end_lpn && compute_sense_pages>1) end_lpn = start_lpn + compute_sense_pages - 1`. At `=1` the condition is false → **no expansion**, so a single-page read senses one plane. | `conv_ftl.c` |

```bash
sudo insmod nvmev.ko memmap_start=96G memmap_size=16G cpus=7,8                       # all-plane (default, 512)
sudo insmod nvmev.ko memmap_start=96G memmap_size=16G cpus=7,8 compute_sense_pages=1 # single-plane
```

**Compatibility:** the default value is `COMPUTE_SENSE_PAGES`, so every prior build/experiment (§11
io_uring, §12 SPDK) reproduces unchanged; `results_nvmevirt_compute_raw.csv` and §12's S1a are the
`compute_sense_pages=512` rows. `host/inflash_bench_spdk.c` is unchanged — single-plane "512-plane
activation" is simply `--requests 512` (512 single-page reads tile LPNs 0..511, one per LUN under
round-robin striping).

### 13.2 Measured (SPDK host path, default knobs, 15 trials) — `results_nvmevirt_spdk_modes_raw.csv`

| mode (`compute_sense_pages`) | planes activated | **NVMe cmds** | qdepth | **host e2e (median)** | per-op p50 | device latency (dmesg) |
|---|---:|---:|---:|---:|---:|---|
| all-plane (512) | **512** | **1** | 1 | **34.82 µs** | 34.8 µs | `34152 ns (sensed 512 pages)` |
| single-plane (1) | 1 | 1 | 1 | 30.79 µs | 30.7 µs | `30152 ns (sensed 1 pages)` |
| single-plane (1) | **512** | **512** | 512 | **144.3 µs** | 61.0 µs (p99 104.7) | `30152 ns/op (sensed 1 pages)` |
| single-plane (1) | **512** | **512** | 64 | **283.5 µs** | 32.3 µs (p99 37.7) | `30152 ns/op (sensed 1 pages)` |

dmesg verifies the toggle directly: single-plane prints `sensed 1 pages` at **30,152 ns** (pure tR, no
emergent `t_cmd` — one LUN never contends for a channel credit), while all-plane prints `sensed 512
pages` at **34,152 ns** (tR + the ~4 µs full-load `t_cmd` of §11.3).

### 13.3 Findings — why the device-side all-plane primitive wins

1. **Per command, single-plane is *cheaper* (30.8 vs 34.8 µs)** — it senses one LUN and dodges the
   ~4 µs emergent channel `t_cmd` that 512-LUN contention adds. That 4 µs is the *only* device-model
   price the all-plane command pays.
2. **But for the real task — activating all 512 planes — all-plane is ~4.2× faster end-to-end
   (34.8 µs vs 144.3 µs)**, because it does it in **one** NVMe command. Single-plane must issue **512**
   commands, and even at full qd512 the host's single-core submit/poll and NVMeVirt's single
   dispatcher/io_worker (`cpus=7,8`) serialise their *processing* (≈ 282 ns/cmd × 512 ≈ the 144 µs
   floor), even though the planes themselves sense in parallel device-side. The +4 µs `t_cmd` the
   all-plane command pays is trivial next to the ~110 µs of per-command overhead it *avoids*.
3. **Queue depth matters a lot for single-plane, not at all for all-plane.** Single-plane 512-cmd e2e
   is 144 µs at qd512 but **283 µs at qd64** (8 serialised batches of 64) — the host/dispatcher
   pipeline must be kept full. All-plane has nothing to pipeline: one command, qd-independent, 34.8 µs.
4. **This is the quantitative case for the in-flash-compute primitive being device-side.** Pushing
   "sense all planes" into one command converts 512 host round-trips into one and amortises the entire
   host+dispatcher per-command cost; the host stays O(1) (§11) *and* the command count stays O(1). The
   single-plane mode is the faithful "naïve host-orchestrated" baseline that makes that saving visible.

> Caveat (consistent with §12.3's S1b): the single-plane 512-cmd e2e is dominated by NVMeVirt's
> *single* dispatcher/io_worker draining 512 commands, not by NAND — it measures the emulator's
> per-command host-facing throughput, which is exactly the cost the all-plane primitive removes.

### 13.4 Does streaming many sets amortize single-plane down to ~30 µs? (No — it's throughput-bound)

A natural follow-up: the single-plane 512-cmd batch is ~144 µs; if that were mostly a *fixed* per-batch
overhead, streaming many back-to-back 512-sets would amortize it toward the ~30 µs device floor. It does
**not**. Streaming sweep (single-plane, SPDK, qd512, the only variable is how many 512-cmd sets are
issued in one e2e window) — `results_nvmevirt_spdk_singleplane_throughput.csv`:

| sets (×512 cmds) | total cmds | e2e median | **amortized µs / 512-plane set** | per-cmd |
|---:|---:|---:|---:|---:|
| 1 | 512 | 188.6 µs | 188.6 µs | 368 ns |
| 2 | 1024 | 340.8 µs | 170.4 µs | 333 ns |
| 4 | 2048 | 595.2 µs | 148.8 µs | 291 ns |
| 8 | 4096 | 1115.5 µs | 139.4 µs | 272 ns |
| 16 | 8192 | 2222.9 µs | **138.9 µs** | 271 ns |

**Streaming amortizes the *fixed startup* (pipeline fill + warm-up: 188 → 139 µs, ~26 %), then flattens
at a ~139 µs/512-set asymptote (~271 ns/command).** It converges to a **per-command throughput floor**,
not to 30 µs — because the cost is *per command*, not a one-time batch overhead: NVMeVirt's single
dispatcher runs `conv_read` on one SQE at a time and one host core polls, so 512 commands cost ~512 ×
271 ns regardless of the fact that the 512 planes themselves sense in parallel device-side. To reach
~30 µs per 512-plane set you would need ~59 ns/command (~4.6× more command-processing throughput than
one dispatcher + one poll core delivers — i.e. more `cpus=` dispatcher cores and/or multiple host
qpairs across cores, which scales *command throughput*, not free amortization).

**Bottom line for the hypothesis:** more sets ≠ convergence to 30 µs. The single-plane asymptote
(~139 µs) is still ~4× the all-plane primitive's 34.8 µs and ~4.6× the 30 µs device floor — because
all-plane is **O(1) commands** (one doorbell/one completion for all 512 planes) while single-plane is
**O(512) commands** no matter how you batch them. That O(1)-vs-O(512) command count, not any fixed
overhead, is the gap; it is the quantitative reason the all-plane primitive belongs device-side.

### 13.5 Can more parallelism rescue single-plane? io_worker scaling (No — the single dispatcher is the wall)

The natural objection to §13.4 is "your single dispatcher is the artifact — give NVMeVirt more threads
and single-plane will scale." NVMeVirt's `cpus=<list>` makes the **first** CPU the (single) dispatcher
and the **rest** io_workers, so this is a free knob for the *completion* side. Sweep (single-plane,
SPDK, qd512; amortized floor from N=4096) — `results_nvmevirt_spdk_ioworker_sweep.csv`:

| io_workers | `cpus=` | e2e (1 set) | **amortized µs / 512-plane set** | per-cmd |
|---:|---|---:|---:|---:|
| 1 | 7,8 | 153 µs | 124.9 µs | 244 ns |
| 3 | 7,8,9,10 | 153 µs | 134.8 µs | 263 ns |
| 5 | 7,8,9,10,11,12 | 160 µs | 136.6 µs | 267 ns |

**Adding io_workers does not lower the floor — it is flat (slightly worse, from cross-core
coordination on an intake-bound workload).** So the limiter is **not** completion/copy parallelism; it
is the **single dispatcher thread** that polls every SQ doorbell and runs `conv_read` per command
(`nvmev_dispatcher` → `nvmev_proc_dbs`, one thread for all queues). The free knob cannot close the
single-plane gap; only **multiple dispatchers** — a code change partitioning SQ doorbell polling across
threads (e.g. dispatcher *i* serves SQs `i::Ndisp`) — would raise command-*intake* throughput.

**What this means for the paper (important framing).** The ~139 µs single-plane floor is set by
NVMeVirt's single command-intake thread — it is an **emulator throughput artifact, not a NAND or
hardware limit**; real hardware with many queues and parallel command processors would post a lower
absolute number. So do **not** present 139 µs as "the hardware cost of single-plane." The **durable,
hardware-independent** claim is the **command complexity: single-plane is O(512) NVMe commands,
all-plane is O(1)** — one doorbell, one PRP fetch, one CQ entry, one completion for all 512 planes.
Multi-queue / multi-dispatcher is a perfectly realistic NVMe design and a reviewer will accept it, but
it only *scales the throughput* used to orchestrate 512 per-plane commands; it never removes the
per-command work. That is precisely the cost the device-side all-plane primitive avoids by construction
— which is the architectural argument, independent of how many threads the controller has.

### 13.6 Reproduce & module state

```bash
make -C host spdk SPDK_DIR=/home/juchanlee/spdk
sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk bash scripts/nvmevirt_spdk_mode_exp.sh
#   ALL-PLANE   : insmod ... (default)            -> dmesg "inflash_dev_lat 34152 ns (sensed 512 pages)"
#   SINGLE-PLANE: insmod ... compute_sense_pages=1 -> dmesg "inflash_dev_lat 30152 ns (sensed 1 pages)"
```

Per-config CSVs: `results_spdk_allplane_1req_512planes.csv`,
`results_spdk_singleplane_1req_1plane.csv`, `results_spdk_singleplane_512req_512planes_qd{512,64}.csv`.

§13.4 throughput sweep (CSV `results_nvmevirt_spdk_singleplane_throughput.csv`): in single-plane mode,
prepopulate then issue increasing command counts at qd512, e.g.
`inflash_bench_spdk --bdf <BDF> -m 0x10000 --compute --requests {512,1024,2048,4096,8192} --qdepth 512`,
and divide e2e by (requests/512) for the amortized per-512-plane-set cost. **Caveat learned: write the
CSV to the repo dir, not `/tmp`** — a `--csv` open failure makes the bench exit without detaching, which
leaves the emulated controller in a *failed* state (later `spdk_nvme_probe` then fails); recover with
`setup.sh reset` + module reload.

§13.5 io_worker scaling (CSV `results_nvmevirt_spdk_ioworker_sweep.csv`):
`sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk bash scripts/nvmevirt_spdk_ioworker_sweep.sh` — reloads
single-plane with `cpus=7,8` / `7,8,9,10` / `7,8,9,10,11,12` (1/3/5 io_workers, one dispatcher each) and
measures the qd512 floor; restores the default at the end.

**Module restored to the default all-plane mode** (`compute_sense_pages=512`) after the run, so
`/dev/nvme1n1` and §11/§12 behaviour are intact.

---

## 14. Multi-dispatcher: scaling controller cores (does it rescue single-plane?)

§13.5 hypothesised that NVMeVirt's **single dispatcher** is the wall holding the single-plane
512-plane-activation floor at ~144 µs (~271 ns/cmd) — far above the ~30 µs flash round — and that
io_worker scaling could not move it because all commands still funnel through one dispatcher. §14 tests
that hypothesis directly: **scale the controller, keep the flash fixed**, and see how close single-plane
can get to the flash floor, and at what resource cost, versus the all-plane primitive that hits the
floor with **one** command on **one** core/queue.

### 14.1 The faithful design (fixed flash + N dispatchers + locked shared media)

A real SSD = a **controller** (fetch/arbitration front-end + several firmware cores running FTL/
scheduling) driving **one fixed flash array** (channels → dies/LUNs, each a serial physical resource).
NVMeVirt's `nvmev_dispatcher` *is* the controller's command pipeline; `ssd_advance_nand`'s
`lun->next_lun_avail_time` / `ch->perf_model` *are* the media. The change scales the **controller**, not
the media:

1. **`nr_dispatchers=N` module param** (default 1, fully backward-compatible). The first `N` CPUs in
   `cpus=` become dispatcher (controller-core) threads; the rest are io_workers (`main.c`, `nvmev.h`).
2. **N dispatcher kthreads over disjoint submission-queue subsets.** SQ `sqid` is owned by dispatcher
   `(sqid-1) % N`; the admin queue and all BAR/register processing stay on dispatcher 0 (no races on
   controller registers). The doorbell scan `nvmev_proc_dbs()` was refactored to take the owning
   dispatcher index and skip non-owned queues (`main.c`).
3. **The shared flash-timing state is serialized under a per-channel spinlock** in `ssd_advance_nand`
   (`ssd.c`/`ssd.h`). With N controller cores touching the one physical channel/die array, this is the
   *physics*, not an emulator wart: independent channels run in parallel (independent locks), commands
   on the same channel serialize. Without it the model would both data-race `next_lun_avail_time` and
   fabricate parallelism the hardware does not have. Per-channel granularity is the physically correct
   unit; at `N=1` the lock is always free.
4. **The flash array is untouched** — `nchs`, `luns_per_ch`, tR, channel bandwidth, channel model, and
   `conv_read`'s compute semantics are all independent of `N`.

> **A second lock was required for correctness (found the hard way).** With `N>1`, multiple dispatchers
> enqueue to / reclaim from the **same** io_worker work-queue whenever `(sqid-1)%nr_io_workers` collides
> across dispatcher-owned SQs (e.g. SQ1 & SQ3 both → io_worker 0). The original single-dispatcher design
> assumed exactly one writer per io_worker free-list, so this corrupted the list into a **cycle** → the
> io_worker thread spun forever in its (cond_resched-free) walk → soft lockup, unkillable kthread,
> reboot. Fix: a **per-io_worker spinlock** around free-list/`io_seq` mutation in `__enqueue_io_req`,
> `schedule_internal_operation`, and `__reclaim_completed_reqs` (`io.c`, `nvmev.h`), plus a defensive
> walk cap so a corrupted list can never wedge the kernel again. Uncontended at `N=1`.

**Host-side queue scaling (Task C).** A controller core only does work if the host presents it a queue:
one SPDK qpair = one SQ, owned by exactly one dispatcher. So effective controller parallelism =
`min(host_threads, N)`. `host/inflash_bench_spdk.c` gained `--threads T` (= `--qpairs T`): T pthreads,
each pinned to a distinct E-core with its own qpair, splitting the LPN range; aggregate e2e = first
submit (any thread) → last completion (any thread). `--threads 1` is the legacy path, unchanged.

### 14.2 N=1 regression (D1) — the lock + refactor cost ~0

| metric | §13 baseline | §14 N=1 (this run) |
|---|---:|---:|
| single-plane 1 cmd → 1 plane | ~30.8 µs | **30.8 µs** |
| single-plane 512 cmds → 512 planes, amortized/512-set | ~139–144 µs | **151.9 µs** |
| dmesg device latency (single-plane, per op) | `30152 ns (sensed 1 pages)` | `30152 ns (sensed 1 pages)` |

Reproduced within run-to-run variance (this run is on kernel 6.8.0-124 vs the §13 6.8.0-111; the
~8 % higher floor is build/run variance, not the lock — see the control in §14.4). The per-channel and
per-io_worker locks are uncontended at N=1.

### 14.3 Dispatcher sweep (D2/D3) — more controller cores make single-plane *worse*

Single-plane, 4096 cmds (8 × 512-plane sets) at qd512, SPDK host path, default knobs. Amortized = e2e ÷ 8.
CSV `results_nvmevirt_spdk_dispatcher_sweep.csv`; figure `fig_nvmevirt_dispatcher_sweep.png`.

| nr_dispatchers (cores) | io_workers | host threads T | amortized µs / 512-set | ns / cmd |
|:---:|:---:|:---:|---:|---:|
| 1 | 1 | 1 | **151.9** | 296.6 |
| 2 | 2 | 1 (1 SQ → 1 disp works) | 184.9 | 361.2 |
| 2 | 2 | 2 (matched) | 198.0 | 386.6 |
| 4 | 2 | 1 | 197.0 | 384.7 |
| 4 | 2 | 4 (matched) | 243.0 | 474.7 |
| 8 | 2 | 1 | 259.2 | 506.2 |
| 8 | 2 | 2 | 290.3 | 567.1 |
| 8 | 2 | 4 | 287.3 | 561.1 |
| 8 | 2 | 8 (matched) | **308.3** | 602.1 |

The single-plane floor **rises monotonically with N** (152 → 308 µs), the *opposite* of the prompt's
expectation that it would fall toward ~30 µs. Two regimes, both worse:

- **T=1 (single host queue):** only dispatcher 0 ever has work, yet the floor still climbs 152 → 259 µs
  as N grows 1 → 8. The N−1 *idle* dispatchers degrade the one working dispatcher.
- **T=N (host queues matched, all N dispatchers active):** worse still (308 µs at N=8), because now N
  dispatchers genuinely contend on the shared per-channel media locks and funnel through 2 io_workers,
  while the intake parallelism they add is smaller than the contention they create.

### 14.4 Why it rises — attribution control

Is N=8/T=1 (259 µs) worse than N=1/T=1 (152 µs) because of **CPU placement** (N=8 uses cpu 1–10 vs
N=1's cpu 7,8) or the **idle dispatcher threads**? Control: run **N=1 on N=8's working cores** —
dispatcher on cpu 1, io_worker on cpu 9 (exactly where N=8's *working* dispatcher 0 and io_workers sit),
just without the 7 idle dispatchers:

| config | amortized µs / 512-set |
|---|---:|
| N=1, cpus=7,8 (default placement) | 151.9 |
| N=1, **cpus=1,9** (= N=8's working cores, no idle dispatchers) | **151.3** |
| N=8, T=1 (cpu1 working + 7 idle dispatchers on cpu2–8) | 259.2 |

Placement is *not* the cause (151.9 ≈ 151.3). The entire 152 → 259 µs rise is attributable to the
**idle dispatcher threads polling the shared doorbell / BAR region** (`nvmev_vdev->dbs[]`) in their
busy-loops, contending on those cachelines with the one dispatcher actually doing work. Adding genuine
work to those dispatchers (T=N) then layers per-channel-lock and io_worker contention on top.

This empirically **refutes the §13.5 "single dispatcher is the wall" hypothesis**: the single-plane
per-command cost is paid across a pipeline (host submit/reap + io_worker memcpy/CQ-fill + shared
doorbell), and that pipeline does not parallelize for this workload; replacing the one dispatcher with
N only adds contention.

### 14.5 Faithfulness invariants (all hold)

1. **Flash array unchanged.** All-plane (D4) is a flat **34.8 µs e2e** and dmesg
   `inflash_dev_lat 34152 ns (sensed 512 pages)` for **every** N ∈ {1,2,4,8}. Single-plane per-op device
   latency is `30152 ns (sensed 1 pages)` for every N. The media model is provably independent of
   controller-core count.
2. **No fabricated media parallelism.** Single-plane never drops below the ~30 µs flash round at any N —
   it only rises. The per-channel lock guarantees same-channel commands serialize regardless of which
   dispatcher runs them; the dmesg per-op latency being invariant is the device-model proof of this.
   (Invariant 2's same-LUN-pair check is satisfied structurally by the per-channel lock + the unchanged
   dmesg per-op time, and the all-plane same-die serialization established in `report.md` is unaffected.)
3. **N=1 regression** within variance (§14.2), confirmed by the placement control (§14.4) to be a
   build/run-variance offset, not lock cost.
4. **No data races** (after the per-io_worker lock fix): the full D1–D4 sweep including T=8 ran clean,
   no soft lockup / WARNING / oops in dmesg.
5. **Honest accounting.** Every data point lists its dispatcher cores, io_workers, and host queues. The
   single-plane floor's *best* case is still N=1 (152 µs); no configuration of N controller cores +
   host queues brings it near all-plane's 34.8 µs.

### 14.6 Conclusion — the O(1)-vs-O(512) command-count argument is hardened

All-plane reaches the flash floor (34.8 µs, `34152 ns`) with **one command, one controller core, one
host queue**, and is completely independent of `nr_dispatchers`. Single-plane O(512)-command activation
**cannot** be brought toward that floor by spending controller cores: scaling N from 1 → 8 (with matched
host queues) *raises* its amortized cost 152 → 308 µs, because the flash media floor is fixed and the
added dispatchers contend (shared doorbell + the physically-mandatory per-channel media lock) faster than
they parallelize command intake. The durable architectural argument — **sense all planes device-side, in
one command, rather than issuing O(512) commands** — therefore survives, and is in fact *strengthened by*,
aggressive controller-core parallelization: throwing N cores (+ N host queues) at the O(512) primitive
makes it worse, not better, while the O(1) primitive needs no scaling at all.

### 14.7 Reproduce & module state

```bash
bash scripts/build.sh                                   # nvmev.ko: nr_dispatchers + per-channel/io_worker locks
make -C host spdk SPDK_DIR=/home/juchanlee/spdk         # bench with --threads
modinfo nvmev.ko | grep -E 'nr_dispatchers|compute_sense_pages'
sudo -v
sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk bash scripts/nvmevirt_spdk_dispatcher_sweep.sh
#   D1 N=1 regression, D2 dispatcher sweep {1,2,4,8} x {T=1, T=N}, D3 host-thread sweep at N=8,
#   D4 all-plane unaffected, dmesg read-back, restore default. Summary CSV (semicolon-separated cpus):
#     results_nvmevirt_spdk_dispatcher_sweep.csv
python3 scripts/plot_dispatcher_sweep.py                # -> fig_nvmevirt_dispatcher_sweep.png
# Key faithfulness lines (dmesg), identical for every N:
#   single-plane: NVMeVirt: inflash_dev_lat 30152 ns (sensed 1 pages)
#   all-plane   : NVMeVirt: inflash_dev_lat 34152 ns (sensed 512 pages)
```

Gotcha learned (the expensive way): an **un-serialized multi-dispatcher io_worker free-list corrupts into
a cycle → unkillable kthread → reboot**. The per-io_worker lock + defensive walk cap prevent it; the
reserved memory (`memmap=…$96G` on the boot cmdline) survives reboot so the module reloads cleanly.

---

## 15. Experiment A — channel-affine dispatchers: isolating per-channel media-lock contention

§14 found that scaling controller cores makes single-plane *worse* and attributed the rise to two
suspects — "the extra busy-spinning dispatcher cores" (turbo/LLC) and, for the matched-queue regime,
"per-channel media-lock contention + the io_worker funnel" — but it never **isolated** the per-channel
lock term. §15 isolates exactly that term and measures it directly.

### 15.1 The design — a host-side-only single-variable isolation

`ssd_advance_nand` takes a **per-channel spinlock** `ch->lock` around the read-modify-write of the
channel's `perf_model` and the addressed LUN's `next_lun_avail_time`. Under §14's *spread* routing,
each of N dispatchers issues commands to **all 16 channels**, so all N dispatchers fight over every
`ch->lock` (cacheline ping-pong + serialized critical sections). **Channel-affine routing** assigns each
channel to exactly one dispatcher and routes the host so that a dispatcher's SQ only ever carries that
channel's LPNs:

- The flash map is deterministic and **verified at runtime** (§15.2): LPN `i` → channel `i % 16`. With
  the worker count `N` dividing 16, **LPN `i` belongs to channel-affine worker `i % N`**, whose channel
  set is `{c : c % N == t}` (N=16 → one channel each; N=8 → 2; N=4 → 4).
- `host/inflash_bench_spdk.c --chan-affine` reorders the per-worker LPN slices so worker `t` issues only
  logical indices `≡ t (mod N)`. One SPDK qpair = one SQ = dispatcher `(qid-1)%N`, so each per-channel
  lock then has **exactly one** owning dispatcher: uncontended. Commands to different LUNs of the same
  channel still serialize on that single-owner lock (physically correct); no two dispatchers ever
  contend.

This is a **host-side routing change only** — the module config (same `nr_dispatchers`, `cpus=`,
io_workers, cores, same per-channel lock) is **identical** between the affine and spread arms. Turbo
state, LLC pressure, io_worker count, and dispatcher count are all held fixed; only the lock-contention
pattern changes. Confound that does *not* vanish (stated, not hidden): the io_worker funnel
(`(sqid-1)%nr_io_workers`) is independent of the channel partition, so it is identical in both arms and
cannot bias the affine-vs-spread *delta* (it may cap absolute throughput).

### 15.2 Direct contention measurement — the airtight evidence (Task CB / CC)

`CONFIG_LOCK_STAT` is **off** in the running kernel (6.8.0-124), so `/proc/lock_stat` is unavailable. We
instead added an **in-module trylock counter** (the prompt's documented fallback): `ssd_advance_nand`
does `spin_trylock`; a failure is a genuine cross-dispatcher collision and is counted before falling
back to the blocking `spin_lock` (identical timing semantics; the uncontended fast path is ~free). It
also tallies per-(CPU, channel) hits — `ssd_advance_nand` runs in **dispatcher context**
(`nvmev_proc_io_sq → __nvmev_proc_io → conv_read`), so the CPU identifies the owning dispatcher. Exposed
at **`/proc/nvmev/chstat`** (read = dump; write = reset).

| N | routing | amort µs/512-set | contended `ch->lock` acq. (of 40 960) | distinct CPUs/channel | dmesg per-op |
|:--:|:--|--:|--:|:--:|:--|
| 4 | spread | 228.9 | **660** | 4 | `30152 ns` |
| 4 | affine | 230.2 | **0** | **1** | `30152 ns` |
| 8 | spread | 292.6 | **584** | 8 | `30152 ns` |
| 8 | affine | 269.4 | **0** | **1** | `30152 ns` |
| 16 | spread | 5911.6 | **586** | 16 | `30152 ns` |
| 16 | affine | 6151.2 | **0** | **1** | `30152 ns` |

(`results_nvmevirt_spdk_chanaffine_sweep.csv`; per-run affinity matrices in
`results_chstat_N${N}_{spread,affine}.txt`; figure `fig_nvmevirt_chanaffine.png`.) The affinity proof is
clean: under affine each channel is touched by **exactly one** dispatcher CPU (e.g. at N=8, cpu1 owns
{ch0,ch8}, cpu0 owns {ch7,ch15}, …), vs all N CPUs per channel under spread.

### 15.3 Finding — the lock was contended but is *not* the bottleneck

Channel-affine routing **eliminates 100 % of cross-dispatcher lock contention** at every N (spread
{660, 584, 586} → affine 0; distinct-CPUs-per-channel N → 1) — yet the single-plane amortized latency
**barely changes**: N=4 is flat (228.9 → 230.2, within noise), N=8 improves a modest **−8 %**
(292.6 → 269.4 µs), and N=16 is swamped by the io_worker-oversubscription confound (§3.4: 16 dispatchers
need all 16 P-cores, so the two io_workers are co-located on cpu0/1 — even the all-plane 1-command case
inflates to ~6 ms there while dmesg stays `34152 ns`, i.e. it is controller-core starvation, not the
device model). The reason the latency is insensitive to contention is now quantitative: even under
spread, only ≈ **1.5 %** of acquisitions (584–660 of 40 960) are contended — the lock is taken often but
collides rarely, so removing those collisions saves little. **N=8 is the clean primary comparison**
(both arms fit on P-cores with 2 io_workers); it reproduces §14's spread value (292.6 µs vs §14's
308 µs, within run-to-run variance, invariant 3) and shows the per-channel lock costs at most ~8 % of
the single-plane floor.

### 15.4 Faithfulness invariants (all hold)

1. **Flash array unchanged.** dmesg per-op `30152 ns (sensed 1 pages)` for every N and both routings;
   all-plane (CA4) `34152 ns (sensed 512 pages)`. The device model is provably independent of routing.
2. **Channel affinity actually holds.** Under affine, the `/proc/nvmev/chstat` matrix shows exactly one
   dispatcher CPU per channel (max distinct CPUs/channel = 1) and 0 contended acquisitions; under spread,
   every active dispatcher row is non-zero (N CPUs/channel).
3. **Spread reproduces §14** (N=8: 292.6 µs ≈ §14's 308 µs).
4. **No fabricated media parallelism.** Affine never drops single-plane below the ~30 µs flash round; it
   only removes *cross-thread* lock collisions. Same-channel commands still serialize on the now
   single-owner lock.
5. **Honest accounting.** Every point lists dispatcher cores, io_workers, host queues, and the
   channel→dispatcher partition; the N=16 io_worker oversubscription is flagged as a confound, with N=8
   as the primary clean comparison. No soft lockup / lockdep splat across the whole sweep.

### 15.5 Conclusion (lock limiter? **No**)

Removing cross-dispatcher per-channel-lock contention entirely (contention → 0, proven directly) recovers
**at most ~8 %** of the single-plane floor at the clean N=8 point and nothing at N=4. The per-channel
media lock is therefore **not** the limiter behind §14's "more dispatchers make single-plane worse"
result — it confirms §14's attribution to turbo/LLC + the io_worker funnel (and, per §16, host-side
fan-out), and **hardens** the O(1)-vs-O(512) command-count argument: single-plane O(512) activation
cannot be rescued by controller-core parallelism even after the one physically-mandatory lock is made
perfectly uncontended.

### 15.6 Reproduce

```bash
bash scripts/build.sh                                   # nvmev.ko: + /proc/nvmev/chstat trylock counter
make -C host spdk SPDK_DIR=/home/juchanlee/spdk         # bench: + --chan-affine / --planes
sudo -v
sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk bash scripts/nvmevirt_spdk_chanaffine_sweep.sh
#   CA2/CA3 spread vs affine N∈{4,8,16} + chstat contention/affinity; CA4 all-plane; restore default.
python3 scripts/plot_chanaffine_sweep.py                # -> fig_nvmevirt_chanaffine.png
# contention proof (any time the module is loaded):
#   echo 1 > /proc/nvmev/chstat   # reset ; then run ; then: cat /proc/nvmev/chstat
```

---

## 16. Experiment B — one plane per dispatcher: removing the per-dispatcher serial intake

NVMeVirt's second fidelity gap (besides the shared media lock of §15) is that **each dispatcher kthread
is serial**: `nvmev_proc_dbs()` scans its SQ doorbells one-by-one and `nvmev_proc_io_sq()` walks new SQ
entries in a serial `for` loop — there is no hardware queue arbitration. In §14's 512-set, each
dispatcher serially processes `512/N` commands (64 at N=8). §16 removes that batching by setting the
**activated plane count equal to the dispatcher count** (`P = N`, one channel-affine command per
dispatcher) and contrasts it with the same planes activated serially on one dispatcher.

### 16.1 Design

- **Parallel arm (B1):** `nr_dispatchers=N`, `--planes N` (= `--threads N --requests N --chan-affine`):
  N dispatchers, N queues, **1 command each** → P=N planes on N distinct channels (fully independent,
  zero shared-LUN and zero per-channel-lock contention).
- **Serial arm (B2):** the **same N planes** on **one** dispatcher / one queue / N commands
  (`nr_dispatchers=1`, `--threads 1 --requests N --qdepth N`) — the per-dispatcher serial intake.
- Sweep `N = P ∈ {1,2,4,8,16}`; e2e = first submit (any thread) → last completion (any thread); median
  of 30 trials.

### 16.2 Result — serial *beats* parallel; the single dispatcher reaches the floor

| N=P | parallel e2e (N disp, 1 cmd each) | serial e2e (1 disp, N cmds) | dmesg per-op |
|:--:|--:|--:|:--|
| 1 | 30.82 µs | 30.80 µs | `30152 ns` |
| 2 | 77.28 µs | 31.19 µs | `30152 ns` |
| 4 | 86.40 µs | 31.76 µs | `30152 ns` |
| 8 | 126.52 µs | **32.95 µs** | `30152 ns` |
| 16 | 5494.78 µs *(oversubscription confound)* | **34.97 µs** | `30152 ns` |

(`results_nvmevirt_spdk_planes_eq_disp.csv`; figure `fig_nvmevirt_planes_eq_disp.png`.) This **inverts**
the naïve "more controller cores = more parallel" expectation:

- The **parallel** arm *rises* 30.8 → 126.5 µs (N=1→8) even at 1 command per dispatcher with **zero**
  lock contention. Its per-plane throughput improves (30 820 → 15 815 ns/plane), but the **wall-clock to
  activate all N planes grows** because N host threads on E-cores + N busy-spinning dispatcher P-cores
  add submit/poll **fan-out skew** and shared-doorbell/turbo contention faster than they overlap. (N=16
  is the §3.4 io_worker-oversubscription confound, ~5.5 ms, not a device effect — dmesg `30152 ns`.)
- The **serial** arm stays **flat at the floor**: one dispatcher activates up to **16** single-plane
  commands in **34.97 µs** — essentially the **34.8 µs all-plane primitive**. It tracks
  `tR + (N−1)·t_cmd` with a directly-measured **t_cmd ≈ 0.28 µs/cmd** ((34.97−30.80)/15), because the N
  planes' tR rounds overlap in the device model and the serial command intake is nearly free.

So NVMeVirt's *single serial dispatcher* is **not** the wall for single-plane — it sits at the floor up
to N=16; the multi-dispatcher "parallel" configuration is the slower one. This is the positive companion
that **refutes the §13.5 "single dispatcher is the wall" hypothesis from the other side** and reinforces
§14: spending controller cores hurts single-plane on *both* axes (lock contention, §15; and serial-vs-
parallel intake, here).

### 16.3 Variant — fix N=8, sweep per-dispatcher batch depth

Fixing `N=8` channel-affine and sweeping the activated plane count `P ∈ {8,32,128,512}` (batch depth
`P/N ∈ {1,4,16,64}`) so each dispatcher serially processes `P/8` commands:

| P | batch P/N | e2e µs | per-plane ns | routing |
|--:|:--:|--:|--:|:--|
| 8 | 1 | 366.5 | 45 812 | affine |
| 32 | 4 | 142.5 | 4 452 | affine |
| 128 | 16 | 150.4 | 1 175 | affine |
| 512 | 64 | 344.7 | **673** | affine |
| 512 | 64 | 351.2 | 686 | **spread** |

(`results_nvmevirt_spdk_batchdepth_N8.csv`.) The **per-plane** cost falls monotonically
(45 812 → 673 ns/plane) — fixed startup amortized over more planes — but the **e2e is non-monotonic**
(366 → 142 → 150 → 345 µs): at small P the 8-thread host **fan-out skew** dominates and swamps the
serial-intake term (which, from B2, is only ~0.28 µs/cmd — i.e. ~18 µs even at batch 64). The expected
clean linear "serial-intake climb" therefore does **not** appear: §14's 512-set cost is
**host-throughput-bound, not per-dispatcher-serial-intake-bound**. The cross-experiment consistency check
holds in spirit: **affine ≈ spread at P=512** (344.7 vs 351.2 µs, contention adds only ~2 %), the same
"lock is not the cost" verdict as §15, and the P=512 affine per-plane (673 ns) is the same order as
Experiment A's N=8 affine (526 ns/cmd amortized).

### 16.4 Faithfulness (Experiment B)

1. **Device model unchanged:** dmesg `30152 ns (sensed 1 pages)` for every N and P; activating N planes
   on N distinct LUNs/channels is one parallel tR round in the model.
2. **Affinity verified** (reused §15 `/proc/nvmev/chstat`): each of the N planes on a distinct channel,
   single owning dispatcher.
3. **Honest accounting:** N (= planes = dispatchers = queues), io_workers, CPU layout reported per point;
   N=16 io_worker oversubscription flagged. No lockdep splat.

### 16.5 Conclusion

When balanced **1 command : 1 dispatcher**, the bottleneck is **not** the per-dispatcher serial intake
(t_cmd ≈ 0.28 µs/cmd, negligible below hundreds of commands) — it is host-side fan-out/skew and the fixed
flash round. A **single** serial dispatcher already reaches the flash floor for up to 16 single-plane
commands (34.97 µs ≈ the all-plane primitive), and parallel multi-dispatcher activation is *slower*. So
of §14's degradation, the per-dispatcher serial-intake share is small and the per-channel-lock share is
small (§15); the residual is host fan-out + turbo/LLC + the io_worker funnel. The durable architectural
conclusion stands and is doubly hardened: **sense all planes device-side in one command** rather than
issuing O(512) commands across N controller cores.

### 16.6 Reproduce

```bash
sudo -v
sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk bash scripts/nvmevirt_spdk_planes_eq_disp_sweep.sh
#   B1 parallel (--planes N) + B2 serial (1 disp, N cmds), N∈{1,2,4,8,16}; B3 batch-depth N=8
#   P∈{8,32,128,512} (+ spread overlay); restore default. CSVs in repo dir.
python3 scripts/plot_planes_eq_disp.py                  # -> fig_nvmevirt_planes_eq_disp.png
```

**Module restored to defaults** after both sweeps (`nr_dispatchers=1`, `compute_sense_pages=512`),
`/dev/nvme1n1` back on the kernel driver, hugepages freed.

**Module restored to defaults** after the run (`nr_dispatchers=1`, `compute_sense_pages=512`),
`/dev/nvme1n1` back on the kernel driver, hugepages freed — §11/§12/§13 behaviour intact.
