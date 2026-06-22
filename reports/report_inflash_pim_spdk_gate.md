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

## Serial Multi-Command Behavior

Follow-up question: when several 512-page commands are submitted back-to-back
in serial (`qdepth = 1`), does total time scale as `N x (30 us + alpha)`, with
each command still completing at the ~30 us level rather than accumulating?

Test: 30 sequential 512-page commands (`--npages 512 --qdepth 1 --trials 30`,
LPNs `0..511`), artifacts `results_pim_serial.csv` and
`dmesg_inflash_pim_serial.txt`.

Results:

- 30/30 trials successful (`status = 0`).
- **Per-command device latency is flat:** every `inflash_dev_lat` line reports
  the identical `34152 ns (requested 512 pages, sensed 512 pages)`. The value
  does not grow across the serial stream — each command is an independent ~34 us
  operation. (Only ~10 lines appear in dmesg because `printk_ratelimited`
  suppresses the rest; the flat per-command host e2e confirms all 30 matched.)
- **Per-command host e2e is flat:** min 34522 ns, mean 34673 ns, max 35235 ns.
- **Aggregate scales linearly in N:** sum of host e2e over 30 commands =
  1.040 ms ~= `30 x 34.7 us`. The device-only ideal `N x 34152 ns` = 1.025 ms;
  the ~15 us difference is per-command SPDK submit/poll overhead (~0.5 us each).

Interpretation:

- Intra-command, the 512 distinct LUNs overlap through `ssd_advance_nand()`, so
  one command costs ~30 us + ~4.15 us channel-model overhead, not 512 x 30 us.
- Inter-command, at `qdepth = 1` the host waits for each completion before
  submitting the next, so by the time command k+1 arrives, command k's LUNs are
  free (`next_lun_avail_time` in the past). Commands therefore do not overlap and
  simply add up.

This confirms the original assumption: **serial total = N x (30 us + alpha)**
(here `alpha ~= 4.15 us`), i.e. ~1.04 ms for N = 30, versus ~460.8 ms for a
broken serialized-fan-out model (`512 x 30 us x N`).

## FTL-Aware Addressing: explicit even distribution across 16 channels

Goal: guarantee that a 512-page command spreads evenly across all 16 NAND
channels by *FTL-aware addressing*, instead of relying on sequential
prepopulation to happen to stripe the LPNs. The `conv_ftl` write pointer
advances channel-first (`advance_write_pointer` increments `ch` before `lun`,
one-page oneshot, `PLNS_PER_LUN = 1`), so LPN `n` deterministically lands on
channel `n % nchs`.

Implementation:

- **Host (`host/inflash_bench_spdk.c`)**: new `--chan-affine` / `--nchs C`
  (default `C = 16`) builds the LPN list grouped by channel residue
  (`fill_lpn_list()`): for each channel `c`, it emits the LPNs in the command
  window with `lpn % C == c`. For a 512-page window this places exactly
  `512 / 16 = 32` LPNs on every channel by construction.
- **Device (`conv_ftl.c`)**: `conv_inflash_compute()` now accumulates a
  per-channel sensed histogram (`ch_counts[ppa.g.ch]`) and appends it to the
  observer line, so the distribution is verifiable from `dmesg`.

Test: `--npages 512 --qdepth 1 --trials 15 --chan-affine --nchs 16`, artifacts
`results_pim_ftlaware.csv` and `dmesg_inflash_pim_ftlaware.txt`.

Result (identical on every trial):

```text
NVMeVirt: inflash_dev_lat 34152 ns (requested 512 pages, sensed 512 pages, ch[16]={32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32})
```

- **Every channel sensed exactly 32 pages** — perfectly even by construction.
- Device latency stays at `34152 ns` and host e2e at 34488 / 34634 / 35035 ns
  (min/median/max, 15/15 successful), unchanged from the sequential gate: the
  *set* of LPNs is the same `0..511`, so reordering them FTL-aware does not move
  the timing - it makes the even 16-channel distribution explicit and provable
  rather than incidental.

## Current Verdict

PASS. Implementation matches the prompt specification and the required
verification gate passes end-to-end via the SPDK raw-command host path, after
the two host-side SPDK 25.05 link/init fixes noted above. Serial multi-command
submission scales linearly as `N x (30 us + alpha)` with flat per-command device
latency. FTL-aware (channel-affine) addressing makes the even spread explicit
and verifiable: the device histogram reports exactly 32 sensed pages on each of
the 16 channels. Generated artifacts: `results_pim_spdk.csv`,
`dmesg_inflash_pim.txt`, `results_pim_serial.csv`,
`dmesg_inflash_pim_serial.txt`, `results_pim_ftlaware.csv`, and
`dmesg_inflash_pim_ftlaware.txt`.
