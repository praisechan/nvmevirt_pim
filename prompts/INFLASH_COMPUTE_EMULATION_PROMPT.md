# Implementation Prompt: SPDK-based In-Flash Computing Emulation on NVMeVirt

> **Use this file as the task specification** for an engineer/agent implementing the
> experiment. It is self-contained: it states the goal, the analytic model to be
> validated, the relevant NVMeVirt internals (with file/line references), the exact
> implementation tasks, the experiment plan, and the report to produce.

---

## 0. One-paragraph summary

I want to **validate an analytic latency model of in-flash computing** by emulating it on
**NVMeVirt** (a software-defined virtual NVMe device, Linux kernel module) driven by an
**SPDK** user-space host application. I am **not** implementing a real ANNS workload — the
attached paper `CIKM25_InstANNS.pdf` is referenced **only** as prior art proving that
"SPDK + NVMeVirt + a custom compute-style NVMe command" is a viable methodology. The
deliverable is **(a)** a working emulation that issues in-flash-compute requests utilizing
all NAND planes, and **(b)** a report comparing my analytic model against the end-to-end
latency NVMeVirt reports, as a function of the number of requests.

---

## 1. Objective and what "validation" means here

### 1.1 The analytic model under test

In-flash computing assumption (my paper):

- Each **plane** has its own computing unit.
- Computation is **fully hidden** behind the next page read via **double buffering**, using
  the **cache register** already present in the NAND page buffer.
- Therefore the latency of one "read-a-page-and-compute" round, performed across **all
  planes in parallel**, is:

  ```
  t_round = tR + t_cmd
          = 30 us  + 8 us
          = 38 us
  ```

  where `tR = 30 us` is the NAND sensing time and `t_cmd = 8 us` is the **command transfer
  time for all planes in one channel** (channels operate in parallel, so this is a
  per-round constant, not per-plane). Note: because this is *compute*, the full page data
  is **not** shipped to the host over the channel/PCIe — only the (tiny) computed result
  and the command overhead cross the channel. This is why the per-round cost is `38 us`
  and not `tR + full-page-transfer-time`.

- All planes in all channels run concurrently. With `P` page-read+compute rounds per plane:

  ```
  T_model(end-to-end) = t_round * P = 38 us * P
  ```

  Example given: `512 planes` (16 ch x 8 die x 4 plane), each plane reads+computes
  `10 pages` => `5120 pages` total => `T_model = 38 us * 10 = 380 us`, independent of the
  number of planes as long as all planes are saturated in parallel.

### 1.2 What NVMeVirt adds that the model omits

The analytic model ignores **firmware latency** and **command / request management
overhead** required to activate all planes. The whole reason for using NVMeVirt (instead of
a spreadsheet) is to capture those costs. The hypothesis is:

- At **high request counts** (all planes saturated, overhead amortized), NVMeVirt's
  end-to-end latency should **converge** to `T_model`.
- At **low request counts** (planes under-utilized, per-request firmware/queueing overhead
  dominant), NVMeVirt should **diverge** from `T_model`.

The experiment must **quantify this divergence as the number of requests varies**, and the
report must explain the accuracy curve.

### 1.3 Target SSD configuration

| Parameter            | Value                            |
|----------------------|----------------------------------|
| `tR` (NAND read)     | 30 us (30000 ns)                 |
| Channels             | 16                               |
| Dies (LUNs) / channel| 8                                |
| Planes / die         | 4                                |
| **Total planes**     | **16 x 8 x 4 = 512**             |
| Command transfer     | 8 us per channel per round       |

> **Emulation mapping (chosen — see §2.1 / Task A): map each physical plane to a NVMeVirt
> LUN.** NVMeVirt models parallelism only at the LUN level, so the 512 physical planes are
> emulated as `16 channels x 32 LUNs/channel x 1 plane/LUN = 512 LUNs`. This gives each
> "plane" an independent timeline with **no timing-model code changes**.

---

## 2. Required reading of NVMeVirt internals (already analyzed — confirm before coding)

These are the facts that make or break the implementation. **Verify each still holds** in
the current tree before changing code.

### 2.1 Timing is serialized at the DIE (LUN) level, NOT the plane level

- `ssd_advance_nand()` in [ssd.c:362](ssd.c#L362) is the single timing primitive. For
  `NAND_READ` ([ssd.c:390-418](ssd.c#L390-L418)) it computes:
  ```
  nand_stime = max(lun->next_lun_avail_time, cmd_stime);   // serialize on the DIE
  nand_etime = nand_stime + pg_rd_lat[cell];               // tR
  ... channel transfer of xfer_size ...
  lun->next_lun_avail_time = chnl_etime;                    // DIE busy through ch xfer
  ```
- **`struct nand_plane.next_pln_avail_time`** exists ([ssd.h:102](ssd.h#L102)) but is
  **never read or written anywhere** in the codebase (confirmed by grep). **Plane-level
  parallelism is not modeled.** Two reads to different planes of the *same die* will
  **serialize** on `next_lun_avail_time`.
- `PLNS_PER_LUN` is **1** in every profile ([ssd_config.h:76,125,191](ssd_config.h#L76)),
  and the conv FTL **hard-asserts `pl == 0`** ([conv_ftl.c:277](conv_ftl.c#L277),
  [conv_ftl.c:295](conv_ftl.c#L295)); the write pointer never advances the plane.

> **Implication & chosen workaround — "LUN-as-plane":** Setting `PLNS_PER_LUN=4` and issuing
> 4 separate reads to a die would serialize them to `4 x tR` (planes are not parallel in the
> model). Modifying the timing model to add a multi-plane command is one option (see Task B,
> kept only as an alternative), but the **simpler and equally faithful approach — chosen for
> this experiment — is to map each physical plane to a NVMeVirt LUN**:
> `LUNS_PER_NAND_CH = 32` (= 8 dies x 4 planes), `PLNS_PER_LUN = 1`, giving `16 x 32 = 512`
> independent LUNs. Each LUN has its own `next_lun_avail_time`, so all 512 "planes" run in
> parallel and each pays exactly one `tR` per round — **with no change to `ssd_advance_nand()`
> and no plane-addressing code** (the `pl == 0` asserts stay valid; `advance_write_pointer()`
> already stripes LPNs across `ch -> lun`). This is consistent with the analytic model, which
> already treats every plane as an independent compute unit. The only thing to calibrate is
> the per-channel 8 us command cost (see §5), since the 32 LUNs in a channel still share one
> channel timeline.

### 2.2 The normal read path transfers full page data over the channel

- `conv_read()` [conv_ftl.c:833](conv_ftl.c#L833) maps LPNs -> PPAs via `maptbl`,
  aggregates reads within the same flash page, and calls `ssd_advance_nand()` with
  `xfer_size = pgsz * (#pages)` and `interleave_pci_dma = true`.
- For **in-flash compute**, the per-page data must **not** be transferred to the host. The
  channel cost per round should be the **command/result overhead (~8 us per channel)**, not
  `pages * 4KB / channel_bandwidth`. See Task C.

### 2.3 Channel model

- `chmodel_request()` [channel_model.c:31](channel_model.c#L31), credit-based, with
  `UNIT_XFER_SIZE=128B`, `UNIT_TIME_INTERVAL=4000ns`
  ([channel_model.h](channel_model.h)). `xfer_lat = BANDWIDTH_TO_TX_TIME(bandwidth)`.
  Per-channel firmware overhead is added in `ssd_init_ch()` [ssd.c:269](ssd.c#L269) via
  `fw_ch_xfer_lat`.
- With **LUN-as-plane**, the 32 LUNs sharing one channel serialize their channel transfers
  in `chmodel_request()`. The `8 us` per-channel command cost is therefore the **sum of the
  32 per-LUN command/result transfers** (≈ 250 ns each), realized by calibrating
  `fw_ch_xfer_lat` / the tiny result `xfer_size`. See §5. (This serialization is exactly why
  the model phrases it as "command transfer for *all* planes in a channel.")

### 2.4 How the latency leaves the simulator

- Each FTL handler sets `ret->nsecs_target` (e.g. [conv_ftl.c:920](conv_ftl.c#L920)). This
  is the completion timestamp the device reports; the difference from `req->nsecs_start` is
  the emulated end-to-end device latency. The SPDK host additionally measures wall-clock
  submit->complete latency. Both are recorded (§4.3).

### 2.5 Methodology precedent from `CIKM25_InstANNS.pdf` (reference only)

The paper (Implementation §5, Evaluation §6.1) establishes the pattern to reuse:

- They added a **custom NVMe command** to NVMeVirt by **repurposing the NVMe Dataset
  Management (DSM) command format** (originally TRIM), encoding the compute parameters in
  command Dwords; they "logically fuse" paired commands via Dwords 10-12.
- They drove it from **SPDK** (user-space, polling-based submission) **without modifying the
  OS kernel or storage drivers**.
- They **bound the NVMeVirt emulator thread, the SPDK polling thread, and the
  query/processing thread to separate physical CPU cores** to avoid contention corrupting
  timing.
- They **calibrated** NVMeVirt's PCIe/channel timing against `fio` on a real Gen4 SSD
  (~7000 MB/s seq, ~1050 KIOPS 4KB random) and profiled real SoC operation times.

We imitate the **mechanism** (custom compute command + SPDK + core isolation +
calibration), not the ANNS algorithm.

---

## 3. Implementation tasks

Implement in this order. Keep authoring and verification as separate passes.

### Task A — New SSD configuration profile

1. In [ssd_config.h](ssd_config.h) add a new `BASE_SSD` profile (e.g. `INFLASH_PIM`) using
   the **LUN-as-plane** mapping:
   - `NAND_CHANNELS = 16`, **`LUNS_PER_NAND_CH = 32`** (= 8 physical dies x 4 planes),
     **`PLNS_PER_LUN = 1`**. Total emulated parallel units = `16 x 32 = 512`.
   - `NAND_READ_LATENCY_* = 30000` (30 us) and a matching `NAND_4KB_READ_LATENCY_*`
     (decide whether compute reads a full flash page or 4KB; default: full page => use
     `pg_rd_lat`).
   - `NS_SSD_TYPE_0 = SSD_TYPE_CONV` (build on the conventional FTL).
   - `SSD_PARTITIONS = 1` (simplest reasoning about the 512 LUNs; avoids splitting the 16
     channels across FTL instances — partitioning divides `nchs`,
     [ssd.c:82-84](ssd.c#L82-L84)).
   - A capacity large enough that 512 LUNs x (rounds) pages exist, but small enough to fit
     the reserved memmap region (see §6 prerequisites).
   - **No FTL or `ssd_advance_nand()` change is required** for parallelism — each of the 512
     LUNs already gets an independent `next_lun_avail_time`, and `PLNS_PER_LUN = 1` keeps the
     conv FTL's `pl == 0` invariant valid.
2. Select it in [Kbuild](Kbuild). Confirm `ssd_init_params()` prints the expected geometry
   (`tt_luns == 512`, `tt_pls == 512`) in `dmesg`.

### Task B — Plane parallelism (handled by config; no code change)

**With the LUN-as-plane mapping from Task A, plane parallelism requires no timing-model
change.** Each of the 512 LUNs already has an independent `next_lun_avail_time`, so requests
to different LUNs overlap their `tR`, and `ssd_advance_nand()` is left untouched. Skip the
multi-plane work below unless you later decide LUN-as-plane is insufficient.

**Validation:** a microtest issuing one request to each of the 512 LUNs at the same arrival
time must report ~`tR + 8us` (~38 us) end-to-end, NOT `~4 x tR` and NOT `~512 x tR`. Two
requests to the *same* LUN must serialize to ~`2 x tR` (sanity check that the timeline works).

#### Alternative (only if you abandon LUN-as-plane): true multi-plane command

Keep the *physical* geometry (`LUNS_PER_NAND_CH = 8`, `PLNS_PER_LUN = 4`) and add a
multi-plane NAND command in `ssd_advance_nand()` [ssd.c:362](ssd.c#L362): one die activation
reads `pls_per_lun` pages charged a **single `tR`**, channel charge = command/result overhead
(not `pls_per_lun * pgsz`), and (optionally) wire up the currently-unused
`struct nand_plane.next_pln_avail_time` ([ssd.h:102](ssd.h#L102)). This is more faithful to
real multi-plane hardware but more invasive, and it also requires the plane-addressing changes
that LUN-as-plane avoids (relaxing the `pl == 0` asserts, advancing the plane in
`advance_write_pointer()`/`get_new_page()`). Not needed for this experiment.

### Task C — In-flash compute request path

**DECISION (chosen for this experiment): use C1 — reuse the read opcode with a compute
flag.** C2 is documented below only as a possible later fidelity upgrade; do not start with
it.

- **C1 (CHOSEN): reuse the read opcode with a "compute" flag/marker.**
  Add a compute path parallel to `conv_read()` [conv_ftl.c:833](conv_ftl.c#L833) that:
  1. Takes a request describing which page(s) to read+compute (see "request shape" below).
  2. Uses the existing FTL mapping (`maptbl`, `get_maptbl_ent`) unchanged. Because Task A
     uses LUN-as-plane and `advance_write_pointer()` already stripes LPNs round-robin across
     `ch -> lun` ([conv_ftl.c:215-281](conv_ftl.c#L215-L281)), consecutive LPNs naturally
     spread over all 512 LUNs — **no plane-addressing changes and no `maptbl` bypass needed.**
     The host (Task D) just has to pick LPNs that cover the LUNs it wants active.
  3. Issues an ordinary `NAND_READ` per targeted LUN but **omits the host page-data
     transfer**: set `interleave_pci_dma = false` and a **tiny result `xfer_size`** (the
     computed result, not 4 KB) so the channel only models the ~8 us/channel command cost,
     not full-page transfer. This is the *only* behavioral change vs `conv_read()`.
  4. Sets `ret->nsecs_target` to the max completion time across all LUNs touched.
- **C2 (higher fidelity, matches the paper): custom NVMe command via DSM repurposing.**
  Define a new admin/io command (repurpose DSM like the paper, Table 1) carrying
  `(#rounds P, plane mask / page list, result buffer)`. Route it in
  `conv_proc_nvme_io_cmd()` [conv_ftl.c:1046](conv_ftl.c#L1046) (and the dispatch in
  [io.c](io.c) / [nvme.h](nvme.h) opcode handling). Use this if you want the SPDK side to
  look exactly like the paper's IPQF command.

**Request shape (DECIDED): `1 request = 1 page read+compute on exactly 1 plane`** — and under
LUN-as-plane, "1 plane" == "1 LUN".
- One NVMe request targets a single 4KB/flash page that maps (via its LPN) to one specific
  `(channel, LUN)` = one emulated plane. Keep this fixed across all runs.
- The host (Task D) must choose LPNs so that, given `N` outstanding requests, they spread as
  evenly as possible across the 512 LUNs (round-robin over `ch -> lun`). Two requests hitting
  the **same LUN** serialize on `next_lun_avail_time`; requests on **different LUNs** run in
  parallel — this is exactly the firmware/parallelism effect the experiment is meant to
  expose.
- With this mapping, `N` requests = `N` pages; the number of parallel "rounds" needed when
  perfectly balanced is `ceil(N / 512)`. The sweep in §4 varies `N` (the **number of
  requests**).

### Task D — SPDK host application

Build an SPDK app (model it on `spdk/examples/nvme/perf` or `hello_world`) that:

1. Attaches to the NVMeVirt device via SPDK (user-space NVMe driver, polling completions).
2. Pre-populates / lays out data so that the addressed pages cover all 512 planes (write
   phase, or rely on the direct-addressing compute path).
3. Issues `N` in-flash-compute requests (the C1 flag or C2 custom command), with a
   configurable **queue depth** and **total request count**.
4. Measures latency two ways: (i) SPDK wall-clock submit->complete per request and
   aggregate end-to-end for the batch; (ii) reads back NVMeVirt's reported `nsecs_target`
   delta if exposed (e.g. via dmesg/debugfs/an instrumented counter).
5. **Core isolation:** pin the SPDK polling thread, and ensure NVMeVirt's dispatcher/IO
   worker `cpus=` ([README.md](README.md) insmod args) and `isolcpus` are on **different**
   physical cores than the SPDK app. This is mandatory for trustworthy timing (paper §6.1).

### Task E — Measurement & calibration harness

- Add a calibration step (paper §6.1): run a plain SPDK read workload and confirm NVMeVirt's
  channel/PCIe timing is sane before trusting compute-path numbers.
- Emit machine-readable results (CSV/JSON): per run record `#requests`, `queue_depth`,
  `#planes_utilized`, `#pages`, `T_model`, `T_nvmevirt_endtoend`, `T_nvmevirt_device`,
  `abs_error`, `rel_error`.

---

## 4. Experiment design

### 4.1 Independent variable

**Number of requests** issued (primary). Secondary knobs to hold fixed per sweep (and
optionally sweep separately): queue depth, pages-per-request, rounds `P`, plane-coverage
per request.

Suggested sweep: e.g. `#requests ∈ {1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, ...}`
chosen so the low end leaves planes idle and the high end saturates all 512 planes and
amortizes firmware overhead.

### 4.2 For each point, compute both sides

- With the decided mapping (`1 request = 1 page = 1 plane`), the model end-to-end for `N`
  requests, assuming perfect balancing across 512 planes:
  ```
  T_model(N) = 38 us * ceil(N / 512)
  ```
  i.e. `T_model = 38 us` for any `N <= 512`, then steps up by 38 us per additional full
  sweep. (Keep the original `38 us * P` framing for the saturated case `N = 512 * P`.)
- `T_nvmevirt` = measured end-to-end latency (and device latency).

### 4.3 Metrics

- Absolute error `|T_nvmevirt - T_model|` and relative error `(T_nvmevirt - T_model)/T_model`.
- Report median + tail (p50/p99) over repeated trials per point.
- Plot **relative error vs. number of requests** — the central result.

### 4.4 Hypotheses to confirm/refute

1. Error is large/positive at small #requests (firmware + queueing overhead dominates).
2. Error shrinks and stabilizes as #requests grows and planes saturate.
3. The asymptotic per-round latency approaches ~38 us.

---

## 5. Calibration notes for the 38 us target

- `tR` is set directly via `NAND_READ_LATENCY_*` = 30000 ns. Each LUN op = one `tR`, and all
  512 LUNs overlap when issued together (LUN-as-plane) — no per-die multi-plane logic needed.
- The `8 us` per-channel command transfer is the **aggregate of the 32 per-LUN command/result
  transfers that serialize on each channel** (32 LUNs/channel x ~250 ns ≈ 8 us). Produce it
  by calibrating `fw_ch_xfer_lat` ([ssd.c:269](ssd.c#L269)) and/or the tiny result `xfer_size`
  fed to `chmodel_request()`. Document the exact values chosen.
- Verify with the Task B microtest that one saturated round (one request per LUN) =
  ~38 us, and that the per-channel transfer scales with the number of active LUNs in that
  channel (so a half-full channel costs < 8 us).

---

## 6. Prerequisites & environment constraints (READ BEFORE RUNNING)

- **memmap region:** The server is **currently free** — no other user's NVMeVirt instance is
  running — so you may **reserve and (re)load a fresh `memmap` region** for this experiment.
  Pick a `memmap=SIZE$OFFSET` reservation that fits the chosen SSD capacity (Task A) within
  available physical RAM, set it in GRUB (`update-grub` + reboot) or confirm an existing
  reservation, then `insmod` NVMeVirt against it. `reload.sh` / re-`insmod` is now safe to
  use. Before reloading, still do a quick `lsmod | grep nvmev` / `dmesg` check to confirm no
  active instance you'd clobber.
- **Per-user-action notification:** For any action only the user can perform (e.g.
  `sudo -v`, `insmod`/`rmmod`, reboot, editing GRUB, anything destructive), ping via
  `./notify.sh` (Slack) rather than silently blocking. (See memory "Slack-notify for user
  actions".)
- Kernel headers for the running kernel; recommended Linux v5.15.x (README §Installation).
- GRUB `memmap=...$...` reservation + `isolcpus` for the NVMeVirt cores; `intremap=off` if
  MSI-X panics (README §Using).
- SPDK installed and built; hugepages configured; device bound to SPDK's userspace driver
  (`setup.sh`). Keep SPDK cores disjoint from NVMeVirt cores.

---

## 7. Deliverable: the report

Produce `report.md` (+ figures/CSV) containing:

1. **Setup**: final SSD geometry, latency params, request->work mapping, SPDK config, core
   pinning, calibration evidence.
2. **Model recap**: the `38 us * P` formula and how `T_model` is computed per sweep point.
3. **Results table**: per #requests — `T_model`, `T_nvmevirt` (end-to-end + device), abs &
   rel error, p50/p99.
4. **Figures**: (a) latency vs #requests (model vs NVMeVirt overlaid); (b) relative error vs
   #requests.
5. **Analysis**: where/why the model and emulation agree or diverge; the role of firmware /
   command-management overhead that NVMeVirt exposes and the model omits; the request count
   at which the model becomes "accurate enough" (define a threshold, e.g. <10% rel error).
6. **Threats to validity**: core contention, memmap sharing, channel-model calibration, the
   **LUN-as-plane abstraction** (planes modeled as fully independent LUNs — no shared-die
   constraint and per-plane rather than per-die command overhead), and the assumption that
   compute results are small enough to ignore page-data transfer.
7. **Conclusion**: is the in-flash-computing analytic model consistent with NVMeVirt
   emulation, and under what request-count regime.

---

## 8. Acceptance criteria

- [ ] New LUN-as-plane profile (16 ch x 32 LUNs, tR=30us) builds and loads; `dmesg` confirms
      `tt_luns=512`.
- [ ] Compute path charges **one tR per LUN per round** with no full page-data transfer to
      host (microtest ≈ 38 us for one saturated round of 512 requests; ~2x tR for two
      requests to the same LUN).
- [ ] SPDK app issues in-flash-compute requests striped across all 512 LUNs and records
      latency, with NVMeVirt and SPDK on disjoint isolated cores.
- [ ] Sweep over #requests executed; CSV + plots produced.
- [ ] `report.md` compares analytic vs emulated latency and characterizes modeling accuracy
      vs #requests.
- [ ] `memmap` region reserved/loaded cleanly; `lsmod`/`dmesg` checked before each reload.

---

## 9. Key code references (current tree)

- Timing primitive: `ssd_advance_nand()` — [ssd.c:362](ssd.c#L362) (NAND_READ
  [ssd.c:390-418](ssd.c#L390-L418)).
- Unused plane timeline: [ssd.h:100-104](ssd.h#L100-L104) (`next_pln_avail_time`).
- Geometry / latency params: [ssd_config.h](ssd_config.h), `ssd_init_params()`
  [ssd.c:68](ssd.c#L68).
- Read path & FTL mapping: `conv_read()` [conv_ftl.c:833](conv_ftl.c#L833); page allocation
  `get_new_page()` / `advance_write_pointer()` [conv_ftl.c:215-298](conv_ftl.c#L215-L298)
  (note `pl==0` asserts).
- IO command dispatch: `conv_proc_nvme_io_cmd()` [conv_ftl.c:1046](conv_ftl.c#L1046),
  [io.c](io.c), [nvme.h](nvme.h).
- Channel model: [channel_model.c](channel_model.c), [channel_model.h](channel_model.h).
- Build target select: [Kbuild](Kbuild); load/run: [README.md](README.md).
- Methodology precedent (custom command + SPDK + isolation + calibration):
  `CIKM25_InstANNS.pdf` §5 Implementation, §6.1 Experimental Setup, Table 1.
