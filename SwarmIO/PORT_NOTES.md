# SwarmIO Port: Build & Link Without Intel DSA + Per-Plane Timing Under skip_io

Target machine: Intel i9-13900F — **no Intel DSA**. The private kernel header
`drivers/dma/idxd/idxd.h` (included as `<idxd.h>`) is **absent**; only
`/usr/include/linux/idxd.h` exists. Goal: `swarmio.ko` builds clean and links
with **no** unresolved idxd/DSA symbols when both DMA backends are OFF, running
the distributed frontend with CPU-side / skipped data movement, while
**preserving per-plane (scheduling-instance) timing**.

Kernel: `6.8.0-111-generic`. All changes are confined to the SwarmIO kernel
tree (`Kbuild`, `src/*.c`, `src/*.h`, `dsa/*.h`). No `sudo` used.

---

## STEP 1 — Gate Intel DSA out of the build (`Kbuild`)

The DSA object files and the private idxd include path were made **conditional**
on either DMA backend being enabled. Previously `dsa/*.o` and
`-I.../drivers/dma/idxd` were always added.

`Kbuild` (the `swarmio-objs` line + the idxd `-I` line):

```make
swarmio-objs := src/main.o nvmev/nvme_vdev.o src/proc.o nvmev/pci.o nvmev/admin.o src/dispatcher.o \
			  src/worker.o src/simple_timing_model.o
ccflags-y += -Wno-unused-variable -Wno-unused-function
ccflags-y += -I$(src) -I$(src)/src

# Intel DSA (idxd) backend: only build the DSA objects and pull in the private
# drivers/dma/idxd headers when dispatcher or worker DMA is enabled. With both
# OFF (CPU-side / skipped data movement) the build must not reference idxd at all.
ifeq ($(filter y,$(CONFIG_SWARMIO_DMA_DISPATCHER) $(CONFIG_SWARMIO_DMA_WORKER)),y)
swarmio-objs += dsa/config.o dsa/dsa.o dsa/batch.o dsa/single.o
ccflags-y += -I/usr/src/linux-source-$(shell uname -r | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')/drivers/dma/idxd
endif
```

With both `CONFIG_SWARMIO_DMA_DISPATCHER` and `CONFIG_SWARMIO_DMA_WORKER` OFF,
`dsa/config.o dsa/dsa.o dsa/batch.o dsa/single.o` are **not compiled** and the
idxd include path is **not added**. Verified: `dsa/*.o` does not exist after a
DMA-off build.

---

## STEP 2 — Compile-guard every DSA reference (not just runtime `if`)

### 2a. `dsa/dsa.h` — the root cause of the header failure

`dsa.h` is `#include`d unconditionally by `src/common.h` (and transitively by
`main.c`, `worker.c`, `dispatcher.c`). It pulled in `<linux/idxd.h>` **and**
the private `<idxd.h>` at the top, so *every* translation unit failed to compile
when idxd was absent — gating only the build of `dsa/*.o` was insufficient.

Fix: the **plain** constants/enums and the DSA *config* structs
(`dsa_cfg_params`, `dsa_engine_cfg`, `dsa_wq_cfg`, `dsa_group_cfg`,
`dsa_dev_cfg`) — which have **no** idxd dependency — were kept ungated
(`DSA_MAX_WQS` etc. are still needed by `main.c` to size module-param arrays).
Everything that depends on idxd (the `<idxd.h>`/`<linux/idxd.h>` includes,
`struct dsa_dma_ctx_single`, `dsa_batch_desc`, `dsa_dma_ctx_batch`, the inline
helpers `__dsa_prep_hw_desc`/`__dsa_sync_wait`, and all function prototypes) is
wrapped in:

```c
#if defined(CONFIG_SWARMIO_DMA_DISPATCHER) || defined(CONFIG_SWARMIO_DMA_WORKER)
... idxd includes + idxd-using structs/inlines/prototypes ...
#endif /* CONFIG_SWARMIO_DMA_DISPATCHER || CONFIG_SWARMIO_DMA_WORKER */
```

Pointer fields elsewhere (`dispatcher.h:17 struct dsa_dma_ctx_single *dma_ctx`,
`worker.h:17/19 typedef ... dma_ctx_t`) keep compiling via incomplete-type
forward declarations — no change needed there.

### 2b. `src/dispatcher.c` — call-site guards

`disp_using_dma` is already `static bool ... = false` when
`CONFIG_SWARMIO_DMA_DISPATCHER` is undefined (dispatcher.c:24-28), so each guard
below is behavior-preserving (the runtime flag is constant-false):

- **dma ctx alloc/init** in `swarmio_dispatcher_init` (`if (disp_using_dma){...}`,
  `dsa_assign_wq_by_group_disagg`, `sizeof(struct dsa_dma_ctx_single)`,
  `dsa_dma_ctx_single_init`, `->dma_ctx->wq->name`): wrapped in
  `#ifdef CONFIG_SWARMIO_DMA_DISPATCHER`.
- **dma ctx remove** in `swarmio_dispatcher_exit`
  (`if (dispatcher->dma_ctx) dsa_dma_ctx_single_remove(...)`): wrapped in
  `#ifdef CONFIG_SWARMIO_DMA_DISPATCHER` (the `kfree(dispatcher->dma_ctx)`
  remains, safe on NULL).
- **non-coalesce SQE copy** (`#else` of `CONFIG_SWARMIO_DISP_COALESCE_SQE`):
  `dsa_dma_issue_sync_single` path guarded; when DMA off, `src = __sq_entry_at(...)`.
- **coalesced SQE fetch** (`swarmio_dispatch_sq`, the active path):
  the `if (disp_using_dma){ dsa_dma_issue_sync_single / dsa_dma_wait_one_single }
  else { memcpy }` block is wrapped in `#ifdef CONFIG_SWARMIO_DMA_DISPATCHER`,
  with a plain `memcpy` of the fetched SQEs in the `#else`.

The prefetch path (`swarmio_prefetch_sq`, `dsa_dma_issue_async_single`,
`dsa_dma_wait_one_single`) is already inside `#ifdef
CONFIG_SWARMIO_DISP_PREFETCH_SQE`, which `common.h:72-76` auto-`#undef`s when
DMA dispatcher is off — so it is never compiled when DMA is off (no edit needed).

### 2c. `src/worker.c` — call-site guards

`worker_using_dma` is `static bool ... = false` when
`CONFIG_SWARMIO_WORKER_SKIP_IO` is set **or** `CONFIG_SWARMIO_DMA_WORKER` is
unset (worker.c:22-27), so the guards are behavior-preserving:

- `__dsa_dma_issue` (calls `dsa_dma_issue_async_batch`/`dsa_dma_issue_sync_single`):
  whole function wrapped in `#ifdef CONFIG_SWARMIO_DMA_WORKER`.
- `__swarmio_submit_dma` + `__swarmio_xfer_data_using_dma` (the DMA data-copy
  helpers): wrapped together in `#ifdef CONFIG_SWARMIO_DMA_WORKER`.
- the DMA data-copy call site in `swarmio_proc_io`: the inner
  `#ifndef CONFIG_SWARMIO_WORKER_SKIP_IO` that called
  `__swarmio_xfer_data_using_dma` is now
  `#if !defined(CONFIG_SWARMIO_WORKER_SKIP_IO) && defined(CONFIG_SWARMIO_DMA_WORKER)`,
  so the call is compiled only when the helper exists; otherwise the
  `__swarmio_mark_copied(w)` (no-copy) branch is used.
- worker dma ctx **init** (`if (worker_using_dma){ dsa_assign_wq_by_group_disagg,
  sizeof(dma_ctx_t), dsa_dma_ctx_single_init }`) and **remove**
  (`if (worker->dma_ctx) dsa_dma_ctx_single_remove(...)`): each wrapped in
  `#ifdef CONFIG_SWARMIO_DMA_WORKER`.

The batch timeout flush block was already inside `#ifdef
CONFIG_SWARMIO_WORKER_BATCH_IO` (off here), so `dsa_dma_*_batch` /
`__dsa_dma_is_*_batch` are not compiled (no edit needed).

### 2d. `src/main.c` — DSA setup is never reached/linked when DMA off

- `struct dsa_cfg_params dsa_params = {...}` local: wrapped in
  `#if defined(CONFIG_SWARMIO_DMA_DISPATCHER) || defined(CONFIG_SWARMIO_DMA_WORKER)`.
- the whole DSA-enable block
  (`if (disp_using_dma || worker_using_dma){ __validate_dsa_params();
  dsa_set_params(); dsa_enable_devices(); }`) in `swarmio_init`: wrapped in the
  same `#if`.
- the two `if (vdev->dsa_enabled){ dsa_disable_devices(); }` blocks
  (`swarmio_init` error path and `swarmio_exit`): wrapped in the same `#if`.
- `__validate_dsa_params` definition (an unused `__init` function when DMA off):
  wrapped in the same `#if`.
- the `err_vdev_init:` label: moved inside the same `#if` (the only `goto
  err_vdev_init` lived in the now-gated DSA block; the cleanup is still reached
  by fall-through from `err_committers`) — removes the `-Wunused-label` warning.

`dsa_init`/`dsa_set_params`/`dsa_enable_devices` are therefore **never called**
(and never referenced at link time) when both DMA flags are off. The DMA-flag
globals (`disp_using_dma`, `worker_using_dma`) and the DMA tuning globals
(`dma_batch_size`, `num_dma_descs_per_disp/_worker`, `dma_timeout`) remain
defined unconditionally in `main.c`, so non-DSA code that references them still
links.

---

## STEP 3 — Per-plane timing under skip_io (Task B, option (b))

Active timing path: `coalesce_sqe=1` + `use_agg_timing_update=1`
(+`use_cas_timing_update=1`) ⇒ the **aggregated** function
`simple_sched_nvme_cmd_aggregated()` in `src/simple_timing_model.c` runs.

**Problem:** previously the whole scheduling-instance accumulation/update
(Step 1 + Step 2) and the per-request target computation (Step 3) were
`#ifndef CONFIG_SWARMIO_WORKER_SKIP_IO`-guarded, so under skip_io every request
collapsed to `nsecs_target = nsecs_start + min_delay` — **no per-plane
serialization** (with `read_min_delay=0`, every target == now).

**Fix (option (b)):** decouple the timing math from
`CONFIG_SWARMIO_WORKER_SKIP_IO`. skip_io must gate **only the data copy** in
`src/worker.c` (the `__swarmio_xfer_data_using_dma` / `__swarmio_xfer_data`
calls), **not** the timing in `simple_timing_model.c`. Concretely, the
`#ifndef CONFIG_SWARMIO_WORKER_SKIP_IO` guards were removed from:

- `simple_sched_nvme_cmd_aggregated()` — Step 1 accumulation, Step 2
  per-unit atomic/locked update (stores the per-unit start time), and the
  Step 3 full per-request target computation now run unconditionally (the flat
  `nsecs_start + min_delay` skip branch was deleted).
- `__sched_io_units()` (the non-aggregated per-request path) — the
  `__sched_io_units`-equivalent accumulation now runs unconditionally too, for
  consistency in case that path is selected. The inner
  `CONFIG_SWARMIO_ATOMIC_CAS_TIMING_UPDATE` / spinlock branches are unchanged.

Each removal carries a comment explaining the skip_io/timing decoupling.

**Faithful-config behavior** (`read_sched_delay=38000`, `read_min_delay=0`):
- 1 read to a scheduling instance ⇒ `nsecs_target ≈ now + 38000` (**38 µs**).
- 2 reads to the **same** instance ⇒ targets `now+38000` and `now+76000`
  (**76 µs** for the second) — Step 2 sums `38000*2` into the unit's
  next-available time and Step 3 advances per request, giving correct per-plane
  serialization.

Edits (final line numbers in `src/simple_timing_model.c`):
- `__sched_io_units`: removed `#ifndef CONFIG_SWARMIO_WORKER_SKIP_IO` opener
  (~line 42) and its matching `#endif` (~line 86); added explanatory comment.
- `simple_sched_nvme_cmd_aggregated`: removed the Step 1+2 wrapper
  `#ifndef ... #endif` (~lines 175 & 257), and the Step 3 per-request
  `#ifndef ... #else <flat min_delay> #endif` (~lines 267/313/318), keeping the
  full computation. Added explanatory comment (~lines 180-185).

The worker's data-copy elision under skip_io is untouched (worker.c
`swarmio_proc_io`: the `#else` of the skip_io guard still just marks the request
copied without moving data).

---

## STEP 4 — Verification (no sudo)

`SwarmIO/Makefile` `default` target maps build.sh flags → `CONFIG_SWARMIO_*`
and invokes `make -C /lib/modules/$(uname -r)/build M=$(pwd) ... modules`
(no install, no sudo). Active-config mapping used:

| build.sh flag           | CONFIG / macro                         | value |
|-------------------------|----------------------------------------|-------|
| `skip_io`               | `CONFIG_SWARMIO_WORKER_SKIP_IO`        | y     |
| `coalesce_sqe`          | `CONFIG_SWARMIO_DISP_COALESCE_SQE`     | y     |
| `use_agg_timing_update` | `CONFIG_SWARMIO_AGGREGATED_TIMING_UPDATE` | y  |
| `use_cas_timing_update` | `CONFIG_SWARMIO_ATOMIC_CAS_TIMING_UPDATE` | y  |
| `use_disp_dma`          | `CONFIG_SWARMIO_DMA_DISPATCHER`        | n     |
| `use_worker_dma`        | `CONFIG_SWARMIO_DMA_WORKER`            | n     |
| `max_queues`            | `NR_MAX_IO_QUEUE`                      | 256   |
| `max_fetch_sqes`        | `NR_MAX_FETCH_SQE`                     | 1024  |
| `worker_queue_size`     | `NR_WORKER_QUEUE_SIZE`                 | 32768 |

### Exact non-sudo build command (run from `SwarmIO/`)

```bash
make clean
make skip_io=y coalesce_sqe=y use_agg_timing_update=y use_cas_timing_update=y \
     use_disp_dma=n use_worker_dma=n \
     max_queues=256 max_fetch_sqes=1024 worker_queue_size=32768
```

(Equivalently, the underlying invocation is
`make -C /lib/modules/$(uname -r)/build M=$(pwd) NR_MAX_IO_QUEUE=256
NR_MAX_FETCH_SQE=1024 NR_WORKER_QUEUE_SIZE=32768
CONFIG_SWARMIO_WORKER_SKIP_IO=y CONFIG_SWARMIO_DISP_COALESCE_SQE=y
CONFIG_SWARMIO_AGGREGATED_TIMING_UPDATE=y CONFIG_SWARMIO_ATOMIC_CAS_TIMING_UPDATE=y
CONFIG_SWARMIO_DMA_DISPATCHER=n CONFIG_SWARMIO_DMA_WORKER=n modules`.)

### Clean-build evidence

- Compiles with **no idxd header error** and **no warnings/errors** in our
  sources (`src/*`, `nvmev/*`, `dsa/*`). The only build-log notes are
  environmental: "compiler differs from the one used to build the kernel" and
  "Skipping BTF generation … due to unavailability of vmlinux".
- `swarmio.ko` is produced:
  ```
  -rw-r--r-- 1 juchanlee student1 2303840 swarmio.ko
  modinfo: vermagic: 6.8.0-111-generic SMP preempt mod_unload modversions
  ```
- `dsa/*.o` are **not** built (`ls dsa/*.o` → no matches).
- Link/symbol checks (both expected empty):
  ```
  nm swarmio.ko    | grep -i idxd     ->  (empty)
  nm -u swarmio.ko | grep -i dsa      ->  (empty)
  nm -u swarmio.ko | grep -iE 'dsa|idxd|dma_ctx'  ->  (empty)
  ```

**Result: PASS** — `swarmio.ko` builds clean and links with no unresolved
idxd/DSA symbols when both DMA backends are OFF, with per-plane scheduling-
instance timing preserved under skip_io.

---

## Lead integration addendum (live bring-up on i9-13900F)

Two defects surfaced during the first real load + calibration and were fixed:

### 1. `skip_io` ignored the completion deadline (timing model not realized)
The aggregated/per-request timing math was correctly de-guarded from
`CONFIG_SWARMIO_WORKER_SKIP_IO`, BUT `__swarmio_complete()` in `src/worker.c`
still wrapped the deadline gate `if (w->nsecs_target <= curr_nsecs)` in
`#ifndef CONFIG_SWARMIO_WORKER_SKIP_IO` — so under `skip_io` requests completed
**immediately**, ignoring `nsecs_target`. Symptom: single 4 KB read measured
~11 µs instead of 38 µs; latency grew ~linearly with N with no floor.
**Fix:** made the deadline gate unconditional (skip_io now skips only the data
copy, never the timing gate). Post-fix microtests: 1 req ≈ 46 µs (38 µs model +
~8 µs host io_uring overhead), 2-reqs-same-instance ≈ 83 µs (76 µs + overhead) —
per-plane serialization faithfully preserved.

### 2. Harness CPU under-provisioning (`load_inflash.sh`)
SwarmIO pins one CPU per dispatcher AND per worker, so `num_service_units=8`
with 1 worker each needs **16** CPUs; the original `--cpus 2-9` (8 cores) made
`modprobe` fail with "CPUs provided (8) are fewer than required (16)". Fixed
`load_inflash.sh` to size the range as `0..(2*S-1)` (service units on the 16
P-core threads 0-15; fio/inflash_bench on E-cores 16-31, always disjoint).

### Build note
`make install` only copies the `.ko` if absent in `/lib/modules/.../extra`; to
reinstall after a rebuild, `rm` the installed module first (or `cp` + `depmod -a`
manually). The original `build.sh` failure was stale mixed-ownership build state
from repeated build passes — cleared by a clean rebuild.

### 3. MDTS experiment (`common.h:68`) — temporary, reverted
Experiment 3.B (`reports/report_swarmio_followup.md`) temporarily raised
`#define MDTS (5)` → `(9)` (128 KB → 2 MB max NVMe command) so a *single* command
could span all 512 scheduling instances in one host submission, isolating the
device timing model from host-submission serialization. With MDTS=9,
`/sys/block/nvme1n1/queue/max_hw_sectors_kb` reads `2048`. **Reverted to `(5)`**
after the experiment so the default stays a realistic 128 KB-cap consumer SSD; a
comment at `common.h:64-76` documents how to reproduce. Finding: the timing model
returns a one-round (38 µs) deadline for such a command (`__sched_io_units`,
`simple_timing_model.c:76-92`), but measured end-to-end scales ~0.9 µs/page from
host O_DIRECT page-pinning/PRP setup — i.e. the residual ceiling is host-side, not
the SwarmIO frontend.
