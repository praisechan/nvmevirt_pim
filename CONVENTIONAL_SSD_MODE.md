# Conventional SSD Mode in this NVMeVirt Tree

This document explains the conventional SSD path in this repository: the `SSD_TYPE_CONV` path implemented by `conv_ftl.c`, `ssd.c`, and `channel_model.c`.

It intentionally does not explain the ZNS, simple NVM/Optane, or KVSSD command sets except where they share the common NVMe front end.

The current `Kbuild` enables an InFLASH/PIM profile:

```make
CONFIG_NVMEVIRT_INFLASH := y

ccflags-$(CONFIG_NVMEVIRT_INFLASH) += -DBASE_SSD=INFLASH_PIM
nvmev-$(CONFIG_NVMEVIRT_INFLASH) += ssd.o conv_ftl.o pqueue/pqueue.o channel_model.o
```

That profile is still conventional from the FTL point of view:

```c
#elif (BASE_SSD == INFLASH_PIM)
#define NS_SSD_TYPE_0 SSD_TYPE_CONV
#define INFLASH_COMPUTE 1
```

So the active build uses the conventional page-mapped FTL plus InFLASH-specific read behavior.

## Big Picture

NVMeVirt emulates a PCIe NVMe controller inside a kernel module. The host driver sees a normal NVMe PCI device. Internally, the module maps a reserved memory range and splits it into:

- controller metadata area: BAR, doorbells, MSI-X table
- storage area: backing bytes for the emulated namespace

The conventional SSD path has two layers that are easy to confuse:

- `io.c` copies actual host data to and from the flat namespace byte array, using LBA offsets.
- `conv_ftl.c` models the flash translation layer: logical-to-physical page mapping, line allocation, GC, and NAND timing.

That means the physical page address (`struct ppa`) affects timing and FTL metadata, but the actual data bytes are still stored at `ns->mapped + lba_offset`.

## Build Profiles

Relevant build branches:

| Build flag | `BASE_SSD` | Namespace type | Main backend |
| --- | --- | --- | --- |
| `CONFIG_NVMEVIRT_SSD` | `SAMSUNG_970PRO` | `SSD_TYPE_CONV` | conventional SSD |
| `CONFIG_NVMEVIRT_INFLASH` | `INFLASH_PIM` | `SSD_TYPE_CONV` | conventional SSD plus InFLASH compute read behavior |
| `CONFIG_NVMEVIRT_NVM` | `INTEL_OPTANE` | `SSD_TYPE_NVM` | simple timing model |
| `CONFIG_NVMEVIRT_ZNS` | `WD_ZN540` or `ZNS_PROTOTYPE` | `SSD_TYPE_ZNS` | zoned SSD |
| `CONFIG_NVMEVIRT_KV` | `KV_PROTOTYPE` | `SSD_TYPE_KV` | key-value SSD |

For the conventional Samsung-style profile, see [`ssd_config.h`](ssd_config.h):

```c
#elif (BASE_SSD == SAMSUNG_970PRO)
#define NS_SSD_TYPE_0 SSD_TYPE_CONV
#define SSD_PARTITIONS (4)
#define NAND_CHANNELS (8)
#define LUNS_PER_NAND_CH (2)
#define FLASH_PAGE_SIZE KB(32)
#define ONESHOT_PAGE_SIZE (FLASH_PAGE_SIZE * 1)
#define OP_AREA_PERCENT (0.07)
```

For the active InFLASH/PIM profile:

```c
#elif (BASE_SSD == INFLASH_PIM)
#define NS_SSD_TYPE_0 SSD_TYPE_CONV
#define INFLASH_COMPUTE 1
#define COMPUTE_RESULT_SIZE (64)
#define COMPUTE_SENSE_PAGES (512)
#define NAND_CHANNELS (16)
#define LUNS_PER_NAND_CH (32)
#define FLASH_PAGE_SIZE KB(4)
```

## End-to-End I/O Flow

The conventional path is:

1. Module load calls `NVMeV_init()` in [`main.c`](main.c).
2. `NVMEV_STORAGE_INIT()` maps the reserved storage memory.
3. `NVMEV_NAMESPACE_INIT()` chooses `conv_init_namespace()` for `SSD_TYPE_CONV`.
4. `NVMEV_PCI_INIT()` creates the virtual PCI/NVMe device.
5. Admin commands create host submission/completion queues.
6. Dispatcher threads poll BAR and doorbell changes.
7. I/O SQ doorbells call `nvmev_proc_io_sq()`.
8. `io.c` wraps the SQ entry into `struct nvmev_request`.
9. The namespace callback `ns->proc_io_cmd` invokes `conv_proc_nvme_io_cmd()`.
10. The FTL calculates `ret->nsecs_target`.
11. The I/O worker copies data and posts completion when target time arrives.

Key dispatch snippet from [`io.c`](io.c):

```c
struct nvmev_request req = {
	.cmd = cmd,
	.sq_id = sqid,
	.nsecs_start = nsecs_start,
};
struct nvmev_result ret = {
	.nsecs_target = nsecs_start,
	.status = NVME_SC_SUCCESS,
};

if (!ns->proc_io_cmd(ns, &req, &ret))
	return false;

__enqueue_io_req(sqid, sq->cqid, sq_entry, nsecs_start, &ret);
```

The worker later does the actual memory copy:

```c
if (cmd->opcode == nvme_cmd_write) {
	memcpy(nvmev_vdev->ns[nsid].mapped + offset, vaddr + mem_offs, io_size);
} else if (cmd->opcode == nvme_cmd_read) {
	memcpy(vaddr + mem_offs, nvmev_vdev->ns[nsid].mapped + offset, io_size);
}
```

## Namespace Initialization

`NVMEV_NAMESPACE_INIT()` picks the backend by `NS_SSD_TYPE(i)`:

```c
if (NS_SSD_TYPE(i) == SSD_TYPE_NVM)
	simple_init_namespace(&ns[i], i, size, ns_addr, disp_no);
else if (NS_SSD_TYPE(i) == SSD_TYPE_CONV)
	conv_init_namespace(&ns[i], i, size, ns_addr, disp_no);
else if (NS_SSD_TYPE(i) == SSD_TYPE_ZNS)
	zns_init_namespace(&ns[i], i, size, ns_addr, disp_no);
else if (NS_SSD_TYPE(i) == SSD_TYPE_KV)
	kv_init_namespace(&ns[i], i, size, ns_addr, disp_no);
```

For conventional mode, `conv_init_namespace()`:

- computes SSD geometry with `ssd_init_params()`
- creates `SSD_PARTITIONS` FTL instances
- creates one `struct ssd` per FTL partition
- shares PCIe and write-buffer state across partitions
- registers `conv_proc_nvme_io_cmd` as the namespace I/O handler
- exposes logical namespace size after over-provisioning

```c
ssd_init_params(&spp, size, nr_parts);
conv_init_params(&cpp);

for (i = 0; i < nr_parts; i++) {
	ssd = kmalloc(sizeof(struct ssd), GFP_KERNEL);
	ssd_init(ssd, &spp, cpu_nr_dispatcher);
	conv_init_ftl(&conv_ftls[i], &cpp, ssd);
}

ns->nr_parts = nr_parts;
ns->ftls = (void *)conv_ftls;
ns->size = (uint64_t)((size * 100) / cpp.pba_pcent);
ns->proc_io_cmd = conv_proc_nvme_io_cmd;
```

## Conventional FTL Model

The conventional FTL is page-mapped and log-structured.

Important properties:

- logical mapping unit is a 4 KiB page (`spp->pgsz`)
- `maptbl[lpn]` maps logical page number to physical page address
- `rmap[ppa]` maps physical page back to logical page
- writes never overwrite in place
- overwrites invalidate old pages and allocate fresh PPAs
- GC cleans victim lines and copies live pages elsewhere

### Physical Page Address

Defined in [`ssd.h`](ssd.h):

```c
struct ppa {
	union {
		struct {
			uint64_t pg  : PAGE_BITS;
			uint64_t blk : BLK_BITS;
			uint64_t pl  : PL_BITS;
			uint64_t lun : LUN_BITS;
			uint64_t ch  : CH_BITS;
			uint64_t rsv : RSB_BITS;
		} g;
		uint64_t ppa;
	};
};
```

The FTL uses `ppa.g.ch`, `ppa.g.lun`, `ppa.g.pl`, `ppa.g.blk`, and `ppa.g.pg` to find NAND state and timing resources.

### Logical-to-Physical Mapping

Core helpers from [`conv_ftl.c`](conv_ftl.c):

```c
static inline struct ppa get_maptbl_ent(struct conv_ftl *conv_ftl, uint64_t lpn)
{
	return conv_ftl->maptbl[lpn];
}

static inline void set_maptbl_ent(struct conv_ftl *conv_ftl, uint64_t lpn, struct ppa *ppa)
{
	NVMEV_ASSERT(lpn < conv_ftl->ssd->sp.tt_pgs);
	conv_ftl->maptbl[lpn] = *ppa;
}
```

Reverse mapping is used during GC:

```c
static inline uint64_t get_rmap_ent(struct conv_ftl *conv_ftl, struct ppa *ppa)
{
	uint64_t pgidx = ppa2pgidx(conv_ftl, ppa);
	return conv_ftl->rmap[pgidx];
}
```

### Lines

A line is a superblock-like unit. One line has the same block id across channels/LUNs.

`struct line` tracks:

- `id`: line id, also block id
- `ipc`: invalid page count
- `vpc`: valid page count
- `entry`: list node for free/full lists
- `pos`: priority queue position for victim selection

`struct line_mgmt` owns:

- `free_line_list`
- `full_line_list`
- `victim_line_pq`
- counters for each list

Victim priority is based on `vpc`; the line with fewer valid pages is better to clean.

```c
static inline pqueue_pri_t victim_line_get_pri(void *a)
{
	return ((struct line *)a)->vpc;
}
```

### Write Pointer

The FTL keeps two write pointers:

- `wp`: host/user writes
- `gc_wp`: GC relocation writes

```c
struct write_pointer {
	struct line *curline;
	uint32_t ch;
	uint32_t lun;
	uint32_t pg;
	uint32_t blk;
	uint32_t pl;
};
```

The allocation order is:

1. page within current oneshot page
2. channel
3. LUN
4. next wordline/page group
5. next line when the current line is full

The allocation snippet:

```c
static struct ppa get_new_page(struct conv_ftl *conv_ftl, uint32_t io_type)
{
	struct write_pointer *wp = __get_wp(conv_ftl, io_type);
	struct ppa ppa = { .ppa = 0 };

	ppa.g.ch = wp->ch;
	ppa.g.lun = wp->lun;
	ppa.g.pg = wp->pg;
	ppa.g.blk = wp->blk;
	ppa.g.pl = wp->pl;

	return ppa;
}
```

## Read Path

`conv_read()` does:

1. convert NVMe LBA range to FTL LPN range
2. select FTL partition by `lpn % ns->nr_parts`
3. look up PPA in `maptbl`
4. skip unmapped pages
5. aggregate adjacent mapped pages in the same flash page
6. call `ssd_advance_nand()` for timing
7. return the latest completion time

Simplified snippet:

```c
start_lpn = lba / spp->secs_per_pg;
end_lpn = (lba + nr_lba - 1) / spp->secs_per_pg;

for (lpn = start_lpn; lpn <= end_lpn; lpn += nr_parts) {
	local_lpn = lpn / nr_parts;
	cur_ppa = get_maptbl_ent(conv_ftl, local_lpn);
	if (!mapped_ppa(&cur_ppa) || !valid_ppa(conv_ftl, &cur_ppa))
		continue;

	srd.xfer_size = xfer_size;
	srd.ppa = &cur_ppa;
	nsecs_completed = ssd_advance_nand(conv_ftl->ssd, &srd);
	nsecs_latest = max(nsecs_completed, nsecs_latest);
}
```

Normal conventional mode uses `interleave_pci_dma = true` for reads, so modeled PCIe transfer can overlap with NAND channel transfer.

## InFLASH Compute Read Path

When `INFLASH_COMPUTE` is defined, reads are modified to model an on-device compute command.

The host can submit a tiny read, often one 4 KiB page. If `compute_sense_pages > 1`, a single-page read is expanded inside `conv_read()` to sense many LPNs device-side:

```c
if (start_lpn == end_lpn && compute_sense_pages > 1) {
	end_lpn = start_lpn + compute_sense_pages - 1;
	nr_lba = (end_lpn - start_lpn + 1) * spp->secs_per_pg;
}
```

For each sensed page, the FTL still walks the mapping table and charges NAND/channel time. But the modeled transfer size is only the small compute result:

```c
#if defined(INFLASH_COMPUTE)
	srd.xfer_size = COMPUTE_RESULT_SIZE;
#else
	srd.xfer_size = xfer_size;
#endif
```

The host-side data copy in `io.c` is also capped for reads:

```c
#if defined(INFLASH_COMPUTE)
if (cmd->opcode == nvme_cmd_read && length > COMPUTE_RESULT_SIZE)
	length = COMPUTE_RESULT_SIZE;
#endif
```

This intentionally separates:

- device-side sensing extent: `compute_sense_pages`
- host-side transfer: `COMPUTE_RESULT_SIZE`

Runtime examples:

```bash
# all-plane mode: one single-page read senses 512 pages/device planes
sudo insmod nvmev.ko memmap_start=96G memmap_size=16G cpus=7,8 compute_sense_pages=512

# single-plane mode: one single-page read senses one page/plane
sudo insmod nvmev.ko memmap_start=96G memmap_size=16G cpus=7,8 compute_sense_pages=1
```

`conv_read()` also emits a rate-limited device-latency message:

```text
NVMeVirt: inflash_dev_lat <N> ns (sensed <P> pages)
```

## Write Path

`conv_write()` does:

1. convert LBA range to LPN range
2. allocate space in the global write buffer
3. advance write-buffer and PCIe timing
4. for each LPN:
   - invalidate old mapped PPA if it exists
   - allocate fresh PPA
   - update `maptbl`
   - update `rmap`
   - mark new page valid
   - advance write pointer
5. issue NAND program when a full oneshot page is collected
6. release write-buffer space through an internal scheduled operation
7. complete early unless FUA or early completion is disabled

The core update looks like:

```c
ppa = get_maptbl_ent(conv_ftl, local_lpn);
if (mapped_ppa(&ppa)) {
	mark_page_invalid(conv_ftl, &ppa);
	set_rmap_ent(conv_ftl, INVALID_LPN, &ppa);
}

ppa = get_new_page(conv_ftl, USER_IO);
set_maptbl_ent(conv_ftl, local_lpn, &ppa);
set_rmap_ent(conv_ftl, local_lpn, &ppa);
mark_page_valid(conv_ftl, &ppa);
advance_write_pointer(conv_ftl, USER_IO);
```

The program operation is batched at oneshot-page granularity:

```c
if (last_pg_in_wordline(conv_ftl, &ppa)) {
	swr.ppa = &ppa;
	nsecs_completed = ssd_advance_nand(conv_ftl->ssd, &swr);
	nsecs_latest = max(nsecs_completed, nsecs_latest);

	schedule_internal_operation(req->sq_id, nsecs_completed, wbuf,
				    spp->pgs_per_oneshotpg * spp->pgsz);
}
```

Early completion:

```c
if ((cmd->rw.control & NVME_RW_FUA) || (spp->write_early_completion == 0))
	ret->nsecs_target = nsecs_latest;
else
	ret->nsecs_target = nsecs_xfer_completed;
```

## Garbage Collection

GC triggers through write credits:

```c
static inline void check_and_refill_write_credit(struct conv_ftl *conv_ftl)
{
	if (conv_ftl->wfc.write_credits <= 0) {
		foreground_gc(conv_ftl);
		conv_ftl->wfc.write_credits += conv_ftl->wfc.credits_to_refill;
	}
}
```

A victim line is selected from `victim_line_pq`. GC scans each flash page in the victim line, copies valid pages to `gc_wp`, updates mappings, erases old blocks, and returns the line to the free list:

```c
victim_line = select_victim_line(conv_ftl, force);
ppa.g.blk = victim_line->id;

for (flashpg = 0; flashpg < spp->flashpgs_per_blk; flashpg++) {
	ppa.g.pg = flashpg * spp->pgs_per_flashpg;
	for (ch = 0; ch < spp->nchs; ch++) {
		for (lun = 0; lun < spp->luns_per_ch; lun++) {
			ppa.g.ch = ch;
			ppa.g.lun = lun;
			clean_one_flashpg(conv_ftl, &ppa);
		}
	}
}

mark_line_free(conv_ftl, &ppa);
```

During live-page copy:

```c
lpn = get_rmap_ent(conv_ftl, old_ppa);
new_ppa = get_new_page(conv_ftl, GC_IO);
set_maptbl_ent(conv_ftl, lpn, &new_ppa);
set_rmap_ent(conv_ftl, lpn, &new_ppa);
mark_page_valid(conv_ftl, &new_ppa);
advance_write_pointer(conv_ftl, GC_IO);
```

## Timing Model

`ssd_advance_nand()` is the main NAND timing function.

For reads:

1. wait for the addressed LUN to become available
2. add NAND sensing latency
3. transfer data over the NAND channel with `chmodel_request()`
4. optionally overlap PCIe transfer
5. update `lun->next_lun_avail_time`

```c
nand_stime = max(lun->next_lun_avail_time, cmd_stime);
nand_etime = nand_stime + spp->pg_rd_lat[cell];
chnl_stime = nand_etime;

while (remaining) {
	xfer_size = min(remaining, (uint64_t)spp->max_ch_xfer_size);
	chnl_etime = chmodel_request(ch->perf_model, chnl_stime, xfer_size);
	remaining -= xfer_size;
	chnl_stime = chnl_etime;
}

lun->next_lun_avail_time = chnl_etime;
```

For writes:

1. transfer data over the NAND channel
2. add NAND program time
3. update LUN availability

```c
chnl_stime = max(lun->next_lun_avail_time, cmd_stime);
chnl_etime = chmodel_request(ch->perf_model, chnl_stime, ncmd->xfer_size);
nand_etime = chnl_etime + spp->pg_wr_lat;
lun->next_lun_avail_time = nand_etime;
```

The channel model is credit based. Each channel has a time ring with available transfer credits:

```c
struct channel_model {
	uint64_t cur_time;
	uint32_t head;
	uint32_t valid_len;
	uint32_t max_credits;
	uint32_t command_credits;
	uint32_t xfer_lat;
	credit_t avail_credits[NR_CREDIT_ENTRIES];
};
```

`chmodel_request()` consumes credits at `request_time` and returns the transfer completion time.

## Multi-Dispatcher Behavior in this Tree

This repository has local multi-dispatcher changes.

`nr_dispatchers` is a module parameter. The first `nr_dispatchers` CPUs in `cpus=` become dispatchers; remaining CPUs become I/O workers.

Example:

```bash
# 4 dispatcher threads on CPUs 7-10, 2 io_workers on CPUs 11-12
sudo insmod nvmev.ko memmap_start=96G memmap_size=16G \
  cpus=7,8,9,10,11,12 nr_dispatchers=4 compute_sense_pages=1
```

Queue ownership:

```c
if (((qid - 1) % nr_disp) != disp_id)
	continue;
```

Admin queue and BAR processing stay on dispatcher 0. I/O queues are partitioned across dispatchers.

This creates real concurrent calls into the SSD timing model. The tree therefore adds:

- `spinlock_t lock` in `struct nvmev_io_worker`
- `spinlock_t lock` in `struct ssd_channel`
- `/proc/nvmev/chstat` instrumentation

The channel lock protects shared timing state:

```c
if (!spin_trylock(&ch->lock)) {
	atomic64_inc(&chstat_contended[chs_ch]);
	spin_lock(&ch->lock);
}
...
spin_unlock(&ch->lock);
```

You can inspect/reset contention counters:

```bash
cat /proc/nvmev/chstat
echo 1 | sudo tee /proc/nvmev/chstat
```

## Important Structs

| Struct | File | Role |
| --- | --- | --- |
| `struct nvmev_dev` | [`nvmev.h`](nvmev.h) | Global virtual device: PCI, BARs, doorbells, queues, namespaces, workers, dispatchers |
| `struct nvmev_config` | [`nvmev.h`](nvmev.h) | Module parameters after parsing: memory map, CPU assignment, dispatcher count, latency knobs |
| `struct nvmev_dispatcher` | [`nvmev.h`](nvmev.h) | One dispatcher/controller-core thread |
| `struct nvmev_io_worker` | [`nvmev.h`](nvmev.h) | Completion/copy worker with sorted work queue |
| `struct nvmev_io_work` | [`nvmev.h`](nvmev.h) | One pending I/O or internal event scheduled by target time |
| `struct nvmev_ns` | [`nvmev.h`](nvmev.h) | Namespace object and backend callback table |
| `struct conv_ftl` | [`conv_ftl.h`](conv_ftl.h) | Conventional FTL state: SSD model, mapping tables, write pointers, line manager |
| `struct convparams` | [`conv_ftl.h`](conv_ftl.h) | Conventional FTL policy: OP ratio, GC thresholds, GC delay flag |
| `struct line` | [`conv_ftl.h`](conv_ftl.h) | Superblock/line metadata: valid and invalid page counts |
| `struct line_mgmt` | [`conv_ftl.h`](conv_ftl.h) | Free/full/victim line collections |
| `struct write_pointer` | [`conv_ftl.h`](conv_ftl.h) | Next physical allocation address for host writes or GC writes |
| `struct ppa` | [`ssd.h`](ssd.h) | Packed physical page address: channel, LUN, plane, block, page |
| `struct ssdparams` | [`ssd.h`](ssd.h) | Geometry and latency constants plus derived totals |
| `struct ssd` | [`ssd.h`](ssd.h) | Runtime SSD model: channels, PCIe model, write buffer |
| `struct ssd_channel` | [`ssd.h`](ssd.h) | NAND channel, LUN array, bandwidth model, channel lock |
| `struct nand_lun` | [`ssd.h`](ssd.h) | LUN/die state and next available time |
| `struct nand_block` | [`ssd.h`](ssd.h) | Block pages, valid/invalid counts, erase count |
| `struct nand_page` | [`ssd.h`](ssd.h) | Page state: free, valid, invalid |
| `struct nand_cmd` | [`ssd.h`](ssd.h) | Timing request passed into `ssd_advance_nand()` |
| `struct buffer` | [`ssd.h`](ssd.h) | Write-buffer capacity accounting |
| `struct channel_model` | [`channel_model.h`](channel_model.h) | Credit-ring bandwidth model for NAND channels and PCIe |

## File Map

| File | Conventional-mode purpose |
| --- | --- |
| [`Kbuild`](Kbuild) | Selects the active backend. Current tree enables `CONFIG_NVMEVIRT_INFLASH`. |
| [`ssd_config.h`](ssd_config.h) | Static SSD profiles: Samsung conventional SSD, InFLASH PIM, ZNS, KV, NVM. |
| [`main.c`](main.c) | Module parameters, memory mapping, namespace init, dispatcher threads, procfs. |
| [`pci.c`](pci.c), [`pci.h`](pci.h) | Virtual PCI bus/device, BAR registers, doorbells, MSI-X/INTx interrupt signaling. |
| [`admin.c`](admin.c) | NVMe admin commands: identify, features, queue create/delete, log pages. |
| [`io.c`](io.c) | SQ/CQ processing, PRP copy, DMA option, target-time scheduling, completion posting. |
| [`nvmev.h`](nvmev.h) | Core NVMeVirt structs and function declarations. |
| [`nvme.h`](nvme.h) | NVMe command, completion, opcode, status, identify structures. |
| [`conv_ftl.c`](conv_ftl.c), [`conv_ftl.h`](conv_ftl.h) | Conventional FTL: map table, reads, writes, GC, line management. |
| [`ssd.c`](ssd.c), [`ssd.h`](ssd.h) | NAND hierarchy, SSD geometry derivation, timing functions, write buffer, chstat. |
| [`channel_model.c`](channel_model.c), [`channel_model.h`](channel_model.h) | Credit-based transfer time model for NAND channel and PCIe links. |
| [`pqueue/pqueue.c`](pqueue/pqueue.c), [`pqueue/pqueue.h`](pqueue/pqueue.h) | Binary heap priority queue used for GC victim lines. |
| [`dma.c`](dma.c), [`dma.h`](dma.h) | Optional IOAT DMA copy path instead of CPU memcpy. |
| [`simple_ftl.c`](simple_ftl.c), [`simple_ftl.h`](simple_ftl.h) | NVM/Optane-style timing backend, not used for conventional mode. |
| [`zns_*.c`](zns_ftl.c), [`nvme_zns.h`](nvme_zns.h) | Zoned namespace backend, not used for conventional mode. |
| [`kv_ftl.c`](kv_ftl.c), [`kv_ftl.h`](kv_ftl.h), [`nvme_kv.h`](nvme_kv.h) | KVSSD backend, not used for conventional mode. |

## Practical Debugging Examples

Check which mode was built:

```bash
grep -n "CONFIG_NVMEVIRT" Kbuild
modinfo nvmev.ko | grep -E "nr_dispatchers|compute_sense_pages"
```

Load all-plane InFLASH mode:

```bash
sudo insmod ./nvmev.ko \
  memmap_start=96G \
  memmap_size=16G \
  cpus=7,8 \
  compute_sense_pages=512
```

Load single-plane mode with multiple dispatchers:

```bash
sudo insmod ./nvmev.ko \
  memmap_start=96G \
  memmap_size=16G \
  cpus=7,8,9,10,11,12 \
  nr_dispatchers=4 \
  compute_sense_pages=1
```

Observe queue and channel state:

```bash
cat /proc/nvmev/stat
cat /proc/nvmev/chstat
dmesg | grep inflash_dev_lat
```

Trace a logical page manually:

```c
uint64_t lba = cmd->rw.slba;
uint64_t lpn = lba / spp->secs_per_pg;
uint32_t part = lpn % ns->nr_parts;
uint64_t local_lpn = lpn / ns->nr_parts;
struct conv_ftl *ftl = &((struct conv_ftl *)ns->ftls)[part];
struct ppa ppa = ftl->maptbl[local_lpn];
```

Reason about line fullness:

```c
if (line->vpc == spp->pgs_per_line) {
	/* all pages still valid: full line */
} else if (line->ipc > 0) {
	/* has invalid pages: GC candidate */
}
```

## Common Pitfalls

- The active tree is not the upstream default NVM mode. `CONFIG_NVMEVIRT_INFLASH` is enabled in `Kbuild`.
- InFLASH still uses `SSD_TYPE_CONV`; it is not a separate namespace command set.
- Data bytes are copied by LBA offset in `io.c`; PPA affects timing and FTL state, not where bytes live in memory.
- A read of an unmapped LPN is silently skipped in the timing walk rather than materializing real media data.
- `compute_sense_pages` only expands a single-page host read. Multi-page reads keep their natural range.
- `COMPUTE_RESULT_SIZE` caps host read copy size only under `INFLASH_COMPUTE`.
- With `nr_dispatchers > 1`, shared channel timing state is protected by `ssd_channel.lock`; use `/proc/nvmev/chstat` to see contention.
- `__print_base_config()` currently has no explicit `INFLASH_PIM` case, so the startup banner may say `unknown` even though the build path is active.

