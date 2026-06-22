# Task Prompt: SPDK (kernel-bypass) host path for the NVMeVirt in-flash-compute command

> **Use this file as the task specification.** It is the follow-up to the Option-1 work recorded in
> `reports/report_nvmevirt_followup.md` §11. That section converged the *device-internal* all-plane
> latency to a verified ~34 µs and the *host end-to-end* (io_uring / `O_DIRECT`) to ~48 µs, leaving a
> **fixed ~14 µs O(1) host-stack overhead** (page pinning, `io_uring_enter` syscall, IRQ reaping). The
> goal here is to **replace the host I/O path with SPDK** (userspace NVMe driver, polled completion)
> and measure whether host e2e collapses onto the device floor — turning the report's claim that "the
> host overhead is separable and removable" from an argument into a measured curve. This file is
> self-contained: it restates the verified state, why SPDK matters, the **feasibility gate that must
> pass first**, the experiments in order, build/run mechanics, the model, deliverables, and a graceful
> fallback if SPDK cannot bind the emulated device.

---

## 0. One-paragraph summary

The faithful NVMeVirt leg already shows that a single-page `--compute` command makes the device sense
all 512 planes in a modeled **34,152 ns** (`tR 30 µs + ~4 µs emergent channel t_cmd`; proven from
dmesg `inflash_dev_lat 34152 ns (sensed 512 pages)`), while the **host** observes ~48 µs because the
Linux `O_DIRECT`/io_uring path adds a fixed ~14 µs of pin/PRP/syscall/IRQ work. That residual is
O(1) (independent of planes sensed — a command sensing 8× more planes than the 256 KB baseline costs
*less* host time, because it pins 1 page not 64). **SPDK removes that residual at the source**:
kernel bypass (pre-pinned hugepage DMA buffers, no `get_user_pages` per I/O), polled completion (no
IRQ → softirq → scheduler → context-switch chain), and no per-I/O syscall (doorbell + CQ are direct
userspace MMIO/memory ops). The expected outcome: **host e2e drops from ~48 µs to ~35 µs** (device
floor + a 1–3 µs poll/dispatch cost) with much tighter variance, and the device-observed 34 µs is
unchanged. **The single hard risk is whether SPDK can bind and enumerate NVMeVirt's *emulated* PCIe
device** — §3 makes that a gate with a defined fallback.

---

## 1. Verified state to build on (do not re-derive)

### 1.1 Machine & module
- **CPU**: i9-13900F, 32 logical (P-cores 0–15, E-cores 16–31). **RAM** ~94 GiB. **Reserved memmap**:
  use **`memmap_start=96G memmap_size=16G`** for NVMeVirt. NVMeVirt threads pinned `cpus=7,8`
  (1 dispatcher + 1 io_worker); host bench pinned to E-cores (`taskset -c 16-31`), disjoint from `cpus=`.
- **`INFLASH_PIM` profile is built, loads, and is the Option-1 build.** Geometry: 16 channels ×
  32 LUNs = **512 LUNs (planes)**, 4 KB page, `MDTS=6` (256 KB cap), device appears as
  **`/dev/nvme1n1`** under the kernel `nvme` driver. Module name `nvmev`.
- **Default knobs preserved** (do **not** retune): `COMPUTE_RESULT_SIZE=64`, `FW_CH_XFER_LATENCY=0`,
  `NAND_CHANNEL_BANDWIDTH=800 MB/s`, `NAND_READ_LATENCY_*=30000`, `CELL_MODE=SLC`.

### 1.2 The Option-1 command shape already in the tree (reuse, do not re-implement)
- `ssd_config.h`: `#define COMPUTE_SENSE_PAGES (512)` — on-device sensing extent, independent of NLB.
- `conv_ftl.c` (`conv_read`): under `INFLASH_COMPUTE`, a **single-page** read (`start_lpn==end_lpn`)
  expands `end_lpn`/`nr_lba` to sense `COMPUTE_SENSE_PAGES` consecutive LPNs (all-plane), while the
  host transfer (NLB) stays 1 page. Multi-page reads keep their natural range.
- Device observer prints `inflash_dev_lat <N> ns (sensed <M> pages)` (rate-limited) — this is how the
  modeled device latency and the sensed extent are read off, **separately from host wall-clock**.
- `io.c` (`__do_perform_io`): for compute reads, only `COMPUTE_RESULT_SIZE` (64 B) is copied to host.
- `host/inflash_bench.c`: `--compute` flag forces `reqsize=4096` (host pins **one** page); the
  in-flash-compute command shape. Built with liburing (`make -C host`).

### 1.3 Baseline numbers to beat / preserve (from `results_nvmevirt_compute_raw.csv`, report §11)
| shape | host pages pinned | planes sensed | host e2e (median) | device latency |
|---|---:|---:|---:|---:|
| OLD 256 KB command | 64 | 64 | ~74 µs | 30,152 ns |
| **NEW 1-page `--compute`** | **1** | **512** | **~48 µs** | **34,152 ns** |
| prior 2 MB (old all-plane shape) | 512 | 512 | 538 µs | 30,152 ns |

**The number SPDK must move:** host e2e for the 1-page `--compute` command, **~48 µs → ~35 µs**, with
the device-observed 34,152 ns unchanged and variance reduced (the io_uring run swung ~46→82→200 µs
cold/warm; SPDK polling should hold a tight band).

---

## 2. Why SPDK matters (what it tests that io_uring cannot)

This is the **host-path-elimination** leg. Make these the analysis spine of the report addition:

1. **It removes the residual O(1) host overhead at the source, not by argument.** The report §11
   *claims* the ~14 µs is removable; SPDK *removes* it. Map each removed cost explicitly:
   IRQ→softirq→wakeup→context-switch (gone: CQ busy-poll), `io_uring_enter` syscall (gone: userspace
   MMIO doorbell + CQ read), `get_user_pages` pin/unpin + PRP build per I/O (gone: pre-registered
   hugepage DMA buffers).
2. **It makes host e2e ≈ device-observed.** With the host term near-zero, the *end-to-end* number the
   host measures finally equals `tR + emergent t_cmd` (~34–35 µs), so the paper no longer asks the
   reviewer to mentally subtract host overhead — the e2e itself validates the assumption.
3. **It isolates "device model" from "host stack" as two measured points under one model.** Same
   NVMeVirt timing model (device-observed flat at 34,152 ns), two host stacks: io_uring → ~48 µs,
   SPDK → ~35 µs. That two-point curve is the clean validation figure (§8).
4. **What it does NOT change (state this):** the device-observed latency, the emergent `t_cmd`, the
   all-plane sensing semantics, and `COMPUTE_SENSE_PAGES`. SPDK is a *host-stack* change only.

---

## 3. FEASIBILITY GATE (Phase 0) — can SPDK bind NVMeVirt's emulated PCIe device?

**This is the one real risk and must be resolved before any benchmark work.** NVMeVirt registers a
*software-emulated* NVMe PCIe controller; the stock kernel `nvme` driver binds it today. SPDK instead
needs the device **unbound from `nvme` and bound to `vfio-pci` (preferred, needs IOMMU) or
`uio_pci_generic`**, then enumerated by `spdk_nvme_probe()`. Whether a software PCI device exposes a
config space + BAR + (for vfio) an IOMMU group that SPDK can claim is **unverified** — settle it
empirically first.

**Phase 0 steps (no benchmark code yet):**
1. Find NVMeVirt's PCI BDF: `lspci -d ::0108` / `lspci | grep -i non-volatile`, and confirm it maps to
   `/dev/nvme1n1` (`ls -l /sys/block/nvme1n1/device` → BDF). Record it.
2. Check IOMMU: `dmesg | grep -iE 'DMAR|IOMMU'`; `ls /sys/kernel/iommu_groups/`. If IOMMU is off,
   note that vfio needs `intel_iommu=on iommu=pt` (a **GRUB + reboot = user action**) or that SPDK
   must fall back to `uio_pci_generic` with `iommu=off` (which needs physical-address DMA — may be
   incompatible with how NVMeVirt resolves PRP addresses; test it).
3. Install SPDK (build from source or distro pkg). Run `spdk/scripts/setup.sh status`, then attempt
   `PCI_ALLOWED="<BDF>" spdk/scripts/setup.sh` to bind the NVMeVirt BDF to vfio/uio. Capture whether
   the bind succeeds, what driver it lands on, and any dmesg errors.
4. Smoke test enumeration: run SPDK's `examples/nvme/identify` (or `hello_world`) against the BDF.
   **Gate pass = `identify`/`hello_world` enumerates the NVMeVirt controller and reads/writes a page.**
5. **Record the verdict explicitly in the report.** If it passes → proceed to §4. If it fails →
   document the exact failure (config-space/BAR/IOMMU-group/DMA-address) and switch to the **fallback
   in §6**, which still tests IRQ/syscall removal without leaving the kernel.

> Do not silently degrade. If the gate fails, say so loudly and run the fallback; a negative result
> ("SPDK cannot drive the emulated device because X") is itself a reportable finding.

---

## 4. Experiment S1 (primary): SPDK compute-command benchmark

**Hypothesis**: issuing the 1-page in-flash-compute read through SPDK (pre-pinned DMA buffer + polled
completion) drops host e2e from ~48 µs to ~35 µs (≈ device-observed 34 µs + 1–3 µs poll/dispatch),
with tight variance, while the device-observed latency stays 34,152 ns and dmesg still shows
`sensed 512 pages`.

### 4.1 Port the compute benchmark to SPDK — `host/inflash_bench_spdk.c`
Mirror the **measurement semantics** of `host/inflash_bench.c` (same e2e/p50/p99 CSV schema:
`requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns`) but over SPDK:
- Init: `spdk_env_init()` (hugepages, core mask on E-cores), `spdk_nvme_probe()`/`attach` the BDF,
  open the namespace (`spdk_nvme_ns` for nsid 1), create an I/O qpair
  (`spdk_nvme_ctrlr_alloc_io_qpair`).
- Buffers: allocate DMA-able buffers with `spdk_zmalloc`/`spdk_dma_zmalloc` (one 4 KB page each,
  pre-registered — this is what removes per-I/O pinning).
- **Compute command shape**: issue a **single-page** read — `spdk_nvme_ns_cmd_read(ns, qpair, buf,
  lba=lpn*secs_per_pg, lba_count=secs_per_pg /* = 8 sectors = 1 page */, cb, cb_arg, 0)`. The
  single-page read triggers the device-side all-plane expansion (§1.2); **no NVMe command-field change
  is needed** because the sensing extent is device-side (`COMPUTE_SENSE_PAGES`). Keep `lba_count` at
  exactly one page so NLB stays 1 (O(1) DMA).
- Completion: **busy-poll** `spdk_nvme_qpair_process_completions(qpair, 0)` in a tight loop; stamp
  submit time before `_cmd_read` and completion time in the callback. e2e = first submit → last
  completion, per the existing bench.
- Parameters to match the io_uring bench: `--requests N --qdepth Q --trials T --compute` semantics.
  qdepth = number of outstanding single-page reads before polling. Prepopulation: SPDK can prepopulate
  with `spdk_nvme_ns_cmd_write` of 4 KB pages over LPN `[0, maxpages)`, OR reuse the kernel path once
  (load under `nvme`, prepopulate with `host/inflash_bench --prepopulate`, then rebind to SPDK) —
  whichever is simpler; **prepopulation is mandatory** (report §2.1: cold LPNs read instantly and
  fabricate false convergence).
- CPU pinning: SPDK core mask on E-cores (e.g. `-m 0xFFFF0000` or `--cpu` equivalent), disjoint from
  NVMeVirt `cpus=7,8`.

### 4.2 Runs (default knobs, MDTS=6, Option-1 build)
1. **S1a — single compute command**: `--requests 1 --qdepth 1 --trials 15`. Headline: host e2e vs the
   io_uring ~48 µs and the device 34 µs. Verify dmesg `inflash_dev_lat 34152 ns (sensed 512 pages)`.
2. **S1b — pipelined compute commands**: `--requests 8 --qdepth 8 --trials 15` (compare to io_uring
   E3b ~52 µs). Expect lower and tighter under polling.
3. **S1c — sequential**: `--requests 8 --qdepth 1 --trials 15` (compare to io_uring E3a ~337 µs;
   per-op p50).
4. **Variance**: report median **and** p99 / min–max spread for S1a vs the io_uring S1a, to show the
   jitter reduction (the cold 200 µs outliers should vanish).

### 4.3 Acceptance (S1)
- dmesg proves the SPDK single-page read still senses **512 pages** at **34,152 ns** (device model
  untouched).
- Host e2e (S1a) is **below ~40 µs median** and within a few µs of the device floor (≈ 34 µs), i.e.
  the ~14 µs io_uring residual is largely eliminated; quantify the SPDK residual (`e2e − 34,152 ns`).
- Variance (p99 − p50, and min–max) is materially tighter than the io_uring run.
- The host residual remains **O(1)**: it does not grow vs the 256 KB / multi-page cases (sanity:
  optionally issue a multi-page SPDK read and confirm host cost still tracks pages, but the headline
  is the 1-page command).

---

## 5. Experiment S2 (analysis): decompose what SPDK removed

Quantify the three removed costs so the report can attribute the ~14 µs → ~1–3 µs drop:
1. **IRQ/scheduler removal** — the dominant term. Compare SPDK polled vs io_uring **with**
   `IORING_SETUP_IOPOLL` (if the NVMeVirt SQ supports polled queues) or vs io_uring default. The
   delta isolates interrupt+context-switch cost.
2. **Syscall removal** — note SPDK issues zero syscalls on the hot path; io_uring issues
   `io_uring_enter` per submit/reap (or amortized with SQPOLL). Mention SQPOLL as the closest
   in-kernel analog.
3. **Pinning removal** — SPDK buffers are pre-registered; io_uring `O_DIRECT` pins per I/O. This term
   is small for a 1-page request (that is the whole point of Option-1) but grows for multi-page; show
   it is ~0 at 1 page.

Report each as a measured or clearly-reasoned contribution; do not over-claim a precise split if the
measurement can only bound it.

---

## 6. FALLBACK (if the §3 gate fails): in-kernel polling, no SPDK

If SPDK cannot bind/enumerate the emulated device, **do not abandon the result** — test the
IRQ/syscall-removal hypothesis without leaving the kernel:
1. **io_uring polled completion**: open with the polled-queue path and `IORING_SETUP_IOPOLL`; the
   reaper busy-polls instead of waiting on IRQs. Requires NVMeVirt to expose a poll queue — verify
   (`/sys/block/nvme1n1/queue/io_poll`, `nvme1n1` poll-queue count). If supported, this removes the
   IRQ + much of the wakeup cost and should land between io_uring-default and SPDK.
2. **io_uring SQPOLL**: kernel submission-poll thread removes `io_uring_enter` from the hot path
   (isolates syscall cost).
3. **Hybrid/adaptive polling** (`/sys/block/nvme1n1/queue/io_poll_delay`).
Report whichever subset is feasible and frame it as "the removable host overhead, partially removed
in-kernel" — a weaker but still valid version of the SPDK result, plus an explicit note that full
kernel-bypass was blocked by the emulated-device/VFIO limitation (with the §3 failure detail).

---

## 7. Build / run mechanics (this machine)

```bash
cd /home/juchanlee/nvmevirt_pim

# (A) Build NVMeVirt (Option-1 build, default knobs) and the kernel-path bench:
bash scripts/build.sh
make -C host

# (B) Phase 0 feasibility — find BDF, check IOMMU, install + bind SPDK, smoke test:
lspci | grep -i non-volatile ; ls -l /sys/block/nvme1n1/device      # → PCI BDF
dmesg | grep -iE 'DMAR|IOMMU' ; ls /sys/kernel/iommu_groups/ 2>/dev/null
# (load NVMeVirt under the kernel driver first if not loaded)
sudo bash scripts/load.sh                                           # cpus=7,8, memmap 96G/16G
sudo PCI_ALLOWED="<BDF>" <spdk>/scripts/setup.sh                    # bind to vfio-pci/uio
sudo <spdk>/build/examples/identify -r "trtype:PCIe traddr:<BDF>"  # GATE: must enumerate

# (C) S1 — SPDK compute benchmark (after gate passes), E-core mask, prepopulate first:
sudo <build>/inflash_bench_spdk --bdf <BDF> --compute \
     --requests 1 --qdepth 1 --trials 15 --csv results_nvmevirt_spdk_raw.csv
# device model read-back (separate terminal / after):
sudo dmesg -C ; <run> ; dmesg | grep inflash_dev_lat               # expect 34152 ns, sensed 512 pages

# (D) Restore the kernel driver when done (so /dev/nvme1n1 and the io_uring bench work again):
sudo <spdk>/scripts/setup.sh reset
```

Constraints (same as the prior legs):
- **Keep authoring and verification as separate passes.** Do not run `sudo` from non-interactive
  contexts without a fresh `sudo -v` (passwordless only inside that window). Surface user-only actions
  (GRUB `intel_iommu=on` + reboot for VFIO, vfio/hugepage setup, insmod/rmmod) explicitly.
- **Hugepages**: SPDK needs them reserved (`setup.sh` allocates; or
  `echo N > /proc/sys/vm/nr_hugepages`). Document the count used.
- **The device-latency observer is the source of truth for the device model** — always read it via
  dmesg and report it separately from host e2e; never let host overhead contaminate the device number.
- Binding to VFIO removes `/dev/nvme1n1`; the io_uring bench cannot run while SPDK owns the device.
  Run the two host stacks in separate phases and `setup.sh reset` between them.

---

## 8. Model & comparison

- **No new device model.** The convergence target is the **measured device-observed latency**
  (34,152 ns = tR 30 µs + ~4 µs emergent `t_cmd`), identical across host stacks. The host term is
  `host_e2e − device_observed`.
- **Two-point host-stack curve** (the validation figure): for the 1-page `--compute` command,
  `host_e2e` under {io_uring/`O_DIRECT` ≈ 48 µs, SPDK ≈ 35 µs} over a flat device floor of 34 µs.
  Annotate the removed components (IRQ/syscall/pin).
- Reuse the existing CSV schema and enrichment so SPDK rows sit alongside io_uring rows
  (`results_nvmevirt_spdk_raw.csv` + the compute CSV from §11). Add a `host_stack` column
  (`io_uring` | `spdk` | `io_uring_iopoll`) if helpful.

---

## 9. Deliverables

1. **Phase 0 verdict** (in the report): does SPDK bind/enumerate the emulated NVMeVirt device? Exact
   evidence (`identify`/`hello_world` output or the failure mode). This gate result is itself a
   deliverable.
2. **Code**: `host/inflash_bench_spdk.c` (+ `host/Makefile` target `spdk:` linking
   `-lspdk_nvme -lspdk_env_dpdk …` or via SPDK's `pkg-config`/`mk` includes). **No changes** to
   `conv_read`'s compute path, `COMPUTE_SENSE_PAGES`, or the device knobs. If the §3 gate fails, the
   fallback (§6) `IORING_SETUP_IOPOLL`/SQPOLL variant of the existing bench instead.
3. **Harness**: a `RUN=1`-guarded `scripts/nvmevirt_spdk_exp.sh` (bind → prepopulate → S1a/b/c →
   dmesg read-back → `setup.sh reset`), host core mask disjoint from `cpus=`.
4. **Data + figures**: `results_nvmevirt_spdk_raw.csv`; a figure overlaying host e2e for the 1-page
   compute command under io_uring vs SPDK (vs the 34 µs device floor), and a variance plot
   (p50/p99/min–max) showing the jitter collapse.
5. **Report**: extend `reports/report_nvmevirt_followup.md` with **§12 — "Experiment S: SPDK host
   path"** covering the feasibility gate verdict, the measured e2e drop and its decomposition, the
   unchanged device-observed latency (proof: `sensed 512 pages` under SPDK), the variance reduction,
   and the explicit reviewer-facing conclusion: *with the host stack bypassed, end-to-end latency
   itself (not just the device-internal number) matches the `tR + control` assumption, because the
   ~14 µs io_uring residual was an artifact of the commodity host path and is removable.* Update the
   §0 TL;DR with a one-line pointer.

---

## 10. Acceptance criteria
- [ ] **Phase 0 gate resolved and documented** — SPDK either drives the emulated device (with
      `identify`/`hello_world` evidence) or is shown not to, with the precise blocking reason and the
      §6 fallback engaged.
- [ ] If gate passes: SPDK 1-page `--compute` command yields **dmesg `inflash_dev_lat 34152 ns
      (sensed 512 pages)`** (device model untouched) and **host e2e ≤ ~40 µs median** (down from
      ~48 µs), within a few µs of the 34 µs floor; SPDK residual quantified.
- [ ] Variance (p99−p50 and min–max) for the SPDK run is materially tighter than the io_uring run
      (cold ~200 µs outliers eliminated).
- [ ] The ~14 µs → ~1–3 µs reduction is attributed across IRQ/syscall/pin removal (measured or
      clearly bounded, §5).
- [ ] CSV (shared schema, `host_stack` column) + overlay/variance figures produced; io_uring and SPDK
      rows for the 1-page command sit side by side over the flat 34 µs device floor.
- [ ] `reports/report_nvmevirt_followup.md` §12 added with an honest verdict and the reviewer-facing
      "host overhead is removable, e2e now matches the assumption" conclusion; device-vs-host
      separation preserved throughout. Kernel driver restored (`setup.sh reset`) at the end.

---

## 11. Key references
- Option-1 implementation + numbers: `reports/report_nvmevirt_followup.md` §11;
  `results_nvmevirt_compute_raw.csv`; `scripts/run_compute_exp.sh`.
- Compute command shape (device-side sensing extent): `ssd_config.h` (`COMPUTE_SENSE_PAGES`),
  `conv_ftl.c` `conv_read` (`start_lpn==end_lpn` expansion + `inflash_dev_lat … (sensed N pages)`
  observer), `io.c` `__do_perform_io` (64 B compute copy).
- Kernel-path bench (mirror its measurement semantics): `host/inflash_bench.c` (`--compute`,
  e2e/p50/p99 CSV), `host/Makefile`.
- Build/load: `scripts/build.sh`, `scripts/load.sh`.
- SPDK APIs: `spdk_env_init`, `spdk_nvme_probe`/`spdk_nvme_ctrlr_*`, `spdk_nvme_ns_cmd_read`/`_write`,
  `spdk_nvme_ctrlr_alloc_io_qpair`, `spdk_nvme_qpair_process_completions`, `spdk_dma_zmalloc`;
  `scripts/setup.sh` (vfio/uio bind, hugepages), `examples/nvme/identify`, `examples/nvme/hello_world`.
- Fallback (in-kernel polling): `IORING_SETUP_IOPOLL`, io_uring SQPOLL,
  `/sys/block/nvme1n1/queue/io_poll{,_delay}`.
- NVMeVirt PCIe emulation (for the VFIO feasibility question): `pci.c`, `main.c` (how the virtual NVMe
  controller / PCI config space + BARs are registered).
```
