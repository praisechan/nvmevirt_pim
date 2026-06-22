# NVMeVirt In-Flash PIM SPDK Gate Report

Date: 2026-06-22

## Scope

This report covers the implementation status for the vendor-specific NVMe I/O command described in `prompts/NVMEVIRT_CUSTOM_PIM_COMMAND_PROMPT.md`.

The implemented command lets the host submit one raw NVMe command with a PRP input buffer containing a little-endian `uint64_t` LPN list. NVMeVirt copies that list from host memory, validates the LPNs, and expands the command inside `conv_ftl` into one modeled NAND read/sense per mapped page.

## Implementation Summary

Device-side changes:

- Added shared constants in `inflash_pim.h`:
  - `INFLASH_PIM_OPCODE = 0x91`
  - `INFLASH_PIM_MAX_PAGES = 512`
  - `COMPUTE_RESULT_SIZE = 64`
- Added `nvme_cmd_inflash_pim` to the NVMe opcode table in `nvme.h`.
- Added the `INFLASH_PIM_512LUN` conventional SSD profile in `ssd_config.h`.
- Switched the default `Kbuild` target to `CONFIG_NVMEVIRT_SSD := y` with `BASE_SSD=INFLASH_PIM_512LUN`.
- Added `conv_inflash_compute()` in `conv_ftl.c`.
- Added a dispatch case for `nvme_cmd_inflash_pim`.
- Added I/O worker skip branches in `io.c` so the custom command does not perform normal read/write backing-store movement.

Host-side changes:

- Added `host/inflash_bench_spdk.c`.
- Added `host/Makefile` using `/home/juchanlee/spdk` by default.
- Added `host/run_inflash_pim_gate.sh`, guarded by `RUN=1`.

## SSD Profile

The new conventional SSD profile is configured for the gate geometry:

- `SSD_PARTITIONS = 1`
- `NAND_CHANNELS = 16`
- `LUNS_PER_NAND_CH = 32`
- `PLNS_PER_LUN = 1`
- Total modeled LUNs: `512`
- `FLASH_PAGE_SIZE = 4 KB`
- `CELL_MODE = CELL_MODE_SLC`
- NAND read latencies: `30000 ns`
- `NAND_CHANNEL_BANDWIDTH = 800 MB/s`
- `FW_CH_XFER_LATENCY = 0`
- `MDTS = 6`

The namespace capacity is capped at `2 GiB`, which is comfortably inside the required `16 GiB` reserved memmap while leaving enough space for LPNs `0..511` and metadata.

## Command Contract

The SPDK benchmark submits:

- Opcode: `0x91`
- Namespace: `1`
- `cdw10 = N`
- `cdw11 = 0`
- PRP data buffer: `N` little-endian `uint64_t` LPNs
- Gate list: `0..511`
- Host transfer size for `N=512`: `4096 bytes`

The device returns:

- Success for a well-formed command.
- Completion result low dword: sensed page count.
- Completion result high dword: requested page count.
- A rate-limited kernel observer line:

```text
NVMeVirt: inflash_dev_lat <ns> ns (requested <N> pages, sensed <M> pages)
```

## Timing Behavior

For each valid, mapped LPN, the handler builds a `struct nand_cmd` with:

- `.type = USER_IO`
- `.cmd = NAND_READ`
- `.stime = req->nsecs_start`
- `.xfer_size = COMPUTE_RESULT_SIZE`
- `.interleave_pci_dma = false`

The critical timing rule is preserved: every listed page uses the same request start time. This allows pages on distinct LUNs to overlap through the existing `ssd_advance_nand()` model. Repeated pages or pages mapped to the same LUN naturally serialize through that LUN's availability time.

## Verification Performed

Build and smoke checks completed:

- Kernel module build succeeds (`make`), producing `nvmev.ko` with the
  `INFLASH_PIM_512LUN` profile (`16 channels`, ns size `2 GiB`).
- SPDK host benchmark build succeeds.
- The only non-prompt `0x91` literal is the shared definition in `inflash_pim.h`.
- Kernel build emits only the existing compiler-identity warning and skips BTF
  (no `vmlinux`); no large-stack-frame warning after moving the 512-entry LPN
  array to `kmalloc_array()`.

### Host benchmark fixes required to pass the gate

Two defects in the original `host/inflash_bench_spdk.c` / `host/Makefile`
prevented the SPDK host path from initializing against this SPDK build
(SPDK 25.05). Both were fixed:

1. **Missing `opts_size`.** SPDK 25.05 requires `env_opts.opts_size =
   sizeof(env_opts)` to be set *before* `spdk_env_opts_init()`. Without it,
   `spdk_env_opts_init` aborted with `Invalid opts->opts_size 0 too small` and
   left the env opts uninitialized. Fixed in `inflash_bench_spdk.c`.
2. **PCIe transport stripped by static linking.** SPDK registers its NVMe
   transports via constructors inside `libspdk_nvme.a`; a flat
   `pkg-config --libs --static` link drops those objects, so probe failed with
   `NVMe trtype 256 (PCIE) not available`. `host/Makefile` now wraps the
   `-lspdk_*` archives in `-Wl,--whole-archive -Wl,--no-as-needed ...
   -Wl,--no-whole-archive` (mirroring SPDK's own `mk/spdk.app_vars.mk`), leaving
   DPDK/system libs outside the group. The rebuilt binary contains the PCIe
   transport symbols and probes successfully.

## Gate Status: PASSED

Executed on 2026-06-22 on the host booted with `memmap=16G$96G` (NVMeVirt
loaded `memmap_start=96G memmap_size=16G cpus=7,8`):

```bash
cd /home/juchanlee/nvmevirt_pim
RUN=1 SPDK_DIR=/home/juchanlee/spdk host/run_inflash_pim_gate.sh
```

The run performed: kernel + benchmark build, `insmod`, `/dev/nvme1n1`
prepopulation (`dd` 512 x 4K), BDF discovery (`0001:10:00.0`),
`uio_pci_generic` binding, SPDK `identify`, the 15-trial raw-command benchmark
at `N=512, qdepth=1`, `dmesg` capture, and SPDK driver reset in cleanup. The
kernel `nvme` driver and `/dev/nvme1n1` were restored afterward.

### Device-observed latency (pass/fail source of truth)

Every trial reports the identical, fully fanned-out result:

```text
NVMeVirt: inflash_dev_lat 34152 ns (requested 512 pages, sensed 512 pages)
```

- `sensed 512 pages` confirms prepopulation, the PRP LPN-list read, and the
  per-LUN fan-out are all correct.
- `34152 ns` ≈ the `30000 ns` NAND read latency plus ~4.2 us of additive
  channel-model cost (the 64-byte per-page internal transfers serializing on
  the 16 shared channels). This is the expected "30-40 us" level and is ~450x
  below a serialized `512 * 30 us = 15.36 ms` result.

### Host SPDK e2e latency (`results_pim_spdk.csv`)

- 15/15 trials successful (`status = 0`).
- min = 34596 ns, median = 34651 ns, max = 46000 ns (first-trial warm-up).

The host e2e tracks the device latency closely, confirming negligible host-side
payload transfer (`io_size = 0` for the custom opcode).

## Pass Criteria — all met

- [x] Module builds and loads with the 512-LUN profile.
- [x] SPDK `identify` enumerates the NVMeVirt controller after `uio_pci_generic` binding.
- [x] CSV contains 15 successful SPDK trials.
- [x] `dmesg` for the gate run contains `requested 512 pages, sensed 512 pages`.
- [x] Device-observed latency (~34.2 us) is near the 30 us level, not proportional to 512 pages.
- [x] No 512-page host payload transfer; `conv_read()` / `conv_write()` unchanged; SPDK reset restored the kernel driver.

## Current Verdict

PASS. Implementation matches the prompt specification and the required
verification gate passes end-to-end via the SPDK raw-command host path, after
the two host-side SPDK 25.05 link/init fixes noted above. Generated artifacts:
`results_pim_spdk.csv` and `dmesg_inflash_pim.txt`.
