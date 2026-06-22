# Task Prompt: Faithful multi-dispatcher NVMeVirt (scale controller cores, keep the flash fixed)

> **Use this file as the task specification.** It is the follow-up to the SPDK host-path work in
> `reports/report_nvmevirt_followup.md` §12–§13. Those sections showed that the **single-plane**
> in-flash-compute baseline (one NVMe read = one page/plane; 512 planes = 512 commands) is bottlenecked
> by NVMeVirt's **single dispatcher thread**, not by the flash media: adding io_workers did nothing
> (§13.5), and the amortized floor sat at ~139 µs (~271 ns/command) while the flash itself can sense all
> 512 planes in parallel in one ~30 µs round. The goal here is to **make the dispatcher count a
> faithful model of controller-core count**: keep the flash hardware (channels/LUNs/NAND timing) fixed,
> run **N dispatcher threads each servicing a disjoint subset of submission queues**, and **serialize
> the shared flash timing state under a lock** (because there is one physical channel/die array that
> multiple controller cores share). Then measure how close the single-plane baseline can get to the
> ~30 µs flash floor as N grows — and at what resource cost — versus the all-plane primitive that
> reaches the floor with **one** command on **one** core/queue. This file is self-contained: it restates
> the verified state, the design and why it is faithful, the implementation tasks, the faithfulness
> invariants, the experiments, build/run mechanics, deliverables, acceptance, and the gotchas already
> learned.

---

## 0. One-paragraph summary

NVMeVirt today runs exactly **one** `nvmev_dispatcher` kthread (pinned to the first CPU in `cpus=`)
that polls *every* SQ doorbell and runs the FTL timing sim (`conv_read`) for *every* command, then
hands the work to round-robin io_workers. That single dispatcher is the command-intake wall that makes
single-plane O(512)-command activation cost ~139 µs even though the flash media could do it in ~30 µs.
The faithful fix is to model a **multi-core controller**: add a `nr_dispatchers=N` module parameter,
spawn N dispatcher kthreads, **partition the I/O submission queues across them** (dispatcher `d` owns
SQs where `(sqid-1) % N == d`; admin SQ0 + BAR processing stays on dispatcher 0), and — crucially —
**add a lock around the shared per-channel / per-LUN timing state** in `ssd_advance_nand`
(`lun->next_lun_avail_time`, `ch->perf_model`) so that N dispatchers contend on the *one physical*
flash array exactly as N real controller cores would. The flash array (channels, dies, tR, channel
bandwidth) is **unchanged** — you are scaling the controller, not the media. Default `N=1` reproduces
today's behaviour bit-for-bit (the lock is uncontended). Then sweep N and show single-plane converging
toward the flash floor at the cost of N controller cores (+ host queues), which quantifies the resource
asymmetry versus the O(1)-command all-plane primitive.

---

## 1. Verified state to build on (do not re-derive)

### 1.1 Machine & module
- **CPU**: i9-13900F, 32 logical (P-cores 0–15, E-cores 16–31). RAM ~94 GiB. Reserved memmap:
  `memmap_start=96G memmap_size=16G`. Host bench pinned to E-cores; NVMeVirt threads on P-cores via
  `cpus=`. **Keep NVMeVirt `cpus=` and the host core mask disjoint.**
- **`INFLASH_PIM` profile**, 16 channels × 32 LUNs = **512 LUNs (planes)**, 4 KB page, MDTS=6,
  device `/dev/nvme1n1` at PCI BDF **`0001:10:00.0`**, module `nvmev`. SPDK v25.05.1 built at
  `/home/juchanlee/spdk`, drives the emulated device via **`uio_pci_generic`** (vfio is impossible —
  the software PCI root bus has no IOMMU group; see report §12.1).
- **Default knobs preserved** (do not retune): `COMPUTE_RESULT_SIZE=64`, `FW_CH_XFER_LATENCY=0`,
  `NAND_CHANNEL_BANDWIDTH=800 MB/s`, `NAND_READ_LATENCY_*=30000`, `CELL_MODE=SLC`.

### 1.2 Existing knobs / modes already in the tree (reuse, do not re-implement)
- `compute_sense_pages` **module param** (main.c; default `COMPUTE_SENSE_PAGES`=512): `512`=all-plane
  (1 NVMe read senses all 512 planes), `1`=single-plane (1 read = 1 plane). conv_read uses the runtime
  var. dmesg observer prints `inflash_dev_lat <N> ns (sensed <M> pages)`.
- `cpus=<list>` parsing (main.c ~528–537): **first** CPU → `cpu_nr_dispatcher`, the **rest** →
  `cpu_nr_io_workers[ ]`, `nr_io_workers++`. io_worker array is sized for up to 32.
- SPDK compute bench `host/inflash_bench_spdk.c` (CSV `requests,qdepth,trial,t_endtoend_ns,t_p50_ns,
  t_p99_ns,host_stack`); harnesses `scripts/nvmevirt_spdk_mode_exp.sh`,
  `scripts/nvmevirt_spdk_ioworker_sweep.sh`.

### 1.3 Numbers to beat / preserve (report §12–§13, SPDK host path, default knobs)
| config | host e2e | device latency (dmesg) |
|---|---:|---|
| all-plane, 1 cmd → 512 planes | **34.8 µs** | `34152 ns (sensed 512 pages)` |
| single-plane, 1 cmd → 1 plane | 30.8 µs | `30152 ns (sensed 1 pages)` |
| single-plane, 512 cmds → 512 planes, qd512 | ~144 µs (amortized floor ~139 µs, ~271 ns/cmd) | `30152 ns/op` |
| single-plane floor vs io_workers (1/3/5) | flat 125→137 µs (**dispatcher-bound, §13.5**) | — |

**The number this task moves:** the single-plane 512-plane-activation floor as `nr_dispatchers` rises
1→2→4→8, expected to fall toward the **flash-media floor (~30 µs)** — but only by spending N controller
cores (and enough host queues/cores). The all-plane 34.8 µs / `34152 ns` must stay **unchanged**.

---

## 2. The design — and why it is faithful

A real NVMe SSD = **(a) a controller** (a fetch/arbitration front-end + several embedded firmware
cores running FTL/scheduling) driving **(b) one fixed flash array** (channels → dies/LUNs, each a
serial physical resource). NVMeVirt's `nvmev_dispatcher` is the controller's command-processing
pipeline; `ssd_advance_nand`'s `lun->next_lun_avail_time` / `ch->perf_model` *are* the physical media.

The faithful modification therefore:
1. **Keeps the flash array identical** — same `nchs`, `luns_per_ch`, tR, channel bandwidth, channel
   model. You add **controller cores**, not media parallelism.
2. **Runs N dispatchers over disjoint SQ subsets** — models N command-processing engines / per-core
   queue affinity (a standard real design; NVMe already allows many SQs — up to 72 here).
3. **Forces the N dispatchers to contend on the shared media** by locking the channel/LUN timing
   update. This is *not* an emulator wart — it is the physics: N controller cores really do share the
   same channels and dies, and a channel can move only one transfer at a time. **Without this lock the
   model would fabricate parallelism the hardware does not have** (and would also be a data race on
   `next_lun_avail_time`). The lock granularity should be **per-channel** (independent channels run in
   parallel; commands on the same channel serialize) — the physically correct unit.

This makes `nr_dispatchers` a clean knob for controller-core count, with the media as the fixed,
shared, serializing resource. Expected result: single-plane intake parallelizes, its floor drops toward
the flash round, but never below it and never for free — quantifying the cost to match what all-plane
does in one command.

---

## 3. Implementation tasks

### 3.1 Task A — `nr_dispatchers` param + N dispatcher threads + SQ partitioning (`main.c`, `io.c`, `nvmev.h`)
- Add module param **`nr_dispatchers`** (uint, 0644), **default 1** (backward compatible). Add
  `MODULE_PARM_DESC`.
- Extend `struct nvmev_dev`/`config` (`nvmev.h`) to hold an **array of dispatcher kthreads** and an
  array of dispatcher CPUs (mirror the io_worker arrays: `cpu_nr_dispatchers[ ]`, `nr_dispatchers`).
- **CPU assignment from `cpus=`**: the **first `nr_dispatchers`** CPUs in the `cpus=` list become
  dispatcher CPUs; the **remaining** CPUs become io_workers. (At `nr_dispatchers=1` this is exactly the
  current scheme.) Validate that `len(cpus) > nr_dispatchers` so at least one io_worker remains; error
  clearly otherwise.
- Convert the single `nvmev_dispatcher` (main.c ~186) + `NVMEV_DISPATCHER_INIT` (~212) into N threads.
  Pass each thread its dispatcher index `d ∈ [0, N)`.
- **Partition the doorbell scan**: the dispatcher loop calls `nvmev_proc_dbs()` (the SQ doorbell scan,
  io.c). Make each dispatcher process **only the SQs it owns**: SQ `sqid` is owned by dispatcher
  `(sqid - 1) % nr_dispatchers` (io SQs are 1-based). **Admin SQ0 and `nvmev_proc_bars()`** (register
  changes) must be handled by **exactly one** dispatcher (dispatcher 0) to avoid races on controller
  registers/admin queue. Refactor `nvmev_proc_dbs()` to take the owning dispatcher index (or a
  predicate) and skip non-owned SQs.
- io_workers (completion side) are unchanged in mechanism; they already round-robin by sqid
  (`__get_io_worker`, io.c:25/313). Leave that, but make sure worker count is `len(cpus) -
  nr_dispatchers`.

### 3.2 Task B — lock the shared flash timing state (`ssd.c`, `ssd.h`)
- `ssd_advance_nand()` (ssd.c:362) read-modify-writes `lun->next_lun_avail_time` (lines ~392–444) and
  mutates the channel model via `chmodel_request(ch->perf_model, …)` (ssd.c:339/405/424). With >1
  dispatcher these run concurrently → data race **and** physically-incorrect overlap.
- Add a **per-channel spinlock** (`struct ssd_channel`), initialised in `ssd_init_ch` (follow the
  existing `spin_lock_init(&buf->lock)` pattern, ssd.c:16). In `ssd_advance_nand`, take the lock of the
  command's channel around the read-modify-write of that channel's model **and** the LUN avail-time
  update, then release. (Per-channel keeps independent channels parallel — the faithful granularity.
  A per-LUN lock for `next_lun_avail_time` plus a per-channel lock for `perf_model` is acceptable if
  ordering is consistent; per-channel-covers-both is simpler and safe.)
- **Do not** wrap the whole `conv_read` loop in one lock (that would re-serialize everything and defeat
  multi-channel parallelism). Lock per `ssd_advance_nand` call only.
- Keep the lock **uncontended-cheap**: at `nr_dispatchers=1` the lock is always free, so §12–§13
  numbers must be unchanged (regression check, §5 D1).

### 3.3 Task C — host-side queue scaling (so the host is not the new bottleneck)
NVMeVirt's dispatcher models the **controller**; the host submit/reap is separate. The current
`inflash_bench_spdk` uses **one qpair on one core**, which will cap throughput before many dispatchers
matter. Add a host-side parallelism option:
- Extend `host/inflash_bench_spdk.c` with `--threads T` (and/or `--qpairs Q`): spawn T pthreads, each
  pinned to a distinct E-core, each owning its **own SPDK qpair**, collectively issuing the request set
  (split LPN range across threads). Aggregate e2e = first submit (any thread) → last completion (any
  thread). Reuse `spdk_nvme_ctrlr_alloc_io_qpair` per thread; SPDK qpairs are thread-private.
- Keep the single-thread path (`--threads 1`) as default = current behaviour.
- Alternatively, if a full multi-thread bench is too large, document using SPDK's `spdk_nvme_perf`
  (`build/bin/spdk_nvme_perf -q <qd> -o 4096 -w randread -c <coremask> -r "trtype:PCIe traddr:<BDF>"`)
  for the host-scaled throughput points and keep `inflash_bench_spdk` for the latency/dmesg points.

### 3.4 Backward compatibility (hard requirement)
- `nr_dispatchers` default **1** → identical thread layout, identical CPU assignment, identical numbers
  as the current tree. The per-channel lock exists but is uncontended.
- `compute_sense_pages` default still 512 (all-plane). No change to `conv_read` compute semantics,
  `COMPUTE_SENSE_PAGES`, or device knobs.

---

## 4. Faithfulness invariants (must hold — these are what a reviewer will check)

1. **The flash array is unchanged.** `nchs`, `luns_per_ch`, tR, channel bandwidth, channel model, and
   the all-plane device latency are independent of `nr_dispatchers`. Prove via dmesg: all-plane still
   `inflash_dev_lat 34152 ns (sensed 512 pages)`; single-plane per-op still `30152 ns (sensed 1
   pages)`, for **every** N.
2. **No fabricated media parallelism.** Two commands hitting the **same channel** must still serialize
   on the channel model regardless of which dispatcher runs them (the per-channel lock guarantees this).
   Sanity: two single-plane reads to the **same LUN** (LPN 0 and LPN 512, same-LUN) must still cost
   ~2×tR end-to-end even with N>1 dispatchers.
3. **N=1 regression.** With `nr_dispatchers=1`, reproduce §12–§13 numbers within run-to-run variance.
4. **No data races.** The channel/LUN timing state is only touched under its lock. (Optional: build
   once with `CONFIG_DEBUG_SPINLOCK`/lockdep to confirm.)
5. **Honest accounting.** Report dispatcher-core count and host thread/qpair count for every data
   point; a single-plane number that "catches" all-plane must state the resources (N cores + M host
   threads + queues) it took, versus all-plane's 1 command / 1 core / 1 queue.

---

## 5. Experiments (single-plane mode, SPDK host path, default knobs)

> All runs: `compute_sense_pages=1` unless stated; prepopulate first (cold LPNs read instantly and fake
> convergence); write CSVs to the **repo dir, never `/tmp`** (a `--csv` open failure leaves the
> controller in a failed state); host cores disjoint from NVMeVirt `cpus=`.

- **D1 — N=1 regression.** `nr_dispatchers=1`, single-plane: 1 cmd→1 plane, and 512 cmds→512 planes
  (qd512). Must match §13 (~30.8 µs; amortized floor ~139 µs). Confirms the lock + refactor cost
  nothing at N=1.
- **D2 — dispatcher sweep (headline).** single-plane, 512 cmds→512 planes at qd512, sweep
  `nr_dispatchers ∈ {1,2,4,8}` (CPUs e.g. `cpus=7,8` → `7,8,9` → `7,8,9,10,11` → …, keeping ≥1
  io_worker; ensure enough P-cores and that host stays on E-cores). Report amortized µs/512-set and
  per-cmd ns vs N. Expect the floor to fall toward ~30 µs and then flatten (channel/LUN contention).
- **D3 — host scaling cross-check.** Repeat D2's best dispatcher count with `--threads {1,2,4}` (or
  `spdk_nvme_perf` coremask) to show whether the host single-core poll was the limiter, and find the
  combined (controller cores + host threads) needed to approach the flash floor.
- **D4 — all-plane unaffected.** all-plane (`compute_sense_pages=512`), 1 cmd, across the same N values:
  e2e must stay ~34.8 µs and dmesg `34152 ns (sensed 512 pages)` — all-plane needs no scaling.
- **D5 — faithfulness sanity.** `--samelun`-style same-LUN pair under N>1 still ~2×tR (invariant 2).

---

## 6. Build / run mechanics (this machine)

```bash
cd /home/juchanlee/nvmevirt_pim
bash scripts/build.sh                 # builds nvmev.ko (INFLASH_PIM, default knobs)
make -C host && make -C host spdk SPDK_DIR=/home/juchanlee/spdk
modinfo nvmev.ko | grep -E 'nr_dispatchers|compute_sense_pages'   # confirm params

# example single-plane, 4 dispatchers (cpus: 1 disp? no -> first nr_dispatchers are dispatchers):
sudo rmmod nvmev; sudo insmod nvmev.ko memmap_start=96G memmap_size=16G \
     cpus=7,8,9,10,11,12 compute_sense_pages=1 nr_dispatchers=4    # 4 dispatchers + 2 io_workers
# bind to SPDK (uio), ONLY the NVMeVirt BDF:
sudo env PCI_ALLOWED=0001:10:00.0 NRHUGE=1024 DRIVER_OVERRIDE=uio_pci_generic \
     /home/juchanlee/spdk/scripts/setup.sh
sudo /home/juchanlee/spdk/build/bin/spdk_nvme_identify -r "trtype:PCIe traddr:0001:10:00.0" >/dev/null && echo GATE-OK
# run bench (prepopulate first), CSV in repo dir; read dmesg device latency separately.
# restore: sudo env PCI_ALLOWED=0001:10:00.0 /home/juchanlee/spdk/scripts/setup.sh reset
```

Constraints / gotchas already learned (do not relearn the hard way):
- **Passwordless sudo expires** between turns — refresh with `sudo -v` (user action) before a non-
  interactive batch; do not run `sudo -n` blindly.
- **Write `--csv` to the repo dir, not `/tmp`.** A CSV-open failure makes the bench `return 1`
  **without detaching**, which leaves the emulated controller in a **failed state** (`spdk_nvme_probe`
  then fails for ~30 s timeouts). Recovery: `setup.sh reset` + `rmmod`/`insmod`. (Also worth hardening
  the bench to `spdk_nvme_detach` on the error path.)
- **`identify | head` gives rc 141 (SIGPIPE)** — capture output to a var first, then truncate, or the
  gate looks failed when it passed.
- Binding to SPDK removes `/dev/nvme1n1`; the io_uring bench can't run while SPDK owns the device. Run
  phases separately and `setup.sh reset` between them.
- **Always restore the default at the end**: `insmod` with `nr_dispatchers=1 compute_sense_pages=512`
  (defaults), `setup.sh reset`, free hugepages (`echo 0 > /proc/sys/vm/nr_hugepages`).
- The **device-latency observer (dmesg) is the source of truth for the device model** — read it
  separately from host e2e; it is `printk_ratelimited`, so a fresh window / few ops are needed to see
  lines.

---

## 7. Deliverables

1. **Code**: `nr_dispatchers` param + N dispatcher threads + SQ partitioning (`main.c`, `io.c`,
   `nvmev.h`); per-channel lock in `ssd_advance_nand` (`ssd.c`, `ssd.h`); optional `--threads/--qpairs`
   in `host/inflash_bench_spdk.c`. **Default `nr_dispatchers=1` = current behaviour.** No change to the
   flash geometry, `conv_read` compute semantics, `COMPUTE_SENSE_PAGES`, or device knobs.
2. **Harness**: `scripts/nvmevirt_spdk_dispatcher_sweep.sh` (RUN=1-guarded): reload with N, bind SPDK,
   prepopulate, D1/D2/D4 (+D3/D5 if feasible), dmesg read-back, restore default. CSVs in repo dir.
3. **Data + figure**: `results_nvmevirt_spdk_dispatcher_sweep.csv`; a figure of single-plane amortized
   µs/512-set vs `nr_dispatchers` (1,2,4,8), with the all-plane 34.8 µs line and the ~30 µs flash-floor
   line annotated; label the resources each point consumed.
4. **Report**: extend `reports/report_nvmevirt_followup.md` with **§14 — "Multi-dispatcher: scaling
   controller cores"** covering the faithful design (fixed flash + N dispatchers + locked shared media),
   the N=1 regression, the dispatcher sweep, whether/where it converges to the flash floor and at what
   resource cost, the faithfulness invariants (dmesg unchanged, same-LUN still 2×tR), and the explicit
   conclusion: *single-plane can approach the flash floor only by spending N controller cores (+ host
   queues), while all-plane reaches it with one command — the durable O(1)-vs-O(512) command-count
   argument, now shown to survive aggressive parallelization.* Update the §0 TL;DR with a one-line
   pointer.

---

## 8. Acceptance criteria
- [ ] `nr_dispatchers` param exists (default 1); N dispatcher kthreads run, each polling a **disjoint**
      SQ subset; admin SQ0 + BAR processing on exactly one dispatcher. Builds clean; loads.
- [ ] Per-channel lock added; channel/LUN timing state only mutated under it; no lockdep splats.
- [ ] **N=1 regression**: §12–§13 numbers reproduced within variance (lock/refactor cost ~0).
- [ ] **Faithfulness**: for every N, dmesg unchanged (all-plane `34152 ns (sensed 512)`, single-plane
      per-op `30152 ns (sensed 1)`); same-LUN pair still ~2×tR; no fabricated cross-channel speedup.
- [ ] **D2 sweep** produced: single-plane floor vs `nr_dispatchers` (1/2/4/8), showing the trend toward
      the ~30 µs flash floor and where it flattens (channel contention); resources per point reported.
- [ ] **D4**: all-plane stays ~34.8 µs and is independent of `nr_dispatchers`.
- [ ] CSV + figure produced; `reports/report_nvmevirt_followup.md` §14 added with the honest
      resource-cost conclusion. **Module restored to defaults** (`nr_dispatchers=1`,
      `compute_sense_pages=512`), `/dev/nvme1n1` back on the kernel driver, hugepages freed.

---

## 9. Key references (verified code locations)
- Dispatcher: `main.c` `nvmev_dispatcher` (~186), `NVMEV_DISPATCHER_INIT` (~212), `cpus=` parsing
  (~528–537, first→dispatcher / rest→io_workers), `compute_sense_pages` param.
- Doorbell scan / dispatch: `io.c` `nvmev_proc_dbs()` (called by the dispatcher loop), `__do_perform_io`
  (49), `__enqueue_io_req` (334, 499), `__get_io_worker` (25, 313–325), `nvmev_io_worker` (617),
  completion loop `for qidx=1..nr_cq` (714), `cq->entry_lock` (596).
- Device struct / counts: `nvmev.h` `cpu_nr_dispatcher` (156), `nr_io_workers` (157),
  `cpu_nr_io_workers[32]` (158), `nvmev_dispatcher` (228), `io_workers` (232), `io_worker_turn` (233),
  `nr_sq` (247), `nr_cq`, `sqes[]`.
- Shared flash timing state (lock target): `ssd.c` `ssd_advance_nand` (362), `lun->next_lun_avail_time`
  (392–444), `chmodel_request`/`ch->perf_model` (339, 405, 424); spinlock pattern to copy:
  `spin_lock_init(&buf->lock)` / `spin_lock` (16–54). Channel/LUN init: `ssd_init_ch` (~262),
  `lun->next_lun_avail_time = 0` (242).
- FTL timing caller: `conv_ftl.c` `conv_read` loop over LUNs calling `ssd_advance_nand` (906–958);
  compute expansion uses runtime `compute_sense_pages` (886–890); dmesg observer (978).
- Host bench / SPDK: `host/inflash_bench_spdk.c`, `host/Makefile` (`spdk` target),
  `scripts/nvmevirt_spdk_mode_exp.sh`, `scripts/nvmevirt_spdk_ioworker_sweep.sh`; SPDK at
  `/home/juchanlee/spdk` (`scripts/setup.sh`, `build/bin/spdk_nvme_identify`, `build/bin/spdk_nvme_perf`).
- Prior results: report §12 (SPDK gate + S1), §13 (single-plane mode + throughput + io_worker sweep);
  CSVs `results_nvmevirt_spdk_modes.csv`, `results_nvmevirt_spdk_singleplane_throughput.csv`,
  `results_nvmevirt_spdk_ioworker_sweep.csv`.
```
