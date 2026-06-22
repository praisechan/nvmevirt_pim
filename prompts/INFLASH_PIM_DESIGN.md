# INFLASH_PIM — Implementation Design (team contract)

This is the authoritative interface contract for the in-flash-compute emulation.
Workers MUST follow the macro/function names here so their changes compose.

## Decisions (locked by lead, from the prompt + environment answers)

- **LUN-as-plane**: 16 channels × 32 LUNs/ch × 1 plane/LUN = **512 independent LUNs**.
  No `ssd_advance_nand()` change for parallelism (Task B is config-only).
- **Compute read = modified read path** (Task C / option C1). No new NVMe opcode.
  In the `INFLASH_PIM` build, the read path omits host page-data DMA and charges the
  channel only a tiny command/result transfer. Host issues ordinary 4 KB reads.
- **Host = io_uring** (liburing) against `/dev/nvmeXn1` with `O_DIRECT`. No SPDK.
- **1 request = 1 × 4 KB page = 1 LUN.** `FLASH_PAGE_SIZE = KB(4)` so there is no
  same-flash-page aggregation; each request is exactly one `ssd_advance_nand()`.
- **Target round latency**: `t_round = tR + t_cmd = 30 us + 8 us = 38 us`.
  `T_model(N) = 38 us * ceil(N / 512)`.

## Interface contract (names workers must use)

In `ssd_config.h`, the new profile defines (consumed by `conv_ftl.c`):

- `#define INFLASH_PIM 5`  (added to the `/* SSD Model */` list)
- Inside the `#elif (BASE_SSD == INFLASH_PIM)` block:
  - `#define INFLASH_COMPUTE 1`   ← gate macro Task C keys off of
  - `#define COMPUTE_RESULT_SIZE (64)`  ← tiny per-LUN channel transfer (bytes); a calibration knob

## Task A — profile (owner: worker-1, file: ssd_config.h + Kbuild)

Mirror the `SAMSUNG_970PRO` profile macro set (it is the CONV reference) and change:

```
#define NR_NAMESPACES 1
#define NS_SSD_TYPE_0 SSD_TYPE_CONV
#define NS_CAPACITY_0 (0)
#define NS_SSD_TYPE_1 NS_SSD_TYPE_0
#define NS_CAPACITY_1 (0)
#define MDTS (6)
#define CELL_MODE (CELL_MODE_SLC)          /* single read latency */

#define INFLASH_COMPUTE 1
#define COMPUTE_RESULT_SIZE (64)

#define SSD_PARTITIONS (1)
#define NAND_CHANNELS (16)
#define LUNS_PER_NAND_CH (32)              /* 8 dies x 4 planes */
#define PLNS_PER_LUN (1)
#define FLASH_PAGE_SIZE KB(4)              /* 1 page == 1 request == 1 LUN */
#define ONESHOT_PAGE_SIZE (FLASH_PAGE_SIZE * 1)
#define BLKS_PER_PLN (8)                   /* capacity tuning: see below */
#define BLK_SIZE (0)
static_assert((ONESHOT_PAGE_SIZE % FLASH_PAGE_SIZE) == 0);

#define MAX_CH_XFER_SIZE KB(4)
#define WRITE_UNIT_SIZE (512)

#define NAND_CHANNEL_BANDWIDTH (800ull)    /* MB/s */
#define PCIE_BANDWIDTH (3360ull)           /* MB/s */

/* tR = 30 us, both 4KB and full-page set identical */
#define NAND_4KB_READ_LATENCY_LSB (30000)
#define NAND_4KB_READ_LATENCY_MSB (30000)
#define NAND_4KB_READ_LATENCY_CSB (30000)
#define NAND_READ_LATENCY_LSB (30000)
#define NAND_READ_LATENCY_MSB (30000)
#define NAND_READ_LATENCY_CSB (30000)
#define NAND_PROG_LATENCY (185000)         /* used only during prepopulation writes */
#define NAND_ERASE_LATENCY (0)

/* firmware overheads — start at 0 so model can converge to 38us; lead recalibrates */
#define FW_4KB_READ_LATENCY (0)
#define FW_READ_LATENCY (0)
#define FW_WBUF_LATENCY0 (0)
#define FW_WBUF_LATENCY1 (0)
#define FW_CH_XFER_LATENCY (0)             /* calibration knob for the 8us/channel cmd cost */
#define OP_AREA_PERCENT (0.07)

#define GLOBAL_WB_SIZE (NAND_CHANNELS * LUNS_PER_NAND_CH * ONESHOT_PAGE_SIZE * 2)
#define WRITE_EARLY_COMPLETION 1

#define LBA_BITS (9)
#define LBA_SIZE (1 << LBA_BITS)
```

Capacity must fit ONE reserved 16 GB memmap region. With 512 LUNs and 4 KB pages,
`capacity = 512 * BLKS_PER_PLN * PGS_PER_BLK * 4KB`. Confirm `PGS_PER_BLK` (check how
ssd.c computes it from BLK_SIZE/BLKS_PER_PLN for the 970PRO profile) and pick
`BLKS_PER_PLN` so total capacity is ~4–8 GB and there are at least a few thousand pages
per LUN (the sweep reaches a few thousand requests). Document the final capacity.

Then: in `Kbuild`, add a build target selecting `-DBASE_SSD=INFLASH_PIM` that compiles the
CONV object set (`ssd.o conv_ftl.o pqueue/pqueue.o channel_model.o`), mirroring the
`CONFIG_NVMEVIRT_SSD` lines. Default the build to it (or document how to select).

**Verify**: `make` builds `nvmev.ko` with no errors against `/lib/modules/$(uname -r)/build`.

## Task C — compute read path (owner: worker-2, file: conv_ftl.c)

Modify `conv_read()` so that **when `INFLASH_COMPUTE` is defined**:
1. The `struct nand_cmd srd` initializer sets `.interleave_pci_dma = false`
   (no page data DMA to host).
2. At each `ssd_advance_nand()` call site, set `srd.xfer_size = COMPUTE_RESULT_SIZE`
   instead of the aggregated page byte count, so the channel models only the small
   command/result transfer (~the 8 us/channel cost once 32 LUNs serialize), while the
   NAND still charges one full `pg_rd_lat` (tR=30 us) per page.
   - NOTE: `ssd_advance_nand` selects `pg_4kb_rd_lat` only when `xfer_size == 4096`;
     with `COMPUTE_RESULT_SIZE=64` it uses `pg_rd_lat`. Both are 30 us, so either is fine.
3. Keep the normal (non-compute) behavior intact behind `#else` so other profiles are
   unaffected. Do not touch `conv_write` (prepopulation needs real writes).
4. `ret->nsecs_target` stays the max completion across touched LUNs (already the case).

Wrap changes in `#if defined(INFLASH_COMPUTE)` / `#else` / `#endif`. Do not edit
`ssd_advance_nand()`.

## Task D — io_uring host app (owner: worker-3, new dir: host/)

`host/inflash_bench.c` using **liburing**:
- `open(dev, O_RDWR|O_DIRECT)` on a device path arg (e.g. `/dev/nvme1n1`).
- 4 KB-aligned buffers (`posix_memalign`).
- **Prepopulate** phase (so maptbl is populated and LPNs stripe across all 512 LUNs):
  sequentially WRITE the LPN range `[0, max_pages)` we will later read.
- **Compute/read** phase: submit `N` 4 KB reads with configurable queue depth (default =
  N, i.e. all outstanding), offsets = `lpn * 4096` for `lpn in [0, N)` (consecutive LPNs
  stripe round-robin across the 512 LUNs via `advance_write_pointer`).
- Measure: (i) per-request submit→complete latency via `clock_gettime(CLOCK_MONOTONIC)`;
  (ii) batch end-to-end = first-submit → last-completion. The batch end-to-end is the
  primary number compared to `T_model(N)`.
- CLI: `--dev`, `--requests N`, `--qdepth`, `--trials`, `--cpu` (pin via
  `sched_setaffinity`), `--csv out.csv`, `--prepopulate`.
- Emit CSV rows: `requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns`.
- Provide a `host/Makefile` (`cc inflash_bench.c -luring -o inflash_bench`). If liburing
  headers are missing, also provide a libaio fallback `#ifdef`-guarded, but prefer
  liburing; document the package needed (`liburing-dev`).

## Task E — harness + report scaffold (owner: worker-3, dir: scripts/)

- `scripts/build.sh` — set Kbuild target to INFLASH_PIM and `make`.
- `scripts/load.sh` — `lsmod | grep nvmev` check, `rmmod nvmev_rr` (guarded, prints
  warning), `insmod nvmev.ko memmap_start=96G memmap_size=16G cpus=<lead fills>`. Mark
  the sudo lines clearly; the script should `echo` the exact command and run with `sudo`.
- `scripts/microtest.sh` — issue 512 reads (one per LUN) and 2 reads to the same LUN;
  print measured latency (used by lead to confirm ~38 us and ~2×tR).
- `scripts/sweep.sh` — prepopulate once, then loop `N in 1 2 4 8 16 32 64 128 256 512
  1024 2048 4096`, `--trials 20`, append to `results.csv`, computing
  `T_model = 38000 * ceil(N/512)` ns per row.
- `scripts/plot.py` — (a) latency vs N (model vs measured); (b) relative error vs N.
  matplotlib; save PNGs.
- `report.md` — template with the section skeleton from prompt §7 (Setup, Model recap,
  Results table, Figures, Analysis, Threats to validity, Conclusion). Leave
  `<FILL>` placeholders the lead completes after the run.

## Calibration (lead, after build+load)
- Run microtest: one read per LUN (512 reqs) must be ≈ 38 us; two reads same LUN ≈ 2×tR.
- Tune `FW_CH_XFER_LATENCY` and/or `COMPUTE_RESULT_SIZE` so 32 LUNs/ch ≈ 8 us/ch.
- Document final values in report.

## Environment (confirmed)
- Kernel 6.8.0-111-generic, headers present. 32 cores, 94 GB RAM.
- Reserved memmap: `16G$64G` and `16G$96G`. Use `96G/16G` for the new instance.
- `nvmev_rr` currently loaded (/dev/nvme1n1) — user OKed `rmmod`. Re-check before reload.
- Real NVMe is `nvme0` (boot disk). The virtual device will likely be `/dev/nvme1n1`
  (or next free nvmeX) after load — confirm with `lsblk`/`dmesg` post-insmod.
