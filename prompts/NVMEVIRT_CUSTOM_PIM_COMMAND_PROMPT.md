# Task Prompt: Vendor NVMe Page-List Command for NVMeVirt, Driven by SPDK

> Use this as the complete task specification. Start from a clean, stock NVMeVirt checkout
> (https://github.com/snu-csl/nvmevirt). Assume none of the previous trial code, reports, scripts,
> or local design history exists. Implement only the custom command below and verify the single
> required gate. Do not add read-path shortcuts, MDTS tricks, io_uring/fio comparisons, dispatcher
> scaling studies, figures, or broad sweeps unless they are needed to debug a failing gate.

---

## 0. Goal

Add one vendor-specific NVMe I/O command. The host submits a single command whose PRP data buffer
contains a list of page IDs (LPNs). NVMeVirt copies that page-id list from host memory, then expands
the one command inside the controller into one NAND read/sense per listed LPN, using the existing
`conv_ftl` mapping logic and `ssd_advance_nand()` timing model.

Configure the SSD as 16 channels x 32 LUNs/channel x 1 plane/LUN = 512 independent LUNs. With the
page list `0..511`, one command should activate all 512 LUNs/planes in one modeled round. The
acceptance gate is that NVMeVirt's device-observed latency for that single 512-page command
converges near the 30 us NAND read-latency level (allowing the small channel/model overhead), not
near 512 x 30 us. Drive the command from SPDK so the host can emit the vendor opcode directly.

---

## 1. Scope and Non-Goals

Implement:
- one 512-LUN conventional-SSD profile;
- one shared vendor I/O opcode;
- one `conv_ftl.c` handler that PRP-reads a `uint64_t` LPN list and fans out existing NAND timing;
- one minimal `io.c` custom-opcode branch so the io_worker does not perform normal read/write data
  movement for this command;
- one SPDK benchmark that submits the raw command and records host latency;
- one exact runbook or `RUN=1`-guarded script for build, load, prepopulate, SPDK bind, identify,
  gate run, `dmesg` capture, and driver restore.

Do not implement:
- automatic all-plane expansion on normal `nvme_cmd_read`;
- raising MDTS or testing large standard reads;
- alternate host stacks;
- ANNS/workload logic;
- required plots or parameter sweeps.

Small diagnostics are fine only to explain a failing gate or avoid a false pass; keep them out of
the required deliverables.

---

## 2. Target Machine and Runtime Setup

Machine:
- CPU: i9-13900F, 32 logical CPUs. Use P-cores for NVMeVirt kthreads and E-cores for SPDK.
- Reserved memory: user must boot with `memmap=16G$96G`; load NVMeVirt with
  `memmap_start=96G memmap_size=16G`.
- Surface GRUB/reboot and privileged commands as user actions; do not assume passwordless `sudo`.

Core placement:
- Example NVMeVirt load: `cpus=7,8` for one dispatcher and one io_worker.
- Example host pinning: `taskset -c 16-31`.
- The SPDK poller and NVMeVirt kthreads must not share a core.

Device path:
- Under the kernel `nvme` driver, expect `/dev/nvme1n1`; use this phase for prepopulation.
- SPDK binding removes `/dev/nvme1n1`; restore the kernel driver with SPDK reset after testing.

---

## 3. SSD Profile

Add a conventional-SSD (`conv_ftl`) profile in `ssd_config.h`.

Required constants:
- `SSD_PARTITIONS = 1`
- `NAND_CHANNELS = 16`
- `LUNS_PER_NAND_CH = 32`
- `PLNS_PER_LUN = 1`
- `FLASH_PAGE_SIZE = 4 KB`
- `CELL_MODE = CELL_MODE_SLC`
- all NAND read latency constants = `30000` ns
- `NAND_CHANNEL_BANDWIDTH = 800` MB/s
- `FW_CH_XFER_LATENCY = 0`
- `MDTS = 6` is fine; the custom command page count is not a normal NLB field.
- keep capacity inside the 16 GiB reserved memmap while leaving enough pages for at least LPNs
  `0..511` and ordinary metadata.

New task constants:
- `INFLASH_PIM_OPCODE = 0x91`
- `INFLASH_PIM_MAX_PAGES = 512`
- `COMPUTE_RESULT_SIZE = 64`

`COMPUTE_RESULT_SIZE` is the small per-page internal channel-transfer size charged in the NAND model.
It is not a host page-data transfer. Define the opcode in one shared header if practical; otherwise
duplicate it only with an explicit host/device value check. Do not scatter magic `0x91` literals.

---

## 4. Stock NVMeVirt Anchors to Read First

Read these in the clean tree and follow the local types exactly:
- `io.c`: `__nvmev_proc_io()` gets SQ entries and calls the namespace handler.
- `conv_ftl.c`: `conv_proc_nvme_io_cmd()` switches on `cmd->common.opcode`; add
  `case INFLASH_PIM_OPCODE:` and call `conv_inflash_compute()`.
- `conv_ftl.c`: mirror `conv_read()` for map lookup, unmapped/invalid-PPA skip, `struct nand_cmd`,
  `ssd_advance_nand()`, max completion time, and `ret->nsecs_target`.
- `io.c`: reuse the PRP walker idiom from `__do_perform_io()` (`cmd->prp1`/`prp2`,
  `kmap_atomic_pfn(PRP_PFN(paddr))` or `memremap()`, page offset, `memcpy`) to read the host LPN list.
- `nvme.h`: use the command union through `cmd->common`; read `cdw10[0]` with endian conversion,
  e.g. `le32_to_cpu(cmd->common.cdw10[0])`.

Do not assume the SPDK buffer has a kernel virtual address. The controller-side "DMA read" is a PRP
walk and host-physical copy inside NVMeVirt.

---

## 5. Custom Command Contract

Opcode:
- `INFLASH_PIM_OPCODE = 0x91`.
- Keep the opcode low bits as host-to-controller data transfer (`01b`), because the command's PRP
  buffer is an input page-id list.

Command dwords:
- `cdw10[0] = N`, the number of LPNs in the list.
- `cdw10[1] = 0` for now; reject nonzero flags unless you actually implement them.
- Do not overload `rw.slba`, `rw.length`, NLB, or MDTS for this command.

Data buffer:
- PRP1/PRP2 describe `N` contiguous little-endian `uint64_t` LPNs.
- For the required gate, `N = 512` and the list is exactly `0, 1, ..., 511`.
- Host transfer length is `N * sizeof(uint64_t)`; for `N <= 512` this is at most 4096 bytes. Use a
  4096-byte-aligned `spdk_zmalloc()` buffer so the 512-entry list is one page.

Completion:
- No host data result buffer is required. Put useful debug information in completion dwords, e.g.
  `result0 = sensed_pages` and `result1 = requested_pages`, if NVMeVirt's completion path supports it.
- Return success for a well-formed command after all valid listed pages are charged.
- Return an existing invalid-field/internal-error status for malformed `N`, bad PRPs, or out-of-range
  LPNs. Unmapped-but-in-range LPNs may be skipped like `conv_read()`, but the gate must not pass unless
  all 512 are sensed.

---

## 6. Device Implementation

Add `conv_inflash_compute(struct nvmev_ns *ns, struct nvmev_request *req, struct nvmev_result *ret)`
in `conv_ftl.c`.

Required behavior:
1. Read `N = le32_to_cpu(req->cmd->common.cdw10[0])`; reject `N == 0` or `N > INFLASH_PIM_MAX_PAGES`.
2. Copy `N * sizeof(u64)` bytes from the command PRPs into a bounded kernel array
   `u64 lpns[INFLASH_PIM_MAX_PAGES]`.
3. Validate each LPN against the FTL namespace range before use.
4. For each mapped, valid LPN, perform the same single-page timing operation `conv_read()` would:
   build `struct nand_cmd { .type = USER_IO, .cmd = NAND_READ, .stime = req->nsecs_start,
   .xfer_size = COMPUTE_RESULT_SIZE, .interleave_pci_dma = false, .ppa = &ppa }`, call
   `ssd_advance_nand()`, and keep the max completion time.
5. Track `requested = N` and `sensed = number of pages that actually called ssd_advance_nand()`.
6. Set `ret->nsecs_target` to the max completion time; if `sensed == 0`, complete at
   `req->nsecs_start` so the log clearly exposes a false prepopulation.
7. Set `ret->status = NVME_SC_SUCCESS` for success and completion result dwords if available.
8. Print the observer:

```c
printk_ratelimited(KERN_INFO
    "NVMeVirt: inflash_dev_lat %llu ns (requested %u pages, sensed %u pages)\n",
    ret->nsecs_target - req->nsecs_start, requested, sensed);
```

Critical timing rule: every listed page uses the same base `stime = req->nsecs_start`. Do not advance
`stime` in the loop. Distinct LUNs then overlap through the existing model; repeated pages on the same
LUN naturally serialize through that LUN's `next_lun_avail_time`.

Keep changes localized: opcode enum/string if needed, one dispatch case, one new handler. Do not
change `conv_read()`, `conv_write()`, or `ssd_advance_nand()` semantics.

---

## 7. io_worker Handling

Add a minimal custom-opcode branch in `io.c`'s data-copy path.

Required behavior:
- For `INFLASH_PIM_OPCODE`, do not derive offset or length from `struct nvme_rw_command`.
- Do not copy normal page data to or from the namespace backing store.
- Return zero copied bytes, or otherwise skip the io_worker data movement while still allowing the
  normal completion path to run at `ret->nsecs_target`.
- Preserve all standard read/write behavior.

If the clean tree can use both CPU-copy and DMA-copy io_worker paths, make sure the custom opcode
cannot accidentally enter a path that interprets `rw.length` and performs a fake read/write transfer.

---

## 8. SPDK Host Benchmark

Create `host/inflash_bench_spdk.c` and a small build target.

Required behavior:
- Initialize SPDK, probe only the selected BDF, open namespace 1, and allocate one I/O qpair.
- Allocate a 4096-byte-aligned DMA buffer with `spdk_zmalloc()` and fill `N` little-endian `uint64_t`
  LPNs.
- Submit a raw I/O command (`spdk_nvme_ctrlr_cmd_io_raw()` or the current SPDK equivalent):
  `opcode = INFLASH_PIM_OPCODE`, `nsid = 1`, `cdw10 = N`, buffer = LPN list, length =
  `N * sizeof(uint64_t)`.
- Busy-poll `spdk_nvme_qpair_process_completions()` until the callback fires.
- Record host e2e latency from just before submission to callback.

CLI:
- `--bdf <BDF>`
- `--npages N`
- `--qdepth Q` (only `Q=1` is required; reject other values if that keeps the benchmark simpler)
- `--trials T`
- `--csv <path>`
- optional `--core-mask`

CSV schema: `host_stack,n_pages,qdepth,trial,t_e2e_ns,status`.

For the gate, run `--npages 512 --qdepth 1 --trials 15` with page list `0..511`.

---

## 9. Prepopulation

Prepopulation is mandatory. Unmapped LPNs are skipped by the FTL and would fabricate a false near-zero
latency.

Before SPDK binding, while `/dev/nvme1n1` exists under the kernel driver, write at least LPNs `0..511`.
A simple direct write is sufficient, for example:

```bash
sudo dd if=/dev/zero of=/dev/nvme1n1 bs=4K count=512 oflag=direct status=none
```

The gate only passes if the device log says `requested 512 pages, sensed 512 pages`. Do not rely on
the custom command to create mappings.

---

## 10. SPDK Feasibility Check

Before benchmarking:
1. Find the BDF: `ls -l /sys/block/nvme1n1/device` or `lspci | grep -i non-volatile`.
2. Check SPDK setup status and bind only that BDF to userspace.
3. Prefer `uio_pci_generic`; NVMeVirt's software PCI device may lack an IOMMU group, so `vfio-pci`
   can fail even when the device is usable.
4. Run: `sudo spdk/build/examples/identify -r "trtype:PCIe traddr:<BDF>"`.

If identify cannot enumerate the controller, stop and report the exact failure. Record the hugepage
reservation used by SPDK. Run `sudo spdk/scripts/setup.sh reset` at the end to restore the kernel
driver.

---

## 11. Minimal Runbook

```bash
cd <clean-nvmevirt>
make
make -C host SPDK_DIR=<path-to-spdk>

sudo insmod nvmev.ko memmap_start=96G memmap_size=16G cpus=7,8
dmesg | tail -50 | grep -iE 'nvmev|tt_luns|luns'   # confirm 512 LUNs and /dev/nvme1n1
sudo dd if=/dev/zero of=/dev/nvme1n1 bs=4K count=512 oflag=direct status=none
BDF=<detected-BDF>

sudo DRIVER_OVERRIDE=uio_pci_generic PCI_ALLOWED="$BDF" spdk/scripts/setup.sh
sudo spdk/build/examples/identify -r "trtype:PCIe traddr:$BDF"

sudo dmesg -C
sudo taskset -c 16-31 host/inflash_bench_spdk --bdf "$BDF" \
  --npages 512 --qdepth 1 --trials 15 --csv results_pim_spdk.csv
dmesg | grep inflash_dev_lat

sudo spdk/scripts/setup.sh reset
```

---

## 12. Expected Timing

Source of truth: `dmesg` line
`inflash_dev_lat <ns> (requested 512 pages, sensed 512 pages)`.

All 512 listed LPNs use the same `req->nsecs_start`. Consecutive prepopulated LPNs `0..511` should
stripe across the 16 x 32 LUN geometry in the existing write-pointer order, one page per LUN. With
read latency set to 30000 ns and only 64 bytes of modeled internal result transfer per page, the
device latency should be close to the 30 us level plus a small additive channel/model cost. A result
around 30-40 us is plausible; a result near 15.36 ms is not.

Host SPDK latency is reported alongside, but the device-observed line is the pass/fail source.

---

## 13. Required Verification Gate

Run exactly:
- prepopulated LPNs: `0..511`
- command page list: `0..511`
- `N = 512`
- `qdepth = 1`
- `trials = 15`
- host path: SPDK raw command

Pass criteria:
- module builds and loads with the 512-LUN profile;
- SPDK identify enumerates after userspace binding;
- CSV contains 15 successful SPDK trials;
- `dmesg` for the gate run contains `requested 512 pages, sensed 512 pages`;
- device-observed latency is near the 30 us level, not proportional to 512 pages;
- final notes report the exact `dmesg` latency line(s) and the host median/min/max from the CSV.

Failure conditions:
- `sensed < 512`: prepopulation, LPN list, or mapping is wrong.
- SPDK identify fails: host path is not ready.
- Device latency scales toward `512 * tR`: fan-out is serialized or loop `stime` is wrong.
- io_worker copies normal page data: the custom command no longer preserves O(1) host data movement.

---

## 14. Deliverables

1. Device code: profile constants, opcode definition, `conv_inflash_compute()`, dispatch case, and custom io_worker skip branch.
2. Host code: `host/inflash_bench_spdk.c` and build target/command.
3. Run support: script or exact transcript for build, load, prepopulate, bind, identify, benchmark, `dmesg`, and reset.
4. Results: `results_pim_spdk.csv`, relevant `dmesg` lines, and a short gate verdict.

Keep the report focused on the gate and SPDK/uio feasibility. Do not add figures unless asked.

---

## 15. Acceptance Checklist

Before calling the task complete, confirm: clean build; 512-LUN profile inside the 16 GiB memmap;
prepopulation through `/dev/nvme1n1`; SPDK `uio_pci_generic` identify; opcode `0x91` with
`cdw10[0] = 512`; exact 512-entry PRP list read; `requested 512 pages, sensed 512 pages`; device
latency near the 30 us level; no 512-page host payload transfer; `conv_read()`/`conv_write()`
unchanged; SPDK reset restored the kernel driver.

---

## 16. Code References

Read `ssd_config.h`, `nvme.h`, `io.c`, `conv_ftl.c`, and `ssd.c` for the local profile, command,
dispatch, PRP-copy, FTL mapping, and timing APIs. Use SPDK's `spdk_env_init`, `spdk_nvme_probe`,
`spdk_nvme_ctrlr_alloc_io_qpair`, `spdk_nvme_ctrlr_cmd_io_raw`,
`spdk_nvme_qpair_process_completions`, and `spdk_zmalloc`.
