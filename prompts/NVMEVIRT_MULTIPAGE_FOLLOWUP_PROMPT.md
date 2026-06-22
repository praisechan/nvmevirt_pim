# Follow-up Experiment Prompt: Multi-Page In-Flash Compute on **NVMeVirt** (the faithful-model leg)

> **Use this file as the task specification.** It is the NVMeVirt counterpart of
> `prompts/SWARMIO_MULTIPAGE_FOLLOWUP_PROMPT.md`. It re-runs the *multi-page / large-request*
> idea on stock **NVMeVirt** (`INFLASH_PIM` profile) instead of SwarmIO, so that the
> convergence test is done on the emulator that **physically models plane-level sensing time
> and lets the 8 µs command overhead emerge from the channel model** rather than injecting it
> as a parameter. It is self-contained: it restates the verified NVMeVirt state, *why this leg
> matters next to the SwarmIO leg*, the device constraints, the experiments (in order), the
> emergent-`t_cmd` characterization (the crux — measured, not tuned), build/run mechanics, the
> model, and deliverables.

---

## 0. One-paragraph summary

The SwarmIO follow-up (`prompts/SWARMIO_MULTIPAGE_FOLLOWUP_PROMPT.md`) showed that presenting a
full 512-unit round with **far fewer, larger requests** removes host-submission serialization
and lets end-to-end latency approach the modeled ≈ 38 µs. But SwarmIO models the device with an
**abstract Tmax/Lmin delay** (`sched_delay`/`min_delay`): it has *no* NAND/channel model, so the
8 µs command overhead there is a typed-in module parameter and "plane-level sensing time" is only
an opaque per-instance occupancy. **NVMeVirt is the faithful leg**: `tR = 30 µs` is charged as a
real `pg_rd_lat` against each LUN's `next_lun_avail_time` in `ssd_advance_nand()` (genuine
plane-level sensing and serialization), and the **8 µs `t_cmd` *emerges*** from the channel model
(the tiny per-LUN compute-result transfers of the 32 LUNs sharing a channel serialize). NVMeVirt's
original bottleneck was its **single dispatcher** serializing command *issue* at ~1 µs/command, so
the `1 request = 1 page = 1 LUN` mapping needed 512 submissions per round and diverged
(~557 µs vs 38 µs). This experiment applies the **same multi-page fix** on NVMeVirt: pack many
pages (LUNs) into each NVMe command so the single dispatcher fetches only a handful of commands
per round, and test whether the **faithful** emulator converges toward the analytic round
latency — while **measuring whatever `t_cmd` emerges** from the default channel model (the 38 µs /
8 µs figure is a loose reference from the analytic model, **not** a target to calibrate to).

---

## 1. Verified state to build on (do not re-derive)

### 1.1 Machine & module
- **CPU**: i9-13900F, 32 logical (P-cores → 0–15, E-cores → 16–31), no Intel DSA (irrelevant to
  NVMeVirt). **RAM** ~94 GiB. **Reserved memmap**: `memmap=16G$64G` and `memmap=16G$96G` →
  use **`memmap_start=96G memmap_size=16G`** for NVMeVirt.
- **NVMeVirt `INFLASH_PIM` profile is already built and proven to load** (`reports/report.md`,
  `results_raw.csv`/`results_enriched.csv`). Geometry: `NAND_CHANNELS=16`,
  `LUNS_PER_NAND_CH=32`, `PLNS_PER_LUN=1` ⇒ **512 independent LUNs** (LUN-as-plane);
  `FLASH_PAGE_SIZE=4 KB`; capacity ≈ 8 GiB (`BLKS_PER_PLN=4`, `PGS_PER_BLK=2048`,
  4096 pages/LUN). The module is `nvmev`, device appears as **`/dev/nvme1n1`** after load.
- **Compute read path is in place** (`conv_ftl.c:833 conv_read`, guarded by
  `#if defined(INFLASH_COMPUTE)`): `interleave_pci_dma=false` and `xfer_size=COMPUTE_RESULT_SIZE`
  per NAND op, so host page-data is **not** transferred — only the tiny result crosses the
  channel. `ret->nsecs_target` is already `max` across all LUNs touched. **Do not change this
  path's structure, and do **not** retune `COMPUTE_RESULT_SIZE` — keep the defaults (§5).
- **Current `INFLASH_PIM` knobs** (`ssd_config.h:244-301`): `MDTS=6`, `COMPUTE_RESULT_SIZE=64`,
  `FW_CH_XFER_LATENCY=0`, `NAND_CHANNEL_BANDWIDTH=800ull` MB/s, `NAND_READ_LATENCY_*=30000`,
  `CELL_MODE=CELL_MODE_SLC`.

### 1.2 Prior NVMeVirt result (the thing we are fixing)
With `1 request = 1 × 4 KB page = 1 LUN`, a single io_uring ring, and qdepth=N (see
`reports/report.md`, `results_enriched.csv`; summarized in
`prompts/SWARMIO_INFLASH_COMPUTE_EMULATION_PROMPT.md` §1.1):

| N (qdepth=N) | NVMeVirt e2e | `T_model = 38µs·⌈N/512⌉` | rel err |
|--------------|--------------|--------------------------|---------|
| 1 | ~36 µs | 38 µs | ~−5 % |
| 8 | ~45 µs | 38 µs | +17 % |
| 64 | ~116 µs | 38 µs | +206 % |
| 512 | ~557 µs | 38 µs | +1366 % |
| 4096 | ~4240 µs | 304 µs | +1295 % |

Shape `e2e(N) ≈ 30 µs floor + N × ~1.0 µs`. Sanity checks passed (1 req ≈ tR; 2 reads to the
**same** LUN ≈ 2·tR ≈ 67 µs), so the per-LUN timeline is correct. The divergence is **NVMeVirt's
single dispatcher** serializing command issue, *not* the timing model. Multi-page requests reduce
the **command count per round** the single dispatcher must fetch — exactly the lever that helped
on SwarmIO.

### 1.3 Harness (already built — reuse)
- `host/inflash_bench.c` — io_uring 4 KB-aligned `O_DIRECT` reads, LPN-striped; **already supports
  `--reqsize BYTES` / `--pages-per-req K`** (added for the SwarmIO follow-up; `g_reqsize`,
  options at `host/inflash_bench.c:386-405`, io_uring read at `:255`, libaio at `:149`). Options:
  `--dev --requests N --qdepth Q --trials T --cpu C --csv --prepopulate --maxpages --samelun
  --reqsize --pages-per-req`. **Reuse unchanged** — it is the same binary used against SwarmIO,
  giving an apples-to-apples NVMeVirt-vs-SwarmIO comparison.
- `scripts/build.sh`, `scripts/load.sh`, `scripts/microtest.sh`, `scripts/sweep.sh`,
  `scripts/plot.py` — the original NVMeVirt harness. `scripts/swarmio_model.py` enriches a raw CSV
  with `T_model_ns`/`abs_err`/`rel_err` (page/`N`-based formula; stdlib only) — reuse it for the
  NVMeVirt rows too (set `N_or_iodepth` = `total_pages`). `scripts/swarmio_csv_schema.md` is the
  CSV contract. `scripts/swarmio_plot.sh` makes gnuplot figures (gnuplot 5.4 present;
  matplotlib/`pip3` are broken on this box — prefer gnuplot/CSV).

---

## 2. Why this NVMeVirt leg matters (what it tests that SwarmIO cannot)

This is the **faithfulness** leg of the study. Make these the analysis spine of the report:

1. **Plane-level sensing is real here.** `tR = 30 µs` is `pg_rd_lat` charged per LUN against
   `next_lun_avail_time` in `ssd_advance_nand()` (`ssd.c`). Two reads to the same LUN serialize
   to ~2·tR; reads to different LUNs overlap. SwarmIO only approximates this with an opaque
   `sched_delay`.
2. **`t_cmd` emerges, it is not a parameter.** It is the sum of the per-LUN
   `COMPUTE_RESULT_SIZE` transfers of the LUNs that share a channel, serialized in
   `channel_model.c`. Therefore **`t_cmd` is *not* constant** — it scales with how many LUNs in a
   channel are active in a round. A lone 4 KB request pays ≈ tR + (one tiny transfer) ≈ **30 µs**;
   a **saturated** round (all 32 LUNs/channel active) pays ≈ tR + `t_cmd`. **Do not tune anything
   to force `t_cmd` to 8 µs** — 8 µs was a loose analytic guess; the point of using the faithful
   emulator is to find out what the channel model actually produces. With the default knobs that
   value is ≈ 2.6 µs (saturated round ≈ 32.6 µs), and that is a legitimate result to report.
   The multi-page sweep walks exactly this load-dependent curve, which is the physically
   meaningful behavior the SwarmIO leg flattens into a single number. **Measure and report it as
   observed**; do not assume a flat 38 µs per request.
3. **The convergence question is the same, the mechanism is the emulator's, not the host's.**
   On SwarmIO the limiter was host-side single-ring submission. On NVMeVirt the limiter is the
   **single dispatcher** (a device-side property). Multi-page packing attacks both. The headline
   question: does the *faithful* emulator converge to its own saturated-round latency
   (≈ tR + emergent `t_cmd`) once the per-round command count is small — and what is that emergent
   `t_cmd`?

---

## 3. The key device constraint: MDTS caps pages (LUNs) per command

- `INFLASH_PIM` sets `#define MDTS (6)` (`ssd_config.h:256`). With a 4 KB minimum page, the
  expected max transfer per NVMe command is `2^6 × 4 KB = 256 KB = 64 pages = 64 LUNs`
  (SwarmIO's `MDTS=5` gave 128 KB / 32 pages — confirmed live there). **Verify on the live
  device** after load: `cat /sys/block/nvme1n1/queue/max_hw_sectors_kb` (expect ~256). If it
  differs, recompute pages/command from the observed value and adjust the layouts below.
- In `conv_read`, a command spanning `K` consecutive 4 KB LPNs issues **K parallel per-LUN NAND
  ops** (each its own `ssd_advance_nand`, all starting at `nsecs_start`, serialized only per
  LUN). Consecutive LPNs stripe round-robin across `ch → lun` (`advance_write_pointer`), so a
  256 KB command covers 64 distinct LUNs = 4 LUNs in each of the 16 channels.
- **Consequence**: covering all 512 LUNs in one round needs `512 / 64 = 8` requests of 256 KB
  (vs. 512 requests of 4 KB) at `MDTS=6` — an **8× reduction** in commands the single dispatcher
  must fetch. To cover 512 LUNs with **one** command you must raise MDTS (§4.B).
- **Host-side splitting**: a single read larger than `max_hw_sectors_kb` is split by the Linux
  block layer into MDTS-sized NVMe commands automatically — fewer *io_uring* submissions but still
  multiple commands on one SQ reaching the one dispatcher. Raising MDTS (§4.B) is the only way to
  make **one NVMe command** span more than 64 LUNs.

---

## 4. Experiment 1 (primary): multi-page / large requests on NVMeVirt

**Hypothesis**: packing many LUNs per command shrinks the per-round command count enough that the
single dispatcher can present a full 512-LUN round inside one ~tR window, so end-to-end latency
for one round converges toward the emulator's saturated-round device latency
(≈ tR + emergent `t_cmd`) — on the faithful emulator. (Use the analytic 38 µs only as an overlay
reference; the convergence target is whatever the device model reports for a saturated round.)

### 4.A — Multi-page requests up to the MDTS cap (no rebuild)
1. **Reuse `host/inflash_bench --reqsize`** (already implemented). Each request reads `reqsize`
   bytes (multiple of 4 KB, ≤ `max_hw_sectors_kb`) at offset `lpn*4096`, `lpn` advancing by
   `reqsize/4096` per request so requests tile distinct LUN ranges. (Confirm the in-tree binary's
   `lpn`-advance matches this tiling; the SwarmIO follow-up used the same striping.)
2. **Saturated-round layout**: with `K = reqsize/4096` pages/req and `R = 512/K` requests at
   offsets `i*reqsize` (`i=0..R-1`), the R requests cover LUNs `[0,511]` exactly once. Issue all R
   at `qdepth=R`. With `MDTS=6` (K ≤ 64): sweep `K ∈ {1,2,4,8,16,32,64}` ⇒
   `R ∈ {512,256,128,64,32,16,8}`. **Expectation**: measured e2e falls toward the saturated-round
   device latency (≈ tR + emergent `t_cmd`) as R shrinks; identify the R (command count) at which
   measured e2e is within 10 % of that saturated-round value. Contrast against the ~557 µs
   `512×4 KB` baseline from §1.2.
3. **Throughput-with-depth sweep**: at fixed `K=64`, vary total pages (multiple rounds) to confirm
   the per-round latency scales as `⌈total_pages / 512⌉` rounds (overlay `T_model = 38 µs ×
   ⌈total_pages/512⌉` as the analytic reference).
4. **Microtests** (add to / mirror `scripts/microtest.sh`):
   (i) one 256 KB request (64 LUNs) → device e2e well under a 4 KB-per-LUN round; report it
   against the *partial-round* emergent value (tR + 4 LUNs/ch × per-LUN cmd), **not** a flat 38 µs;
   (ii) 8 × 256 KB covering all 512 LUNs → the saturated round, only 8 commands; report the
   measured device e2e (expected ≈ tR + emergent `t_cmd`);
   (iii) two 256 KB requests to the **same** 64-LUN range → expect ≈ 2·tR ≈ 67 µs (same-LUN
   serialization preserved through the multi-page path).

### 4.B — Raise MDTS so one command spans all 512 LUNs (rebuild)
1. In `ssd_config.h`, raise `INFLASH_PIM`'s `#define MDTS (6)` to **`9`** (`2^9 = 512 pages = 2 MB`
   max per command). Rebuild (`scripts/build.sh`) + reload. Confirm `max_hw_sectors_kb` grows
   (≈ 2048). **Clearly comment the change and gate/revert it** so the default profile stays a
   realistic SSD; document it as a single-dispatcher-isolation probe.
2. **Cleanest single-round test**: issue **one** 2 MB request (`--reqsize $((512*4096))`,
   `--requests 1 --qdepth 1`) at `lpn 0` → spans all 512 LUNs in one command → the single
   dispatcher fetches exactly one command → expect device e2e ≈ tR + the now-fully-emergent
   `t_cmd`. This most directly realizes the user's idea ("bigger requests, fewer requests fully
   utilize all planes") and isolates the timing model from dispatcher serialization entirely.
3. Sweep `reqsize ∈ {256 KB, 512 KB, 1 MB, 2 MB}` at `qdepth=1` and small qdepths; record e2e vs
   the analytic reference `T_model = 38 µs × ⌈pages_per_req / 512⌉` and vs the measured
   saturated-round device latency.

### 4.A/4.B acceptance
- A 512-LUN round is presented with ≤ 8 (4.A, `MDTS=6`) or **1** (4.B, `MDTS=9`) command(s) and
  measured **device** e2e ≈ (tR + emergent `t_cmd`) ± host/PCIe/dispatcher overhead (vs ~557 µs
  for 512×4 KB) — i.e. it converges to the emulator's own saturated-round latency.
- The per-round latency scales as `⌈total_pages/512⌉` rounds across request sizes (analytic
  `T_model` overlaid as a reference, not a pass/fail target).
- The **emergent `t_cmd` is measured and reported as observed** (≈ 2.6 µs at default knobs, so a
  saturating command ≈ 32.6 µs while a lone 4 KB request ≈ 30 µs) — not tuned to any figure.
- If achieved, **convergence is confirmed on the faithful emulator** and the prior divergence is
  conclusively attributed to single-dispatcher command count.

---

## 5. The emergent `t_cmd`: measure it, do **not** tune it (the crux)

This is what distinguishes the NVMeVirt leg from SwarmIO: `t_cmd` **comes out of the channel
model** instead of being typed in. **Keep the default knobs** (`COMPUTE_RESULT_SIZE=64`,
`FW_CH_XFER_LATENCY=0`, `NAND_CHANNEL_BANDWIDTH=800 MB/s`) and report whatever the model produces.
The 8 µs in the analytic model was only a guess — the goal is to discover the real value, not to
make the emulator match the guess.

- With the defaults the per-LUN result transfer ≈ `COMPUTE_RESULT_SIZE / NAND_CHANNEL_BANDWIDTH`
  = `64 B / 800 MB/s ≈ 80 ns`, so a saturated channel (32 LUNs serializing) yields
  `t_cmd ≈ 32 × 80 ns ≈ 2.6 µs` and a saturated-round device latency ≈ **32.6 µs**, not 38 µs.
  **This is an expected and acceptable result** — report it; do not "fix" it by enlarging
  `COMPUTE_RESULT_SIZE` / `FW_CH_XFER_LATENCY` / lowering bandwidth. (If you want to *understand*
  sensitivity, a single optional side-note run varying one knob is fine, but the headline numbers
  use the defaults.)
- **Characterization microtests** (report values as observed — these are measurements, not
  pass/fail calibration):
  - one 4 KB request → device e2e ≈ **tR ≈ 30 µs** (one tiny transfer on one channel; negligible).
  - one saturated round (all 512 LUNs, via 8 × 256 KB or 1 × 2 MB) → device e2e ≈ tR + emergent
    `t_cmd` (≈ **32.6 µs** at default knobs).
  - a **half-full** channel (e.g. 256 LUNs total, 16 LUNs/channel) → `t_cmd` ≈ half the saturated
    value, confirming `t_cmd` scales with active-LUNs-per-channel (the emergent, non-parameterized
    behavior the user asked for).
- Read NVMeVirt's reported **device** latency (`nsecs_target − nsecs_start`) separately from the
  host wall-clock e2e so the emergent `t_cmd` is read off the model, not contaminated by host
  overhead. Expose it via the existing dmesg/instrumentation used in `reports/report.md`, or add a
  minimal counter if absent.

---

## 6. Build / run mechanics (this machine)

```bash
cd /home/juchanlee/nvmevirt_pim

# host bench already supports --reqsize; rebuild only if you touch it (no sudo):
make -C host            # or: cc -O2 host/inflash_bench.c -luring -o host/inflash_bench

# build NVMeVirt INFLASH_PIM (Kbuild already targets it; keep default knobs — do NOT retune
# COMPUTE_RESULT_SIZE; change MDTS only for Exp 4.B):
bash scripts/build.sh           # wraps make against /lib/modules/$(uname -r)/build

# pre-flight: SwarmIO and NVMeVirt contend for the device/memmap — unload swarmio first.
lsmod | grep -E 'nvmev|swarmio'
sudo rmmod swarmio 2>/dev/null
sudo rmmod nvmev   2>/dev/null   # if an old nvmev is loaded

# load NVMeVirt on the 96G/16G region; device = /dev/nvme1n1
bash scripts/load.sh            # confirm it uses memmap_start=96G memmap_size=16G; set cpus=
dmesg | tail -30 | grep -iE 'nvmev|tt_luns|tt_pls'   # expect tt_luns=512, tt_pls=512
lsblk | grep nvme1n1
cat /sys/block/nvme1n1/queue/max_hw_sectors_kb        # expect ~256 (MDTS=6) or ~2048 (MDTS=9)

# multi-page saturated round (Exp 4.A): 8 × 256 KB covers all 512 LUNs; pin to E-cores,
# keep NVMeVirt dispatcher/worker cpus= disjoint from the host cores:
sudo taskset -c 16-31 host/inflash_bench --dev /dev/nvme1n1 --reqsize 262144 \
     --requests 8 --qdepth 8 --trials 15 --csv results_nvmevirt_reqsize_raw.csv
```

Constraints: **keep authoring and verification as separate passes.** Do **not** run `sudo` from
non-interactive contexts without a fresh `sudo -v` (passwordless sudo only inside that window).
For any user-only action (insmod/rmmod, GRUB, reboot), surface it to the user (Slack `notify.sh`
exists but its webhook has returned HTTP 000 — surface inline as well). `isolcpus` is not set; for
low-noise timing recommend (but don't require) a GRUB `isolcpus` change as a user action and
document whichever was used.

---

## 7. Model

- **Analytic reference model** for a full round: `T_model = 38000 × ⌈total_pages / 512⌉` ns, where
  `total_pages = Σ_requests (reqsize / 4096)` and `38 µs = tR(30 µs) + t_cmd(8 µs guess)`. Overlay
  this as a **reference line only** — the convergence target is the emulator's *measured*
  saturated-round device latency (≈ tR + emergent `t_cmd`, ≈ 32.6 µs at default knobs), not the
  38 µs guess. The convergence independent variable is **command count per round** (= `R = 512 / K`),
  not page count.
- **Partial-round nuance (report it):** for a round that does *not* saturate every channel, the
  emergent device latency is `tR + (active_LUNs_per_channel) × per_LUN_cmd`, i.e. **below the
  saturated value**. A lone 4 KB request ≈ tR ≈ 30 µs. This load-dependent curve is the physically
  faithful behavior NVMeVirt produces and SwarmIO's flat `sched_delay` cannot.
- Reuse `scripts/swarmio_model.py` for enrichment (set CSV `N_or_iodepth` = `total_pages`); its
  `T_model` column is the analytic reference. Also compute error against the *measured*
  saturated-round latency if a second reference column is useful. Extend only if a per-request-size
  breakdown is needed.

---

## 8. Deliverables

1. **Code/config**: **no retuning** of `COMPUTE_RESULT_SIZE`/`FW_CH_XFER_LATENCY`/bandwidth — keep
   the default `INFLASH_PIM` knobs. The only source change is, for Exp 4.B, the `MDTS` bump
   (commented + gated/reverted so the default stays realistic). No structural change to
   `conv_read`'s compute path. If you add a device-latency counter, keep it minimal and documented.
2. **Harness**: a sweep script (add `scripts/nvmevirt_reqsize_sweep.sh` or extend `scripts/sweep.sh`)
   emitting the existing CSV schema (`scripts/swarmio_csv_schema.md`); `RUN=1`-guarded sudo, host
   cores disjoint from NVMeVirt `cpus=`. Reuse `host/inflash_bench` unchanged.
3. **Data + figures**: `results_nvmevirt_reqsize_raw.csv` → enriched via `swarmio_model.py` →
   figures via `swarmio_plot.sh`: (a) **device e2e vs command-count-per-round** (overlay the
   ~557 µs 512×4 KB baseline, the multi-page curve, the measured saturated-round latency, and the
   38 µs analytic reference); (b) **emergent `t_cmd` vs active-LUNs-per-channel** (the
   characterization curve: ~30 µs lone-page → saturated-round value); (c) optional
   NVMeVirt-vs-SwarmIO overlay of latency-vs-submission-count using the shared schema.
4. **Report**: `reports/report_nvmevirt_followup.md` covering: single-dispatcher recap (§1.2), the
   multi-page design + results (does device e2e converge to the saturated-round latency as command
   count drops? at what K/R?), the **emergent-`t_cmd` measurement** (lone-page ≈ 30 µs, saturated
   ≈ 32.6 µs at default knobs, half-channel in between — reported as observed, not tuned), Exp 4.B
   single-command result if run, and an explicit **NVMeVirt-vs-SwarmIO** comparison: the faithful
   emulator reproduces plane-level sensing and an emergent (load-dependent) command overhead, where
   SwarmIO uses a flat parameterized delay.

---

## 9. Acceptance criteria
- [ ] `INFLASH_PIM` built with **default knobs** (no `COMPUTE_RESULT_SIZE` retuning); microtests
      report a **lone 4 KB request ≈ 30 µs** and a **saturated round ≈ tR + emergent `t_cmd`**
      (≈ 32.6 µs at defaults) — measured, not calibrated to any target.
- [ ] A 512-LUN round is presented with ≤ 8 (Exp 4.A) or 1 (Exp 4.B) command(s); measured device
      e2e reported vs the analytic 38 µs reference, the measured saturated-round latency, and the
      prior ~557 µs 512×4 KB result; the command-count at which e2e is within 10 % of the measured
      saturated-round latency is identified.
- [ ] Per-round latency scales as `⌈total_pages/512⌉` rounds across request sizes (analytic
      `T_model` overlaid as reference); the partial-round `t_cmd` scaling is shown.
- [ ] CSV (shared schema) + gnuplot figures produced; NVMeVirt-vs-SwarmIO overlay included.
- [ ] `reports/report_nvmevirt_followup.md` gives an honest verdict on whether multi-page packing
      lets the **faithful** emulator converge end-to-end to its saturated-round latency, reports the
      emergent `t_cmd` as observed, and contrasts emergent vs parameterized `t_cmd` and
      plane-level-sensing fidelity against the SwarmIO leg.
- [ ] memmap `96G/16G` used cleanly; `swarmio` unloaded first; `lsmod`/`dmesg` checked before each
      (re)load.

## 10. Key code references
- Compute read path: `conv_ftl.c:833` (`conv_read`), `INFLASH_COMPUTE` guards at `:856-861`,
  `:905-909`, `:921-925`; `nsecs_target=max` at `:932`.
- Timing primitive (plane-level sensing): `ssd_advance_nand()` in `ssd.c` (NAND_READ charges
  `pg_rd_lat` per LUN against `next_lun_avail_time`).
- Channel model (emergent `t_cmd`): `channel_model.c` / `channel_model.h`; per-channel firmware
  overhead `fw_ch_xfer_lat` in `ssd_init_ch()` (`ssd.c`).
- Profile / knobs: `ssd_config.h:244-301` (`INFLASH_PIM`: `MDTS`, `COMPUTE_RESULT_SIZE`,
  `FW_CH_XFER_LATENCY`, `NAND_CHANNEL_BANDWIDTH`, `NAND_READ_LATENCY_*`).
- Host bench (reuse, `--reqsize` present): `host/inflash_bench.c` (options `:386-405`, io_uring
  read `:255`, libaio `:149`).
- Harness: `scripts/build.sh`, `scripts/load.sh`, `scripts/microtest.sh`, `scripts/sweep.sh`,
  `scripts/swarmio_model.py`, `scripts/swarmio_plot.sh`, `scripts/swarmio_csv_schema.md`.
- Prior NVMeVirt baseline + root cause: `reports/report.md`, `results_enriched.csv`;
  SwarmIO counterpart: `prompts/SWARMIO_MULTIPAGE_FOLLOWUP_PROMPT.md`, `reports/report_swarmio.md`.
```
