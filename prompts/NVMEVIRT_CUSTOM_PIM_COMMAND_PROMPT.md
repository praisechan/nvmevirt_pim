# Task Prompt: Custom NVMe Page-List Command for NVMeVirt, Driven by SPDK

> Use this file as the complete task specification. You are working from a clean,
> stock NVMeVirt checkout (https://github.com/snu-csl/nvmevirt). Assume none of
> the previous trial implementations, reports, scripts, or local modifications
> exist. Implement only the feature described here, then verify the single
> required gate. Do not add alternate experiments, read-path shortcuts, MDTS
> tricks, extra controller modes, or broad parameter sweeps unless they are
> needed to debug a failing gate.

---

## 0. Goal

Add one vendor-specific NVMe I/O command to NVMeVirt. The host sends a single
command whose PRP data buffer contains a list of page IDs (LPNs). NVMeVirt
copies that page-id list from host memory, then expands the one command inside
the controller into one NAND read/sense per listed LPN. The important behavior
is that the device model charges those NAND reads against the addressed LUNs
using NVMeVirt's existing `ssd_advance_nand()` timing model, so page IDs that
map to distinct LUNs run in parallel.

For the configured geometry, 16 channels x 32 LUNs/channel x 1 plane/LUN gives
512 independent LUNs. Therefore a single custom command carrying the 512 LPNs
`0..511` should activate all 512 LUNs/planes in one modeled round. The required
gate is: the device-observed latency printed by NVMeVirt for that single
512-page command converges near the configured NAND read latency, about 30 us,
not 512 x 30 us. The host benchmark must use SPDK so it can submit the vendor
opcode directly and avoid kernel block-layer command overhead.

---

## 1. Scope and Non-Goals

Implement:
- one SSD profile for the 512-LUN geometry;
- one vendor-specific I/O opcode shared by host and device;
- one `conv_ftl.c` handler that PRP-reads a `uint64_t` LPN list and fans out
  existing NAND timing calls;
- one `io.c` data-copy branch for the custom command's tiny result;
- one SPDK benchmark that submits the raw command and records host latency;
- one guarded run script or exact runbook that builds, loads, prepopulates,
  binds SPDK, runs the gate, captures `dmesg`, and restores the kernel driver.

Do not implement:
- automatic all-plane expansion on normal `nvme_cmd_read`;
- MDTS-based large-read experiments;
- io_uring/fio comparisons;
- dispatcher/io_worker scaling studies;
- arbitrary workload emulation or ANNS logic;
- plots or sweeps as required deliverables.

Small diagnostic runs are fine only when the gate fails or to prevent a false
positive, but they must not become part of the required implementation.

---

## 2. Target Machine and Runtime Setup

Machine:
- CPU: i9-13900F, 32 logical CPUs. Use P-cores for NVMeVirt kthreads and
  E-cores for the SPDK host benchmark.
- Reserved memory for NVMeVirt: boot with `memmap=16G$96G`, then load the
  module with `memmap_start=96G memmap_size=16G`.
- Treat the GRUB edit and reboot as user actions. Surface them explicitly.

Core placement:
- Load NVMeVirt with disjoint P-core kthreads, for example `cpus=7,8` for one
  dispatcher and one io_worker.
- Run the SPDK benchmark on E-cores, for example `taskset -c 16-31`.
- Do not share a core between the host poller and NVMeVirt kthreads.

Device path:
- While bound to the kernel `nvme` driver, the device should enumerate as
  `/dev/nvme1n1`. Use this phase for prepopulation.
- Binding to SPDK removes `/dev/nvme1n1`; restore it with SPDK reset after the
  benchmark.

---

## 3. SSD Profile

Add a profile in `ssd_config.h` for a conventional SSD namespace using
`conv_ftl`.

Geometry and timing:
- `SSD_PARTITIONS = 1`
- `NAND_CHANNELS = 16`
- `LUNS_PER_NAND_CH = 32`
- `PLNS_PER_LUN = 1`
- `FLASH_PAGE_SIZE = 4 KB`
- `CELL_MODE = CELL_MODE_SLC`
- all NAND read latency constants = `30000` ns
- `NAND_CHANNEL_BANDWIDTH = 800` MB/s
- `FW_CH_XFER_LATENCY = 0`
- `MDTS = 6` is acceptable because the custom command's page count is not a
  normal NLB field.

Capacity:
- Keep the configured capacity within the 16 GiB reserved memmap.
- It only needs enough mapped pages to cover at least the 512 tested LPNs, plus
  ordinary metadata/headroom. Do not over-provision just for future tests.

New constants:
- `INFLASH_PIM_OPCODE = 0x91`
- `COMPUTE_RESULT_SIZE = 64`
- `INFLASH_PIM_MAX_PAGES = 512`

Put the opcode definition in one shared header visible to both the device code
and the host benchmark, or duplicate it only with an explicit compile-time or
runtime check that the values match. Avoid scattering magic `0x91` literals.

---

## 4. Stock NVMeVirt Anchors to Read First

Read the clean tree before editing and use the local code's exact types.

Device command routing:
- `io.c`: `__nvmev_proc_io()` obtains SQ entries and calls the namespace
  handler.
- `conv_ftl.c`: `conv_proc_nvme_io_cmd()` switches on `cmd->common.opcode`.
  Add `case INFLASH_PIM_OPCODE:` here and call `conv_inflash_compute()`.

NAND timing pattern:
- `conv_ftl.c`: mirror the inner timing behavior of `conv_read()`.
- For each requested LPN, map the LPN with `get_maptbl_ent()`.
- Skip unmapped or invalid PPAs, exactly as the normal read path does.
- Build `struct nand_cmd` with `.type = USER_IO`, `.cmd = NAND_READ`,
  `.stime = req->nsecs_start`, `.xfer_size = COMPUTE_RESULT_SIZE`,
  `.interleave_pci_dma = false`, and `.ppa = &ppa`.
- Call `ssd_advance_nand()` and set `ret->nsecs_target` to the maximum
  completion time over all sensed pages.

Host-memory copy pattern:
- `io.c`: `__do_perform_io()` already walks PRP1/PRP2, maps host physical pages
  with `kmap_atomic_pfn(PRP_PFN(paddr))` or `memremap()`, applies page offsets,
  and copies bytes.
- Reuse that PRP-walk idiom for the controller-side DMA-read of the page-id
  list. Do not assume the SPDK buffer is virtually addressable in the kernel.

Important type detail:
- In NVMeVirt's command union, the vendor command should be read through
  `cmd->common`. Use little-endian helpers where appropriate, e.g.
  `le32_to_cpu(cmd->common.cdw10[0])`.

---

## 5. Custom Command Contract

Opcode:
- I/O opcode `INFLASH_PIM_OPCODE = 0x91`.

Command dwords:
- `cdw10[0]`: number of LPNs, `N`.
- `cdw10[1]`: optional flags, initially zero. Reject nonzero flags unless you
  implement them.
- Do not overload `rw.slba` or `rw.length`; those fields are not part of this
  command's semantic contract.

Data buffer:
- The PRP data buffer starts as `N` contiguous little-endian `uint64_t` LPNs.
- For the required gate, `N = 512` and the list is `0, 1, ..., 511`.
- The same buffer may receive a tiny completion result after the device has
  already copied the input list into kernel memory.

Transfer lengths:
- Device-side input copy length: `N * sizeof(uint64_t)`.
- io_worker result copy length: exactly `COMPUTE_RESULT_SIZE`, independent of
  `N`.
- Host SPDK command transfer length should be at least
  `max(N * sizeof(uint64_t), COMPUTE_RESULT_SIZE)` so the same DMA buffer can
  hold the input list and the result without relying on undefined behavior.
  For `N <= 512`, this is at most 4096 bytes.

Completion:
- Return normal NVMe success when all valid listed pages have been charged.
- Result content is not under test. It may be zeros or a simple fixed pattern.
- Set `ret->status = NVME_SC_SUCCESS`; use an invalid-field or internal-error
  status for malformed `N`, PRPs, or out-of-range LPNs.

---

## 6. Device Implementation

Add `conv_inflash_compute(struct nvmev_ns *ns, struct nvmev_request *req,
struct nvmev_result *ret)` in `conv_ftl.c`.

Required behavior:
1. Read `N = le32_to_cpu(req->cmd->common.cdw10[0])`.
2. Reject `N == 0` and `N > INFLASH_PIM_MAX_PAGES`.
3. Allocate or stack-store a bounded `u64 lpns[INFLASH_PIM_MAX_PAGES]`.
4. PRP-copy `N * sizeof(u64)` bytes from host memory into `lpns`.
5. Validate each LPN against the namespace/FTL page range before using it.
6. For each mapped, valid LPN, issue one existing NAND read timing operation
   using the same `stime = req->nsecs_start`.
7. Track both `requested = N` and `sensed = number of mapped/valid pages that
   actually called `ssd_advance_nand()`.
8. Set `ret->nsecs_target` to the max NAND completion time. If no page was
   sensed, complete successfully at `req->nsecs_start` but print `sensed 0`
   so a missing prepopulation cannot pass.
9. Print the device-latency observer:

```c
printk_ratelimited(KERN_INFO
    "NVMeVirt: inflash_dev_lat %llu ns (requested %u pages, sensed %u pages)\n",
    ret->nsecs_target - req->nsecs_start, requested, sensed);
```

Critical timing requirement:
- Every listed page uses the same base `stime = req->nsecs_start`.
- Do not update `stime` between pages. Distinct LUNs must overlap naturally
  through `ssd_advance_nand()`, while repeated pages on the same LUN should
  serialize naturally through that LUN's `next_lun_avail_time`.

Localized changes only:
- Add the opcode to the opcode enum/string table if that is how the clean tree
  reports opcodes.
- Add one dispatch case in `conv_proc_nvme_io_cmd()`.
- Do not change `conv_read()` or `conv_write()` semantics.
- Do not alter `ssd_advance_nand()` unless the clean tree requires a trivial
  compile fix for the new call site.

---

## 7. io_worker Result Copy

In `io.c`, add a minimal branch in the existing data-copy path for
`INFLASH_PIM_OPCODE`.

Required behavior:
- Copy exactly `COMPUTE_RESULT_SIZE` bytes from the namespace/device-side
  backing area or a small fixed result source into the command PRP buffer.
- Do not copy `N * 4096` bytes and do not copy page data for the listed LPNs.
- Do not derive the custom command's copy length from `rw.length`.
- Preserve normal write/read behavior for standard opcodes.

If the clean tree has both CPU-copy and DMA-copy io_worker paths, either:
- route the custom opcode through the CPU-copy path only, or
- add equivalent custom-length handling to both paths.

The important invariant is one host command, one tiny host result transfer.

---

## 8. SPDK Host Benchmark

Create `host/inflash_bench_spdk.c` and a small `host/Makefile` target.

Required benchmark behavior:
- Initialize SPDK with a core mask suitable for E-cores.
- Probe and attach exactly the target BDF.
- Open namespace 1 and allocate one I/O qpair.
- Allocate one DMA buffer with `spdk_zmalloc()`.
- Fill the first `N` entries with little-endian `uint64_t` LPNs.
- Submit one raw I/O command with `spdk_nvme_ctrlr_cmd_io_raw()` or the current
  SPDK equivalent:
  - `opcode = INFLASH_PIM_OPCODE`
  - `nsid = 1`
  - `cdw10 = N`
  - transfer buffer = the DMA buffer
  - transfer length = `max(N * sizeof(uint64_t), COMPUTE_RESULT_SIZE)`
- Busy-poll `spdk_nvme_qpair_process_completions()` until the callback fires.
- Record host end-to-end latency from just before submission to callback.

CLI:
- `--bdf <BDF>`
- `--npages N`
- `--qdepth Q` (only `Q=1` is required for the gate)
- `--trials T`
- `--csv <path>`
- optional `--core-mask` if easier than relying on `taskset`.

CSV schema:
- `host_stack,n_pages,qdepth,trial,t_e2e_ns,status`

For the gate, run `--npages 512 --qdepth 1 --trials 15`, with the page list
`0..511`.

---

## 9. Prepopulation

Prepopulation is mandatory. Unmapped LPNs are skipped by `conv_ftl`, which would
produce a false near-zero device latency.

Required:
- While the device is bound to the kernel `nvme` driver, write at least LPNs
  `0..511` on `/dev/nvme1n1`.
- Use a simple deterministic write, for example `dd` or `fio`, with direct I/O
  if convenient.
- After prepopulation, bind the device to SPDK and run the benchmark.
- The gate only passes if the device log says `requested 512 pages, sensed 512
  pages`.

Do not rely on the custom command itself to populate mappings.

---

## 10. SPDK Feasibility Gate Before Benchmarking

Before running the custom benchmark:
1. Find the PCI BDF:
   `ls -l /sys/block/nvme1n1/device` or `lspci | grep -i non-volatile`.
2. Run SPDK setup status.
3. Bind only the NVMeVirt BDF to userspace.
4. Prefer `uio_pci_generic`. NVMeVirt's software PCI device may not have an
   IOMMU group, so `vfio-pci` can fail even when the device is otherwise usable.
5. Run SPDK identify:
   `sudo spdk/build/examples/identify -r "trtype:PCIe traddr:<BDF>"`.

If identify cannot enumerate the controller, stop and report the exact failure.
The custom benchmark cannot be interpreted without this step.

Remember:
- SPDK setup may reserve hugepages; record the count used.
- SPDK binding removes `/dev/nvme1n1`.
- Run `sudo spdk/scripts/setup.sh reset` at the end to restore the kernel
  driver.

---

## 11. Minimal Build and Runbook

```bash
cd <clean-nvmevirt>

# Build NVMeVirt and the SPDK benchmark.
make
make -C host SPDK_DIR=<path-to-spdk>

# Load under the kernel driver and prepopulate.
sudo insmod nvmev.ko memmap_start=96G memmap_size=16G cpus=7,8
dmesg | tail -50 | grep -iE 'nvmev|tt_luns|luns'
# Confirm 512 LUNs and /dev/nvme1n1.

# Prepopulate LPNs 0..511, then find the BDF.
sudo dd if=/dev/zero of=/dev/nvme1n1 bs=4K count=512 oflag=direct status=none
BDF=<detected-BDF>

# Bind to SPDK and smoke-test enumeration.
sudo DRIVER_OVERRIDE=uio_pci_generic PCI_ALLOWED="$BDF" spdk/scripts/setup.sh
sudo spdk/build/examples/identify -r "trtype:PCIe traddr:$BDF"

# Run the required gate. Clear dmesg immediately before the gate run.
sudo dmesg -C
sudo taskset -c 16-31 host/inflash_bench_spdk --bdf "$BDF" \
  --npages 512 --qdepth 1 --trials 15 --csv results_pim_spdk.csv
dmesg | grep inflash_dev_lat

# Restore kernel driver.
sudo spdk/scripts/setup.sh reset
```

If root privileges or GRUB changes are required, ask the user to perform them.
Do not assume passwordless `sudo`.

---

## 12. Expected Timing

Source of truth:
- The gate is based on NVMeVirt's device-observed line:
  `inflash_dev_lat <ns> (requested 512 pages, sensed 512 pages)`.
- Host SPDK latency is reported alongside, but it is not the primary pass/fail
  value.

Why it should converge:
- All 512 listed LPNs use the same `req->nsecs_start`.
- Consecutive LPNs written during prepopulation should stripe across the
  16 x 32 LUN geometry in the existing `conv_ftl` write-pointer order.
- Each LUN receives one NAND read, so the per-LUN timelines overlap.
- With all read latencies set to 30000 ns and only a 64-byte per-page channel
  transfer, the modeled device latency should be close to 30000 ns plus a small
  channel/model overhead.

Accept a small additive overhead; reject any result that is near 512 x 30000 ns
or any result where `sensed` is less than 512.

---

## 13. Required Verification Gate

Run exactly the required all-plane command:
- prepopulated LPNs: `0..511`
- command page list: `0..511`
- `N = 512`
- `qdepth = 1`
- `trials = 15`
- host path: SPDK raw command

Pass criteria:
- Module builds and loads with the 512-LUN profile.
- SPDK identify enumerates the device after userspace binding.
- `dmesg` contains at least one line for the gate run with:
  - `requested 512 pages`
  - `sensed 512 pages`
  - device latency near the 30 us level, not near 15.36 ms.
- The CSV contains 15 successful SPDK trials for the same command.
- The final report states the median/min/max device-observed latency from the
  captured `dmesg` lines and the median host e2e latency from the CSV.

Failure conditions:
- `sensed < 512`: prepopulation or LPN mapping is wrong.
- SPDK identify fails: host path is not ready; stop and report.
- Device latency scales with 512 x tR: the fan-out is serialized or `stime` is
  being advanced incorrectly.
- Host transfer length scales as page data (`512 * 4096`): the custom command is
  not preserving O(1) host data movement.

---

## 14. Deliverables

1. Device changes:
   - profile/config constants;
   - opcode definition;
   - `conv_inflash_compute()`;
   - dispatch case;
   - custom io_worker result-copy length.
2. Host changes:
   - `host/inflash_bench_spdk.c`;
   - `host/Makefile` target or documented build command.
3. Run support:
   - either a `RUN=1`-guarded script or exact command transcript for build,
     load, prepopulate, bind, identify, benchmark, `dmesg`, and reset.
4. Results:
   - `results_pim_spdk.csv`;
   - the relevant `dmesg` lines;
   - a short report with the gate verdict.

Keep the report focused on the gate. Mention SPDK/uio feasibility and the exact
latency numbers. Do not add figures unless the user asks.

---

## 15. Acceptance Checklist

- [ ] Clean NVMeVirt tree builds after the localized changes.
- [ ] New profile reports 512 LUNs/planes and fits inside the 16 GiB memmap.
- [ ] Normal prepopulation writes still work through `/dev/nvme1n1`.
- [ ] SPDK binds with `uio_pci_generic` and identify enumerates the controller.
- [ ] The SPDK benchmark issues opcode `0x91` with `cdw10[0] = 512`.
- [ ] NVMeVirt PRP-reads exactly the 512-entry LPN list from host memory.
- [ ] The gate run prints `requested 512 pages, sensed 512 pages`.
- [ ] Device-observed latency is near 30 us, not proportional to 512 pages.
- [ ] Host result transfer is `COMPUTE_RESULT_SIZE`, not 512 page reads.
- [ ] `conv_read()` and `conv_write()` behavior are unchanged.
- [ ] SPDK reset restores the kernel driver at the end.

---

## 16. Code References

- `ssd_config.h`: SSD profiles, geometry, timing constants, `MDTS`.
- `nvme.h` or local equivalent: opcode enum/string table and command structs.
- `io.c`: SQ processing, namespace dispatch, PRP copy implementation, io_worker
  data copy.
- `conv_ftl.c`: `conv_proc_nvme_io_cmd()`, `conv_read()`, map-table lookup,
  valid-PPA checks, `ssd_advance_nand()` usage.
- `ssd.c`: `ssd_advance_nand()`, per-LUN availability, channel transfer model.
- SPDK APIs: `spdk_env_init`, `spdk_nvme_probe`,
  `spdk_nvme_ctrlr_alloc_io_qpair`, `spdk_nvme_ctrlr_cmd_io_raw`,
  `spdk_nvme_qpair_process_completions`, `spdk_zmalloc`.
