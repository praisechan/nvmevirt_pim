# Task Prompt: Two controls on NVMeVirt's multi-dispatcher serialization limit — (A) channel-affine dispatchers (one channel / 32-plane set per core), and (B) one plane per dispatcher (planes = dispatchers)

> **Use this file as the task specification.** It is the direct follow-up to the multi-dispatcher work
> in `reports/report_nvmevirt_followup.md` §14 (and its prompt `prompts/NVMEVIRT_MULTI_DISPATCHER_PROMPT.md`).
> §14 added `nr_dispatchers=N` (N dispatcher kthreads over disjoint SQ subsets `(sqid-1)%N`) plus a
> **per-channel spinlock** around the shared flash-timing state in `ssd_advance_nand`, and found that
> scaling controller cores did **not** bring single-plane 512-plane activation toward the ~30 µs flash
> floor — the amortized floor *rose* (152 µs at N=1 → 308 µs at N=8 with host queues matched). §14
> attributed the rise to "the extra busy-spinning dispatcher cores" (all-core turbo throttling + shared
> LLC/memory pressure) and, for the T=N regime, to **per-channel media-lock contention + the io_worker
> funnel** — but it did **not** isolate the per-channel-lock term. **This task isolates exactly that
> term.** It makes each dispatcher's submission queue carry requests for **only its own channel(s)** so
> each per-channel spinlock is taken by **exactly one** dispatcher (zero cross-dispatcher contention),
> and compares this *channel-affine* routing against §14's *spread* routing at matched N. The canonical
> case is **one channel = one 32-plane set per dispatcher** (N=16). This file is self-contained: it
> restates the verified mapping, the design, the implementation tasks, the faithfulness invariants, the
> experiments, build/run mechanics, deliverables, acceptance, and the gotchas already learned.

---

## 0. Summary — two experiments

This file specifies **two experiments** that decompose §14's "more dispatchers make single-plane worse"
result into its two suspected causes. **Experiment A (channel-affine dispatchers, §1–§9)** isolates
per-channel *media-lock* contention. **Experiment B (planes = dispatchers, §10)** isolates the other
fundamental NVMeVirt fidelity limit — a dispatcher kthread polls its SQ doorbells and processes its
commands **serially** (`nvmev_proc_dbs` scans queues one-by-one; `nvmev_proc_io_sq` walks new SQ entries
in a serial loop), unlike a real controller's hardware queue arbitration — by reducing the number of
activated planes to equal the number of dispatchers `N`, so each dispatcher handles **exactly one
command (one plane)**. The two compose (Experiment B is cleanest with channel-affine on). The rest of
§0 summarizes Experiment A; Experiment B has its own summary in §10.

### Experiment A (channel-affine)

In §14, with N dispatchers and the host issuing LPNs that land on *all 16 channels*, every dispatcher
calls `ssd_advance_nand` on every channel, so all N dispatchers contend on all 16 per-channel spinlocks.
This task removes that cross-dispatcher contention by **binding each dispatcher to a disjoint channel
subset and routing the host so that the SQ owned by dispatcher `d` only ever carries LPNs whose physical
channel belongs to `d`**. Because the flash layout is deterministic (verified below: channel `c` ⇔ LPNs
`≡ c (mod 16)`), this is a **host-side routing change only** — no change to the flash array, the FTL, or
the per-channel lock. Each per-channel lock then has a single owning dispatcher (uncontended), while the
*spread* baseline keeps all dispatchers contending. Compare the single-plane amortized µs/512-set for
**channel-affine vs spread at matched N ∈ {4, 8, 16}**, and — crucially — **measure the lock contention
directly** (lockstat / a contention counter) so the conclusion does not rest on the latency delta alone.
If channel-affine is materially faster *and* contention drops to ~0, the per-channel lock was a real
limiter; if channel-affine ≈ spread (as §14's turbo/LLC/io_worker-funnel analysis predicts), it confirms
the lock was **not** the bottleneck and hardens §14's conclusion that single-plane O(512) cannot be
rescued by controller-core parallelism.

---

## 1. Verified state to build on (do not re-derive)

### 1.1 Machine, module, knobs — unchanged from §14
- **CPU**: i9-13900F. **8 physical P-cores = 16 logical (cpu 0–15)**, 16 E-cores (cpu 16–31). RAM ~94 GiB.
  Reserved memmap on the **boot cmdline** (`memmap=16G$96G memmap=16G$64G`), so it survives reboot and the
  module reloads cleanly. **Keep NVMeVirt `cpus=` (P-cores) and host core mask (E-cores) disjoint** —
  except the documented N=16 io_worker oversubscription in §3.4.
- **Kernel is now 6.8.0-124-generic** (the §14 reboot upgraded it from -111). Rebuild against the running
  kernel (`scripts/build.sh` uses `uname -r`).
- **`INFLASH_PIM` profile**: 16 channels × 32 LUNs = **512 LUNs/planes** (`PLNS_PER_LUN=1`), 4 KB page,
  device `/dev/nvme1n1` at PCI BDF **`0001:10:00.0`**, module `nvmev`. SPDK at `/home/juchanlee/spdk`,
  drives the device via **`uio_pci_generic`**.
- **Default knobs preserved** (do not retune): `COMPUTE_RESULT_SIZE=64`, `FW_CH_XFER_LATENCY=0`,
  `NAND_CHANNEL_BANDWIDTH=800 MB/s`, `NAND_READ_LATENCY_*=30000`, `CELL_MODE=SLC`,
  `compute_sense_pages=1` for single-plane runs.

### 1.2 Knobs / code already in the tree (reuse, do not re-implement)
- **`nr_dispatchers=N`** module param; N dispatcher kthreads; SQ `sqid` owned by dispatcher `(sqid-1)%N`;
  admin SQ0 + BARs on dispatcher 0 (`main.c`, `nvmev.h`). `cpus=` assignment: first N CPUs → dispatchers,
  rest → io_workers.
- **Per-channel spinlock** `ch->lock` in `struct ssd_channel`, taken across the channel/LUN timing RMW in
  `ssd_advance_nand` (`ssd.c`/`ssd.h`). **This is the lock whose contention we are isolating.**
- **Per-io_worker spinlock** `worker->lock` (`io.c`/`nvmev.h`) — mandatory for `N>1` (a missing lock
  corrupted the io_worker free-list into a cycle → unkillable kthread → reboot; see §6 gotchas). Plus a
  defensive walk cap in `nvmev_io_worker`.
- **`compute_sense_pages`** (1 = single-plane, 512 = all-plane).
- **SPDK bench** `host/inflash_bench_spdk.c` with **`--threads T` / `--qpairs T`** (T pthreads, each its
  own qpair = its own SQ, pinned from `--basecore`; LPN range split across threads). One SPDK qpair =
  one SQ = owned by one dispatcher, so **effective controller parallelism = min(T, N)**.
- Harness `scripts/nvmevirt_spdk_dispatcher_sweep.sh`; plotter `scripts/plot_dispatcher_sweep.py`;
  summary `results_nvmevirt_spdk_dispatcher_sweep.csv` (semicolon-separated `cpus` field).

### 1.3 The flash mapping — VERIFIED (the routing key)
INFLASH_PIM has `SSD_PARTITIONS=1` (one conv_ftl over all 16 channels), `pgs_per_oneshotpg=1`
(`ONESHOT_PAGE_SIZE == FLASH_PAGE_SIZE == 4 KB == pgsz`), and `advance_write_pointer` increments
**channel first** (`wpp->ch++`, wrap at `nchs=16`, then `wpp->lun++`, wrap at 32). Prepopulation writes
LPNs `0,1,2,…` sequentially, so the maptbl places:

> **LPN `i` → channel `i % 16`, LUN `(i / 16) % 32`.** Hence **channel `c` owns exactly the LPNs
> `≡ c (mod 16)`**, and the 32-plane (32-LUN) set of channel `c` is `{ c + 16·lun : lun ∈ [0,32) }`
> (within the first line; the (ch,lun) pattern repeats every 512 LPNs at higher blk/pg).

This is the routing rule the host uses. **It MUST be verified at runtime before being trusted** (§3.1,
step 0) — a future allocator/config change would break it.

### 1.4 Numbers to beat / reference (report §14, single-plane, SPDK, default knobs, kernel 6.8.0-124)
| config (spread routing) | amortized µs / 512-set |
|---|---:|
| N=1, T=1 (baseline) | 151.9 |
| N=8, T=1 (1 SQ, 7 idle dispatchers) | 259.2 |
| **N=8, T=8 (matched, spread)** | **308.3** |
| all-plane, 1 cmd (any N) | 34.8 (`34152 ns`, independent of N) |
| flash-media floor (tR) | ≈ 30 |

**The number this task moves:** the single-plane amortized µs/512-set under **channel-affine** routing vs
the **spread** value at the same N (e.g. vs 308 µs at N=8). The all-plane 34.8 µs / `34152 ns` and the
single-plane per-op `30152 ns` must stay **unchanged**.

---

## 2. The design — and why it isolates the lock

`ssd_advance_nand` takes `ch->lock` (per channel) around the read-modify-write of `ch->perf_model` and
the addressed LUN's `next_lun_avail_time`. With spread routing, N dispatcher threads each issue commands
to random channels, so multiple dispatchers fight over the *same* channel lock → real cross-thread
contention on a kernel spinlock (cacheline ping-pong on the lock word + serialized critical sections).

**Channel-affine routing** assigns each channel to exactly one dispatcher and routes the host so that a
dispatcher's SQ only ever carries that channel's LPNs:
- Partition the 16 channels across the N dispatchers: dispatcher `d` owns channel set `C_d`.
  - **N=16 (canonical, the ask):** `C_d = {d}` — one channel = one 32-plane set per dispatcher.
  - **N=8:** `C_d = {d, d+8}` — 2 channels = 64 planes per dispatcher.
  - **N=4:** `C_d = {d, d+4, d+8, d+12}` — 4 channels = 128 planes per dispatcher.
- Host thread `t` owns qpair → SQ `qid = t+1` → dispatcher `(qid-1)%N = t` (when `T=N`). So host thread
  `t` must issue **only** LPNs with `(LPN % 16) ∈ C_t`.
- Then every per-channel lock `ch[c].lock` is acquired by **exactly one** dispatcher (the owner of `c`):
  uncontended. Commands to different LUNs of the same channel still serialize on that one lock (correct —
  same physical channel), but **no two dispatchers ever contend on it**.

This is a **host-side routing change only**. The module config (same `nr_dispatchers`, same `cpus=`, same
io_workers, same cores, same per-channel lock) is **identical** between the channel-affine and spread arms
— the *only* difference is which LPNs each host thread submits. That is what makes the comparison a clean
single-variable isolation of cross-dispatcher per-channel-lock contention: turbo state, LLC pressure,
io_worker count, and dispatcher count are all held fixed; only the lock-contention pattern changes.

**Caveat on confounds (state them; do not pretend they vanish):**
- The **io_worker funnel** is *not* removed by channel affinity: `__get_io_worker(sqid) =
  (sqid-1) % nr_io_workers` is independent of the channel partition, so N dispatchers still feed
  `nr_io_workers` workers. Because io_worker count is identical in both arms at a given N, it does not
  bias the affine-vs-spread *delta*, but it may cap the absolute throughput. Optionally also test with
  `nr_io_workers` raised (more cores) to check whether the io_worker stage, not the lock, is the limiter.
- **Turbo/LLC** are held fixed (same N, same cores in both arms).

---

## 3. Implementation tasks

### 3.1 Task CA — host-side channel-affine routing (`host/inflash_bench_spdk.c`)
- **Step 0 (verify the map):** add a one-shot verification path. Either (a) add a debug print in
  `conv_read`/the write path that emits `lpn -> ppa.g.ch` for a small LPN range to dmesg, run it once,
  and confirm `ch == lpn % 16`; or (b) trust §1.3's formula but **assert** it by issuing, per channel `c`,
  the LPN set `{c, c+16, …}` and confirming via the existing dmesg `inflash_dev_lat` observer / a
  per-(dispatcher,channel) counter (Task CB) that those commands only ever hit channel `c`. Do not run
  the experiment until the map is confirmed for the current build.
- Add a routing mode, e.g. **`--chan-affine`** (used together with `--threads N`): instead of giving
  worker `t` a contiguous LPN slice, give it the channel set `C_t` (computed from `t`, `N`, and
  `NCHANNELS=16` as in §2) and have it iterate **only LPNs with `(lpn % 16) ∈ C_t`** within
  `[0, maxpages)`. The default (no flag) keeps the §14 contiguous-slice "spread" behaviour.
- For a clean 512-plane-set count: with `N` dividing 16, the union of all workers' LPNs over one pass must
  still cover all 512 planes exactly once per set, so the amortized µs/512-set is comparable to §14.
  (E.g. N=16: worker `c` issues LPNs `{c, c+16, …, c+16·31}` = its channel's 32 planes; 16 workers × 32 =
  512.) Keep total requests and qd matched to §14 (e.g. 4096 requests = 8 sets, qd512 aggregate).
- Keep aggregate e2e = first submit (any thread) → last completion (any thread), as in `--threads`.
- Tag the CSV `host_stack` so affine vs spread rows are distinguishable (e.g. `spdk-t8-affine`).

### 3.2 Task CB — direct lock-contention measurement (the airtight evidence)
Latency deltas alone are weak (turbo/LLC noise). Measure cross-dispatcher contention on `ch->lock`
directly, two acceptable ways (do at least one):
- **lockstat (preferred, zero code):** build the module once with `CONFIG_DEBUG_LOCK_ALLOC` /
  `CONFIG_LOCK_STAT` available, `echo 1 > /proc/sys/kernel/lock_stat`, run, and read `/proc/lock_stat`
  for `ch->lock` contention counts/wait-time, affine vs spread. (Requires lockstat support in the running
  kernel; if unavailable, use the counter below.)
- **lightweight counter:** in `ssd_advance_nand`, replace `spin_lock(&ch->lock)` with a
  `spin_trylock` loop that increments a per-channel `contended` counter on failure (or an atomic global
  "contended acquisitions" counter), exposed via a `/proc/nvmev/` entry or dmesg dump. Reset per run.
  Expect: spread > 0 and growing with N; channel-affine ≈ 0. This is the headline evidence.

### 3.3 Task CC — (optional) per-(dispatcher,channel) access counter
To *prove* channel affinity actually holds (host routed correctly), add a counter
`disp_ch_hits[disp_id][ch]` incremented in `ssd_advance_nand` (the calling dispatcher's id can be passed
down or read from `smp_processor_id()` → dispatcher map). Dump via `/proc/nvmev/` at end of run. Under
channel-affine, each channel column must have exactly one non-zero dispatcher row; under spread, all rows
non-zero. This is the faithfulness check for invariant 2 below.

### 3.4 CPU budget (esp. N=16) — be explicit, it is awkward
- **N=4, N=8:** dispatchers + io_workers fit on P-cores cleanly (e.g. N=8 → `cpus=0,1,2,3,4,5,6,7,8,9`
  = 8 dispatchers + 2 io_workers), host `--threads N --basecore 16` on E-cores. Matches §14 layout.
- **N=16 (canonical one-channel-per-dispatcher):** 16 dispatchers need all 16 logical P-cores (cpu 0–15),
  leaving none for io_workers, but the module requires ≥1 io_worker. Resolve by **oversubscribing** two
  P-cores: pass `cpus=0,1,2,…,15,0,1` (first 16 = dispatchers cpu0–15; last two = io_workers co-located on
  cpu0, cpu1). Host uses all 16 E-cores (`--threads 16 --basecore 16`). **Document this oversubscription
  as a confound** (io_workers steal cycles from dispatchers 0,1). If it muddies the result, also report
  N=8 (clean) as the primary comparison and treat N=16 as the limiting illustration.

### 3.5 Backward compatibility
- No flag → spread routing (§14 behaviour), identical numbers. `nr_dispatchers` default 1. Device knobs,
  flash geometry, `conv_read`, and `compute_sense_pages` semantics unchanged. The contention counter (if
  added) must be ~free when uncontended (trylock-fast-path or a single `lock_stat` gate).

---

## 4. Faithfulness invariants (a reviewer will check these)

1. **Flash array unchanged.** All-plane device latency stays `34152 ns (sensed 512 pages)` and single-plane
   per-op stays `30152 ns (sensed 1 pages)` for every N and both routings (dmesg).
2. **Channel affinity actually holds.** Under `--chan-affine`, Task CC shows each channel touched by
   exactly one dispatcher (and Task CB shows ~0 contended acquisitions). If routing is wrong, the
   experiment is meaningless — verify before believing any speedup.
3. **Spread baseline reproduces §14** within run-to-run variance (e.g. N=8/T=8 ≈ 300–310 µs).
4. **No new media parallelism fabricated.** Channel-affine only removes *cross-thread lock contention*; it
   must not change the modeled device latency (per-op `30152 ns`) or let single-plane drop below the
   ~30 µs flash round. Same-channel commands still serialize on the (now single-owner) lock.
5. **Honest accounting.** Report dispatcher cores, io_workers, host threads/queues, and the channel→
   dispatcher partition for every point; note the N=16 io_worker oversubscription.

---

## 5. Experiments (single-plane, SPDK host path, default knobs, `compute_sense_pages=1`)

> Prepopulate first (8192 pages); CSVs to the **repo dir, never `/tmp`**; host on E-cores, NVMeVirt on
> P-cores; verify the LPN→channel map (§3.1 step 0) before trusting routing.

- **CA1 — map verification.** Confirm `ch == lpn % 16` (Task CC dump or dmesg). Gate for everything else.
- **CA2 — headline, matched-N affine vs spread.** Single-plane 4096 cmds (8×512-set) at qd512, `T=N`, for
  **N ∈ {4, 8, 16}**, each run **twice**: spread (`--threads N`) and channel-affine (`--threads N
  --chan-affine`). Report amortized µs/512-set for both; the delta is the per-channel-lock-contention cost.
- **CA3 — direct contention (the proof).** For each N, report Task CB's contended-acquisition count (or
  `/proc/lock_stat` `ch->lock` contentions + total wait-ns) for spread vs affine. Expect affine ≈ 0.
- **CA4 — faithfulness.** dmesg per-op `30152 ns` for both routings, all N; all-plane `34152 ns`
  unaffected; Task CC confirms single-owner-per-channel under affine.
- **CA5 — (optional) io_worker control.** Repeat CA2 at the best N with `nr_io_workers` raised (more cores)
  to test whether the io_worker funnel — not the lock — caps throughput.

---

## 6. Build / run mechanics (this machine)

```bash
cd /home/juchanlee/nvmevirt_pim
bash scripts/build.sh                                   # rebuild vs running kernel (uname -r); nr_dispatchers + locks
make -C host spdk SPDK_DIR=/home/juchanlee/spdk         # bench with --threads/--chan-affine
modinfo nvmev.ko | grep -E 'nr_dispatchers|compute_sense_pages'
sudo -v                                                 # passwordless sudo expires between turns

# Example: N=8, channel-affine, single-plane
sudo rmmod nvmev; sudo insmod nvmev.ko memmap_start=96G memmap_size=16G \
     cpus=0,1,2,3,4,5,6,7,8,9 nr_dispatchers=8 compute_sense_pages=1
sudo env PCI_ALLOWED=0001:10:00.0 NRHUGE=1024 DRIVER_OVERRIDE=uio_pci_generic \
     /home/juchanlee/spdk/scripts/setup.sh
OUT="$(sudo /home/juchanlee/spdk/build/bin/spdk_nvme_identify -r 'trtype:PCIe traddr:0001:10:00.0' 2>/dev/null)"
echo "$OUT" | grep -q 'NVMe Controller' && echo GATE-OK
# prepopulate, then: spread vs affine (CSV in repo dir)
sudo ./host/inflash_bench_spdk --bdf 0001:10:00.0 --compute --prepopulate --maxpages 8192 \
     --requests 1 --qdepth 1 --trials 1 --csv /dev/null
sudo ./host/inflash_bench_spdk --bdf 0001:10:00.0 --compute --requests 4096 --qdepth 512 --trials 10 \
     --threads 8 --basecore 16 --csv results_chanaffine_N8_spread.csv
sudo ./host/inflash_bench_spdk --bdf 0001:10:00.0 --compute --requests 4096 --qdepth 512 --trials 10 \
     --threads 8 --basecore 16 --chan-affine --csv results_chanaffine_N8_affine.csv
# restore: setup.sh reset; reload defaults; free hugepages
```

Gotchas already learned (do not relearn the hard way):
- **The per-io_worker lock is already in the tree and is mandatory** for `N>1`. Do not remove it. An
  un-serialized multi-dispatcher io_worker free-list corrupts into a cycle → soft lockup → **unkillable
  kthread → reboot** (reserved memory survives reboot via the boot cmdline, so the module reloads).
- **Passwordless sudo expires between turns** — `sudo -v` before a non-interactive batch.
- **Write `--csv` to the repo dir, not `/tmp`** — a CSV-open failure leaves the controller in a failed
  state; recover with `setup.sh reset` + `rmmod`/`insmod`.
- **`identify | head` gives SIGPIPE rc 141** — capture to a var first, then grep.
- Binding to SPDK removes `/dev/nvme1n1`; run kernel-driver and SPDK phases separately; `setup.sh reset`
  between them.
- The **dmesg `inflash_dev_lat` observer is the source of truth for the device model** — read it
  separately from host e2e; it is `printk_ratelimited`.
- **Always restore defaults at the end**: `insmod` with `nr_dispatchers=1 compute_sense_pages=512`,
  `setup.sh reset`, `echo 0 > /proc/sys/vm/nr_hugepages`, confirm `/dev/nvme1n1` is back.

---

## 7. Deliverables
1. **Code**: `--chan-affine` routing in `host/inflash_bench_spdk.c` (Task CA); a direct lock-contention
   measurement (Task CB — lockstat procedure and/or a per-channel contended-acquisition counter); optional
   per-(dispatcher,channel) access counter (Task CC) to verify affinity. **No change to the flash
   geometry, `conv_read`, `compute_sense_pages`, device knobs, or the per-channel/io_worker locks'
   semantics.** Default (no flag) = §14 spread behaviour.
2. **Harness**: `scripts/nvmevirt_spdk_chanaffine_sweep.sh` (RUN=1-guarded): for N ∈ {4,8,16}, reload,
   bind SPDK, prepopulate, run spread + affine, capture contention counters + dmesg, restore defaults.
   CSVs in repo dir; summary `results_nvmevirt_spdk_chanaffine_sweep.csv` (semicolon-separated `cpus`).
3. **Data + figure**: amortized µs/512-set, affine vs spread vs the §14 spread curve, across N; plus a
   panel/inset of contended-acquisition count (or `/proc/lock_stat` wait-ns) affine vs spread.
4. **Report**: extend `reports/report_nvmevirt_followup.md` with **§15 — "Channel-affine dispatchers:
   isolating per-channel media-lock contention"** covering the design (host-only routing, single-owner
   locks), the verified LPN→channel map, the affine-vs-spread comparison, the direct contention
   measurement, the faithfulness checks (dmesg unchanged, affinity verified), and the conclusion: *whether
   removing cross-dispatcher per-channel-lock contention recovers single-plane scaling (lock was a
   limiter) or not (confirms turbo/LLC/io_worker-funnel dominate — hardening §14)*. Update the §0 TL;DR
   with a one-line pointer.

---

## 8. Acceptance criteria
- [ ] LPN→channel map verified at runtime (`ch == lpn % 16`); `--chan-affine` routes each host thread to
      only its channel set; default = spread (§14) behaviour.
- [ ] Channel affinity proven: under affine, each channel touched by exactly one dispatcher (Task CC) and
      contended `ch->lock` acquisitions ≈ 0 (Task CB); under spread, contention > 0 and grows with N.
- [ ] **CA2 produced**: single-plane amortized µs/512-set, affine vs spread, for N ∈ {4,8,16}; spread
      reproduces §14 (e.g. N=8 ≈ 308 µs) within variance.
- [ ] **CA3 produced**: direct contention numbers affine vs spread.
- [ ] **Faithfulness**: dmesg per-op `30152 ns` (single-plane) and `34152 ns` (all-plane) unchanged for
      every N and both routings; no soft lockup / lockdep splat.
- [ ] CSV + figure produced; `reports/report_nvmevirt_followup.md` §15 added with the conclusion (lock
      limiter? yes/no) and its bearing on §14. **Module restored to defaults** (`nr_dispatchers=1`,
      `compute_sense_pages=512`), `/dev/nvme1n1` back on the kernel driver, hugepages freed.

---

## 9. Key references (verified code locations)
- Per-channel lock (the contention target): `ssd.c` `ssd_advance_nand` `spin_lock(&ch->lock)` around the
  `lun->next_lun_avail_time` / `chmodel_request(ch->perf_model,…)` RMW; `ssd.h` `struct ssd_channel.lock`;
  init `spin_lock_init(&ch->lock)` in `ssd_init_ch`.
- Dispatcher↔SQ ownership: `main.c` `nvmev_proc_dbs(disp_id, nr_disp)` (`(qid-1)%nr_disp`); `nr_dispatchers`
  param + `cpus=` parsing (first N → dispatchers).
- io_worker mapping/funnel: `io.c` `__get_io_worker` (`(sqid-1)%nr_io_workers`), per-io_worker lock in
  `__enqueue_io_req` / `schedule_internal_operation` / `__reclaim_completed_reqs`.
- Flash mapping (routing key): `conv_ftl.c` `advance_write_pointer` (ch-first, lines 235–247),
  `SSD_PARTITIONS=1` and `ONESHOT_PAGE_SIZE==FLASH_PAGE_SIZE==4KB` in `ssd_config.h` (INFLASH_PIM block) ⇒
  channel `c` ⇔ LPN `≡ c (mod 16)`; conv_read maptbl lookup `get_maptbl_ent` → `ppa.g.ch`.
- Host bench: `host/inflash_bench_spdk.c` (`--threads`/`--qpairs`/`--basecore`, worker_main, run_trial_mt).
- §14 result + harness: `reports/report_nvmevirt_followup.md` §14;
  `scripts/nvmevirt_spdk_dispatcher_sweep.sh`; `results_nvmevirt_spdk_dispatcher_sweep.csv`;
  `scripts/plot_dispatcher_sweep.py`.

---

## 10. Experiment B — one plane per dispatcher (planes = dispatchers): remove the per-dispatcher serial command intake

### 10.1 Summary & motivation

NVMeVirt's second fundamental fidelity gap (besides the shared media lock of Experiment A) is that **each
dispatcher kthread is serial**: `nvmev_proc_dbs()` scans its owned SQ doorbells one-by-one, and
`nvmev_proc_io_sq()` processes the new entries of an SQ in a serial `for` loop — there is no hardware
queue-arbitration / parallel command fetch as in a real NVMe controller. In §14 the single-plane 512-set
puts **512 ÷ N commands on each dispatcher**, so each controller core still serializes a large batch
(e.g. 64 commands/dispatcher at N=8) — the "shared dispatcher problem." Experiment B removes that batching
by setting the number of activated planes **equal to the number of dispatchers**: `P = N`, with `T = N`
host queues, so **each dispatcher processes exactly one command for one plane**. This is the maximal-
parallelism / minimal-serialization configuration; it measures the best case NVMeVirt can reach when no
dispatcher is oversubscribed, and — by contrast with §14's oversubscribed 512-set — shows how much of the
§14 degradation was per-dispatcher serial intake rather than a true parallel-activation floor.

### 10.2 Design

- **Config:** single-plane (`compute_sense_pages=1`), `nr_dispatchers=N`, host `--threads N` (one qpair =
  one SQ = one dispatcher), **one single-plane command per host thread** → `P = N` planes activated, one
  per dispatcher. Run with **channel-affine routing ON** (Experiment A's `--chan-affine`) so the `N`
  planes sit on `N` *distinct channels* (LPN `t` → channel `t`, lun 0): fully independent, no shared-LUN
  and no per-channel-lock contention, so Experiment B measures the pure intake/fan-out floor.
- **Sweep** `N = P ∈ {1, 2, 4, 8, 16}` (≤16, the channel count). Each trial = `N` threads each issuing one
  4 KB single-plane read; `e2e` = first submit (any thread) → last completion (any thread) = wall-clock to
  activate `N` planes. Repeat for many trials (e.g. 30) and take the median; keep one command in flight per
  thread (qd1/thread).
- **Two arms per N:**
  - **Parallel (the point):** `N` dispatchers, `N` queues, **1 cmd each** (`--threads N`,
    `--requests N`).
  - **Serial baseline:** the **same `N` planes** activated by **1 dispatcher, 1 queue, `N` commands**
    (`nr_dispatchers=1`, `--threads 1`, `--requests N`, `--qdepth N`) — the per-dispatcher serial intake.
- **References on the same plot:** the flash-media floor (single-op ≈ 30.8 µs / `30152 ns`), the
  all-plane 34.8 µs primitive, and §14's oversubscribed 512-set numbers (152 µs at N=1 → 308 µs at N=8).

### 10.3 Expected outcomes & interpretation
- If **parallel e2e stays ≈ 30–35 µs (≈ one tR round), roughly flat as N grows 1→16**, NVMeVirt *does*
  parallelize faithfully when balanced 1 command : 1 dispatcher — so §14's rise was **oversubscription
  (many serial commands per dispatcher) + contention**, not a fabricated serial wall. This is the
  positive companion to §14: the emulator reaches the floor exactly when the per-dispatcher serial intake
  is reduced to one command.
- If **parallel e2e rises with N even at 1 cmd/dispatcher**, a deeper limit remains (host fan-out skew
  across `T` threads, all-core turbo throttling, or the io_worker stage) — report which, since it bounds
  any multi-core controller model in NVMeVirt regardless of per-dispatcher batching.
- The **serial baseline** should track `≈ tR + (N-1)·t_cmd` (small at low N because `t_cmd ≈ 0.3 µs`, so
  the parallel/serial gap is modest below ~100 commands); state this explicitly so the reader sees the
  per-dispatcher serial penalty only becomes large at the 512-command scale of §14.

### 10.4 Variant — fix N, sweep plane count (per-dispatcher serial-batch depth)

§10.2 fixes the batch at one command per dispatcher. This variant fixes the dispatcher count and *grows*
the per-dispatcher serial batch, exposing the serial-intake cost as a clean function of batch depth and
bridging Experiment B (batch = 1, at the floor) to §14 / Experiment A (batch = 64 at N=8, the
oversubscribed 512-set).

- **Fix `N = 8`** dispatchers, `T = 8` host queues, **channel-affine ON** (each dispatcher owns 2 channels
  = 64 planes; its commands stay on its own channels → zero cross-dispatcher lock contention, so any climb
  is *purely* per-dispatcher serial intake, not contention).
- **Sweep the activated plane count** `P ∈ {8, 32, 128, 512}` (= `{N, 4N, 16N, 64N}`), so each dispatcher
  serially processes `P/N = {1, 4, 16, 64}` commands per activation. The `P` planes are routed
  channel-affine across the 8 dispatchers (`P/8` LPNs drawn from each dispatcher's own channel set).
- **Metric:** e2e to activate `P` planes (median over trials), per-plane ns = `e2e/P`, and the derived
  per-command serial-intake cost = the **slope of e2e vs `P/N`** (per-dispatcher batch depth). Plot e2e
  (and per-plane ns) vs `P/N`.
- **Expected:** at `P=N` (batch 1) e2e ≈ the floor (~30–35 µs); as batch grows it climbs ~linearly,
  `e2e ≈ tR + (P/N − 1)·t_intake`, reaching the channel-affine N=8 value at `P=512` (batch 64) — which
  **must agree with Experiment A's N=8 affine point** (cross-experiment consistency check). The slope
  quantifies the per-dispatcher serial command-intake cost (≈ the ~0.3 µs/cmd seen amortized in §14),
  now shown *directly* as the mechanism that makes the 512-set expensive.
- **Optional contention overlay:** repeat one `P` (e.g. 512) in **spread** routing to show contention adds
  *on top of* the serial-intake climb — visually separating §14's two components (serial intake vs
  per-channel-lock contention) on a single axis.

### 10.5 Implementation
- **Reuses Experiment A's host changes** (`--threads`, `--chan-affine`) — no new host routing code needed:
  `--threads N --requests N --chan-affine` already yields one channel-affine command per dispatcher.
  Optionally add a convenience flag `--planes P` (alias for `--threads P --requests P`) for clarity.
- Add a harness `scripts/nvmevirt_spdk_planes_eq_disp_sweep.sh` (RUN=1-guarded; or a mode of the
  Experiment-A harness): for `N ∈ {1,2,4,8,16}`, reload module with `nr_dispatchers=N`, bind SPDK,
  prepopulate, run the parallel arm (`--threads N --requests N --chan-affine`) and the serial arm
  (`nr_dispatchers=1`, `--threads 1 --requests N --qdepth N`), capture dmesg, restore defaults. CSVs in
  repo dir; summary `results_nvmevirt_spdk_planes_eq_disp.csv`. (N=16 uses the §3.4 io_worker
  oversubscription `cpus=0,…,15,0,1`; host `--threads 16 --basecore 16`.)

### 10.6 Faithfulness invariants (Experiment B)
1. **Device model unchanged:** each single-plane command's dmesg line is still `30152 ns (sensed 1 pages)`
   for every N; activating `N` planes on `N` distinct LUNs/channels is one parallel tR round in the model.
2. **Affinity verified** (reuse Experiment A's Task CC counter): each of the `N` planes is on a distinct
   channel and each dispatcher issued exactly one `ssd_advance_nand` call.
3. **Honest accounting:** report `N` (= planes = dispatchers = host queues), io_workers, and CPU layout
   per point; for N=16 note the io_worker oversubscription confound.

### 10.7 Deliverables & acceptance (Experiment B)
- **Data + figures:** (i) §10.2/10.3 — e2e-to-activate-`N`-planes vs `N`, parallel vs serial arms, against
  the ~30 µs floor, the 34.8 µs all-plane line, and §14's 512-set curve; (ii) §10.4 variant — e2e (and
  per-plane ns) vs per-dispatcher batch depth `P/N` at fixed `N=8` channel-affine, with the fitted slope
  (= per-command serial-intake cost) annotated and the `P=512` point shown to coincide with Experiment
  A's N=8 affine value (and, optionally, the spread overlay separating serial-intake from contention).
  Harness: `scripts/nvmevirt_spdk_planes_eq_disp_sweep.sh` also drives the fixed-N plane-count sweep
  (CSV e.g. `results_nvmevirt_spdk_batchdepth_N8.csv`).
- **Report:** add **§16 — "One plane per dispatcher: removing the per-dispatcher serial intake"** to
  `reports/report_nvmevirt_followup.md` (Experiment A is §15), covering both the planes=dispatchers sweep
  and the fixed-N batch-depth variant, the faithfulness checks, and the conclusion: *whether NVMeVirt
  reaches the flash floor when balanced 1 command : 1 dispatcher, how the cost grows with per-dispatcher
  batch depth, and therefore how much of §14's degradation was per-dispatcher serial intake vs. per-channel
  contention.* Update the §0 TL;DR pointer.
- **Acceptance:**
  - [ ] `P = N` planes activated with one command per dispatcher (`--threads N --requests N
        --chan-affine`); serial baseline (`nr_dispatchers=1`, `N` cmds on one queue) captured; sweep
        `N ∈ {1,2,4,8,16}`.
  - [ ] Parallel e2e-vs-N curve produced and compared to the ~30 µs floor and §14's 512-set curve;
        interpretation (flat ⇒ faithful parallelism / rises ⇒ residual limit named) stated.
  - [ ] **Variant produced:** fixed `N=8`, channel-affine, `P ∈ {8,32,128,512}`; e2e vs batch depth `P/N`
        plotted with fitted per-command serial-intake slope; `P=512` point matches Experiment A's N=8
        affine value (consistency check).
  - [ ] dmesg per-op `30152 ns` unchanged for every N and P; affinity verified (Task CC); no lockdep splat.
  - [ ] Figures + report §16 added; **module restored to defaults**, `/dev/nvme1n1` back, hugepages freed.
