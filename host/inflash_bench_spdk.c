/*
 * inflash_bench_spdk.c — SPDK (kernel-bypass) INFLASH_PIM latency benchmark
 *
 * The SPDK counterpart to inflash_bench.c. It mirrors that bench's measurement
 * semantics exactly (same CSV columns, same e2e = first_submit -> last_completion
 * definition, same --compute / --requests / --qdepth / --trials / --prepopulate
 * semantics) but issues I/O through the SPDK userspace NVMe driver instead of the
 * Linux O_DIRECT / io_uring block path. That removes the three host-side costs the
 * io_uring path pays per I/O:
 *   - get_user_pages pin/unpin + PRP build  (SPDK buffers are pre-registered DMA hugepages)
 *   - io_uring_enter syscall                (SPDK rings the SQ doorbell via userspace MMIO)
 *   - IRQ -> softirq -> wakeup -> ctx switch (SPDK busy-polls the CQ)
 *
 * The in-flash-compute command shape is unchanged from the kernel bench: a
 * SINGLE-PAGE read (lba_count = secs_per_pg = 8 sectors = 4 KB). The device side
 * (conv_read, COMPUTE_SENSE_PAGES) expands the *sensing* extent to all 512 planes;
 * no NVMe command-field change is needed. Host pins exactly one page -> O(1).
 *
 * CSV output columns (superset of inflash_bench.c, with a host_stack tag):
 *   requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns,host_stack
 *
 * Build:  make -C host spdk      (see host/Makefile; needs SPDK installed)
 * Run  :  sudo <...>/inflash_bench_spdk --bdf 0001:10:00.0 --compute \
 *              --requests 1 --qdepth 1 --trials 15 --csv results_nvmevirt_spdk_raw.csv
 *
 * SPDK must own the device first: bind it to uio_pci_generic / vfio-pci via
 * spdk/scripts/setup.sh (see scripts/nvmevirt_spdk_exp.sh). Binding removes
 * /dev/nvme1n1; restore with setup.sh reset.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <getopt.h>
#include <pthread.h>
#include <sched.h>

#include "spdk/stdinc.h"
#include "spdk/env.h"
#include "spdk/nvme.h"
#include "spdk/string.h"

#undef  PAGE_SIZE                /* sys/user.h (via spdk/stdinc.h) also defines it */
#define PAGE_SIZE   4096U
#define NLUNS       512          /* 16 channels x 32 LUNs/ch — same as inflash_bench.c */

/* ------------------------------------------------------------------ */
/* Globals: SPDK handles + per-trial measurement state                  */
/* ------------------------------------------------------------------ */

static struct spdk_nvme_ctrlr *g_ctrlr;
static struct spdk_nvme_ns    *g_ns;
static struct spdk_nvme_transport_id g_trid = {};
static uint32_t g_secs_per_pg = 8;   /* 4096 / 512; recomputed from ns after attach */

/* run_trial state shared with the completion callback */
static struct timespec *g_sts;       /* [nreqs] submit timestamps */
static int64_t         *g_lat_ns;    /* [nreqs] per-request latency */
static int              g_reaped;    /* completions seen this trial */
static int              g_err;       /* completion error flag */

/* ------------------------------------------------------------------ */
/* Timing helpers (identical to inflash_bench.c for comparability)      */
/* ------------------------------------------------------------------ */

static inline int64_t ts_ns(const struct timespec *ts)
{
    return (int64_t)ts->tv_sec * 1000000000LL + (int64_t)ts->tv_nsec;
}

static int cmp_i64(const void *a, const void *b)
{
    int64_t ia = *(const int64_t *)a, ib = *(const int64_t *)b;
    return (ia > ib) - (ia < ib);
}

static int64_t pct(int64_t *sorted, int n, int p)
{
    if (n <= 0) return 0;
    int idx = (int)((double)p / 100.0 * (n - 1) + 0.5);
    if (idx < 0) idx = 0;
    if (idx >= n) idx = n - 1;
    return sorted[idx];
}

/* ------------------------------------------------------------------ */
/* SPDK probe / attach                                                  */
/* ------------------------------------------------------------------ */

static bool probe_cb(void *cb_ctx, const struct spdk_nvme_transport_id *trid,
                     struct spdk_nvme_ctrlr_opts *opts)
{
    (void)cb_ctx; (void)opts;
    fprintf(stderr, "[spdk] probe: attaching %s\n", trid->traddr);
    return true;   /* attach every controller the probe surfaces (we filter by trid) */
}

static void attach_cb(void *cb_ctx, const struct spdk_nvme_transport_id *trid,
                      struct spdk_nvme_ctrlr *ctrlr,
                      const struct spdk_nvme_ctrlr_opts *opts)
{
    (void)cb_ctx; (void)opts;
    fprintf(stderr, "[spdk] attached %s\n", trid->traddr);
    g_ctrlr = ctrlr;
}

/* ------------------------------------------------------------------ */
/* Completion callbacks                                                 */
/* ------------------------------------------------------------------ */

static void io_complete_cb(void *arg, const struct spdk_nvme_cpl *cpl)
{
    int idx = (int)(uintptr_t)arg;
    struct timespec tnow;
    clock_gettime(CLOCK_MONOTONIC, &tnow);

    if (spdk_nvme_cpl_is_error(cpl)) {
        fprintf(stderr, "  cqe[%d] error: sct=%d sc=%d\n",
                idx, cpl->status.sct, cpl->status.sc);
        g_err = 1;
    }
    g_lat_ns[idx] = ts_ns(&tnow) - ts_ns(&g_sts[idx]);
    g_reaped++;
}

struct sync_arg { volatile int done; volatile int err; };
static void sync_complete_cb(void *arg, const struct spdk_nvme_cpl *cpl)
{
    struct sync_arg *s = arg;
    if (spdk_nvme_cpl_is_error(cpl)) s->err = 1;
    s->done = 1;
}

/* ------------------------------------------------------------------ */
/* Prepopulate: sequential single-page writes over [0, max_pages)       */
/* (mandatory — cold LPNs read instantly and fabricate false convergence)*/
/* ------------------------------------------------------------------ */

static int prepopulate(struct spdk_nvme_qpair *qpair, long max_pages)
{
    void *buf = spdk_zmalloc(PAGE_SIZE, PAGE_SIZE, NULL,
                             SPDK_ENV_SOCKET_ID_ANY, SPDK_MALLOC_DMA);
    if (!buf) { fprintf(stderr, "[prepopulate] spdk_zmalloc failed\n"); return -1; }
    memset(buf, 0xAB, PAGE_SIZE);
    fprintf(stderr, "[prepopulate] writing %ld pages (%ld MiB) across %d LUNs...\n",
            max_pages, max_pages * (long)PAGE_SIZE / (1024 * 1024), NLUNS);

    for (long lpn = 0; lpn < max_pages; lpn++) {
        struct sync_arg s = { 0, 0 };
        int rc = spdk_nvme_ns_cmd_write(g_ns, qpair, buf,
                                        (uint64_t)lpn * g_secs_per_pg, g_secs_per_pg,
                                        sync_complete_cb, &s, 0);
        if (rc != 0) { fprintf(stderr, "[prepopulate] submit lpn=%ld rc=%d\n", lpn, rc);
                       spdk_free(buf); return -1; }
        while (!s.done) spdk_nvme_qpair_process_completions(qpair, 0);
        if (s.err) { fprintf(stderr, "[prepopulate] write error lpn=%ld\n", lpn);
                     spdk_free(buf); return -1; }
        if (lpn > 0 && (lpn % 512) == 0)
            fprintf(stderr, "  [prepopulate] %ld / %ld pages\n", lpn, max_pages);
    }
    spdk_free(buf);
    fprintf(stderr, "[prepopulate] done.\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Trial execution — mirrors inflash_bench.c run_trial loop, polled      */
/* ------------------------------------------------------------------ */

static int run_trial(struct spdk_nvme_qpair *qpair, int nreqs, int qdepth,
                     const long *lpns, void **bufs, int K,
                     int64_t *lat_ns, int64_t *e2e_ns)
{
    g_sts    = calloc(nreqs, sizeof(*g_sts));
    if (!g_sts) { perror("calloc"); return -1; }
    g_lat_ns = lat_ns;
    g_reaped = 0;
    g_err    = 0;
    memset(lat_ns, 0, (size_t)nreqs * sizeof(*lat_ns));

    int sub = 0, inflight = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    while (g_reaped < nreqs) {
        /* Submit up to qdepth outstanding single-(K-)page reads */
        while (inflight < qdepth && sub < nreqs) {
            clock_gettime(CLOCK_MONOTONIC, &g_sts[sub]);
            int rc = spdk_nvme_ns_cmd_read(g_ns, qpair, bufs[sub],
                                           (uint64_t)lpns[sub] * g_secs_per_pg,
                                           (uint32_t)K * g_secs_per_pg,
                                           io_complete_cb, (void *)(uintptr_t)sub, 0);
            if (rc == -ENOMEM) break;                 /* SQ full: drain then retry */
            if (rc != 0) { fprintf(stderr, "submit rc=%d\n", rc); free(g_sts); return -1; }
            sub++; inflight++;
        }
        /* Busy-poll the CQ (no IRQ, no syscall) */
        int done_before = g_reaped;
        spdk_nvme_qpair_process_completions(qpair, 0);
        inflight -= (g_reaped - done_before);
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    *e2e_ns = ts_ns(&t1) - ts_ns(&t0);
    free(g_sts); g_sts = NULL;
    return g_err ? -1 : 0;
}

/* ------------------------------------------------------------------ */
/* Multi-threaded host path (--threads T): T pthreads, each pinned to a  */
/* distinct E-core, each owning its own SPDK qpair. The request set is    */
/* split across threads. Aggregate e2e = earliest submit (any thread) ->  */
/* latest completion (any thread). This scales the HOST submit/reap path   */
/* so the single-core poll loop is not mistaken for the device's          */
/* dispatcher (controller-core) limit. See Task C / D3.                    */
/* ------------------------------------------------------------------ */

struct cb_arg;

struct worker {
    int id;
    int core;                       /* CPU to pin this worker's pthread to */
    struct spdk_nvme_qpair *qpair;  /* thread-private qpair */
    int nreqs;                      /* requests assigned to this worker */
    int qdepth;                     /* per-worker outstanding before polling */
    int K;                          /* pages per request */
    const long *lpns;               /* [nreqs] slice of the global lpn array */
    void **bufs;                    /* [nreqs] slice of the global buffer array */
    struct timespec *sts;           /* [nreqs] submit timestamps (worker-private) */
    int64_t *lat_ns;                /* [nreqs] slice of the global latency array */
    struct cb_arg *cbs;             /* [nreqs] completion callback args */
    int reaped;
    int err;
    int64_t first_submit_ns;        /* earliest submit seen by this worker */
    int64_t last_done_ns;           /* latest completion seen by this worker */
    pthread_t thr;
};

struct cb_arg { struct worker *w; int idx; };

static void io_complete_mt(void *arg, const struct spdk_nvme_cpl *cpl)
{
    struct cb_arg *c = arg;
    struct worker *w = c->w;
    struct timespec tnow;
    clock_gettime(CLOCK_MONOTONIC, &tnow);
    int64_t now = ts_ns(&tnow);

    if (spdk_nvme_cpl_is_error(cpl)) {
        fprintf(stderr, "  [w%d] cqe[%d] error: sct=%d sc=%d\n",
                w->id, c->idx, cpl->status.sct, cpl->status.sc);
        w->err = 1;
    }
    w->lat_ns[c->idx] = now - ts_ns(&w->sts[c->idx]);
    if (now > w->last_done_ns) w->last_done_ns = now;
    w->reaped++;
}

static void *worker_main(void *arg)
{
    struct worker *w = arg;
    int sub = 0, inflight = 0;

    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(w->core, &set);
    if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0)
        fprintf(stderr, "  [w%d] warning: pin to core %d failed\n", w->id, w->core);

    w->reaped = 0;
    w->err = 0;
    w->last_done_ns = 0;
    w->first_submit_ns = 0;

    while (w->reaped < w->nreqs) {
        while (inflight < w->qdepth && sub < w->nreqs) {
            struct timespec ts;
            clock_gettime(CLOCK_MONOTONIC, &ts);
            w->sts[sub] = ts;
            if (sub == 0)
                w->first_submit_ns = ts_ns(&ts);
            int rc = spdk_nvme_ns_cmd_read(g_ns, w->qpair, w->bufs[sub],
                                           (uint64_t)w->lpns[sub] * g_secs_per_pg,
                                           (uint32_t)w->K * g_secs_per_pg,
                                           io_complete_mt, &w->cbs[sub], 0);
            if (rc == -ENOMEM) break;             /* SQ full: drain then retry */
            if (rc != 0) { fprintf(stderr, "  [w%d] submit rc=%d\n", w->id, rc);
                           w->err = 1; return NULL; }
            sub++; inflight++;
        }
        int before = w->reaped;
        spdk_nvme_qpair_process_completions(w->qpair, 0);
        inflight -= (w->reaped - before);
    }
    return NULL;
}

/* Run one trial across T workers. lpns/bufs/lat are global arrays of size
 * nreqs; each worker owns a contiguous slice. Returns 0 on success. */
static int run_trial_mt(struct worker *workers, int nthreads, int nreqs,
                        const long *lpns, void **bufs, int64_t *lat,
                        struct timespec *sts_global, int64_t *e2e_ns)
{
    int t;
    memset(lat, 0, (size_t)nreqs * sizeof(*lat));

    /* (re)assign per-trial slices and reset counters */
    int base = 0;
    for (t = 0; t < nthreads; t++) {
        struct worker *w = &workers[t];
        w->lpns = &lpns[base];
        w->bufs = &bufs[base];
        w->lat_ns = &lat[base];
        w->sts = &sts_global[base];
        base += w->nreqs;
    }

    for (t = 0; t < nthreads; t++)
        pthread_create(&workers[t].thr, NULL, worker_main, &workers[t]);

    int err = 0;
    int64_t first_submit = INT64_MAX, last_done = 0;
    for (t = 0; t < nthreads; t++) {
        pthread_join(workers[t].thr, NULL);
        err |= workers[t].err;
        if (workers[t].first_submit_ns && workers[t].first_submit_ns < first_submit)
            first_submit = workers[t].first_submit_ns;
        if (workers[t].last_done_ns > last_done)
            last_done = workers[t].last_done_ns;
    }

    *e2e_ns = (last_done > first_submit) ? (last_done - first_submit) : 0;
    return err ? -1 : 0;
}

/* ------------------------------------------------------------------ */
/* usage                                                                */
/* ------------------------------------------------------------------ */

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s --bdf <PCI BDF> [OPTIONS]\n\n"
        "SPDK (kernel-bypass) INFLASH_PIM latency benchmark. Mirrors inflash_bench.c.\n\n"
        "Options:\n"
        "  --bdf BDF         NVMeVirt PCI address, e.g. 0001:10:00.0   [required]\n"
        "  --requests N      Reads per trial                           [default: 1]\n"
        "  --qdepth Q        Outstanding reads before polling          [default: N]\n"
        "  --trials T        Measurement trials                        [default: 15]\n"
        "  --csv PATH        Append CSV rows to PATH                   [default: stdout]\n"
        "  --prepopulate     Sequentially write LPNs [0, maxpages) first\n"
        "  --maxpages M      LPN range for prepopulate                 [default: 4096]\n"
        "  --pages-per-req K Pages per request (K>=1)                  [default: 1]\n"
        "  --compute         In-flash-compute shape: force K=1 (host pins ONE page);\n"
        "                    device senses all planes internally (COMPUTE_SENSE_PAGES).\n"
        "  --threads T       Host threads, each its own qpair on a distinct core [default: 1]\n"
        "                    Requests are split across threads; e2e = first submit\n"
        "                    (any thread) -> last completion (any thread). T=1 = legacy path.\n"
        "  --basecore C      First CPU to pin worker threads (then C+1, C+2, ...) [default: 16]\n"
        "  --chan-affine     §15: route worker t to channels {c: c%%threads==t} only\n"
        "                    (each per-channel ch->lock single-owner; needs --threads>1).\n"
        "                    Default (no flag) = spread (each worker touches all channels).\n"
        "  --planes P        Experiment B alias: --threads P --requests P --chan-affine\n"
        "                    (one channel-affine plane per dispatcher).\n\n"
        "CSV columns: requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns,host_stack\n"
        "host_stack is always 'spdk'. Primary metric: t_endtoend_ns (first submit -> last completion).\n",
        prog);
}

/* ------------------------------------------------------------------ */
/* main                                                                 */
/* ------------------------------------------------------------------ */

int main(int argc, char *argv[])
{
    const char *bdf = NULL, *csv_path = NULL;
    const char *coremask = "0x10000";   /* single E-core (CPU 16) by default */
    int nreqs = 1, qdepth = -1, trials = 15;
    int do_prepop = 0; long max_pages = 4096;
    int K = 1, compute = 0;
    int nthreads = 1, basecore = 16;
    int chan_affine = 0;            /* §15: route each thread to its own channel set */
    int planes = 0;                 /* --planes P alias for --threads P --requests P */

    enum { OPT_BDF = 256, OPT_REQ, OPT_QD, OPT_TRIALS, OPT_CSV,
           OPT_PREPOP, OPT_MAXPAGES, OPT_PPR, OPT_COMPUTE, OPT_COREMASK,
           OPT_THREADS, OPT_BASECORE, OPT_CHANAFFINE, OPT_PLANES, OPT_HELP };
    static const struct option lo[] = {
        {"bdf",          required_argument, 0, OPT_BDF},
        {"requests",     required_argument, 0, OPT_REQ},
        {"qdepth",       required_argument, 0, OPT_QD},
        {"trials",       required_argument, 0, OPT_TRIALS},
        {"csv",          required_argument, 0, OPT_CSV},
        {"prepopulate",  no_argument,       0, OPT_PREPOP},
        {"maxpages",     required_argument, 0, OPT_MAXPAGES},
        {"pages-per-req",required_argument, 0, OPT_PPR},
        {"compute",      no_argument,       0, OPT_COMPUTE},
        {"coremask",     required_argument, 0, OPT_COREMASK},
        {"threads",      required_argument, 0, OPT_THREADS},
        {"qpairs",       required_argument, 0, OPT_THREADS}, /* alias: one qpair per thread */
        {"basecore",     required_argument, 0, OPT_BASECORE},
        {"chan-affine",  no_argument,       0, OPT_CHANAFFINE},
        {"planes",       required_argument, 0, OPT_PLANES},
        {"help",         no_argument,       0, OPT_HELP},
        {0,0,0,0}
    };
    int opt;
    /* "+" stops at the first non-option so an SPDK-style "-m <mask>" is tolerated */
    while ((opt = getopt_long(argc, argv, "+hm:", lo, NULL)) != -1) {
        switch (opt) {
        case OPT_BDF:      bdf = optarg; break;
        case OPT_REQ:      nreqs = atoi(optarg); break;
        case OPT_QD:       qdepth = atoi(optarg); break;
        case OPT_TRIALS:   trials = atoi(optarg); break;
        case OPT_CSV:      csv_path = optarg; break;
        case OPT_PREPOP:   do_prepop = 1; break;
        case OPT_MAXPAGES: max_pages = atol(optarg); break;
        case OPT_PPR:      K = atoi(optarg); break;
        case OPT_COMPUTE:  compute = 1; break;
        case OPT_THREADS:  nthreads = atoi(optarg); break;
        case OPT_BASECORE: basecore = atoi(optarg); break;
        case OPT_CHANAFFINE: chan_affine = 1; break;
        case OPT_PLANES:   planes = atoi(optarg); break;
        case 'm': case OPT_COREMASK: coremask = optarg; break;
        case 'h': case OPT_HELP: usage(argv[0]); return 0;
        default: usage(argv[0]); return 1;
        }
    }
    if (!bdf) { fprintf(stderr, "Error: --bdf is required\n\n"); usage(argv[0]); return 1; }

    /* --planes P (Experiment B convenience): one channel-affine plane per
     * dispatcher => P host threads, P single-page requests, channel-affine on. */
    if (planes > 0) {
        nthreads = planes;
        nreqs = planes;
        chan_affine = 1;
        fprintf(stderr, "[bench] --planes %d: threads=%d requests=%d chan-affine=1\n",
                planes, nthreads, nreqs);
    }
    if (nthreads < 1) nthreads = 1;

    if (compute) { K = 1;
        fprintf(stderr, "[bench] --compute: 1-page host reads, device senses all planes internally\n"); }
    if (K < 1) K = 1;
    if (qdepth <= 0) qdepth = nreqs;
    if (qdepth < 1)  qdepth = 1;

    /* ---- SPDK env init: hugepages + (E-core) shm. Core mask is passed by the
     *      harness via the SPDK -m / --main-core env opts on the command line. ---- */
    struct spdk_env_opts opts;
    opts.opts_size = sizeof(opts);
    spdk_env_opts_init(&opts);
    opts.name = "inflash_bench_spdk";
    opts.core_mask = coremask;   /* pin DPDK EAL to E-core(s), disjoint from cpus=7,8 */
    fprintf(stderr, "[spdk] env core_mask=%s\n", coremask);
    if (spdk_env_init(&opts) < 0) {
        fprintf(stderr, "spdk_env_init failed\n");
        return 1;
    }

    spdk_nvme_trid_populate_transport(&g_trid, SPDK_NVME_TRANSPORT_PCIE);
    snprintf(g_trid.traddr, sizeof(g_trid.traddr), "%s", bdf);

    fprintf(stderr, "[spdk] probing %s ...\n", bdf);
    if (spdk_nvme_probe(&g_trid, NULL, probe_cb, attach_cb, NULL) != 0 || !g_ctrlr) {
        fprintf(stderr, "spdk_nvme_probe failed / no controller attached for %s\n", bdf);
        return 1;
    }

    /* namespace 1 */
    g_ns = spdk_nvme_ctrlr_get_ns(g_ctrlr, 1);
    if (!g_ns || !spdk_nvme_ns_is_active(g_ns)) {
        fprintf(stderr, "namespace 1 not active\n");
        return 1;
    }
    uint32_t sector = spdk_nvme_ns_get_sector_size(g_ns);
    g_secs_per_pg = PAGE_SIZE / sector;
    fprintf(stderr, "[spdk] ns1: sector=%u B, secs_per_pg=%u, size=%lu sectors\n",
            sector, g_secs_per_pg, (unsigned long)spdk_nvme_ns_get_num_sectors(g_ns));

    struct spdk_nvme_qpair *qpair =
        spdk_nvme_ctrlr_alloc_io_qpair(g_ctrlr, NULL, 0);
    if (!qpair) { fprintf(stderr, "alloc_io_qpair failed\n"); return 1; }

    if (do_prepop && prepopulate(qpair, max_pages) < 0) return 1;

    /* LPN array + pre-registered DMA buffers (allocated ONCE — no per-I/O pinning) */
    long *lpns = malloc((size_t)nreqs * sizeof(*lpns));
    void **bufs = calloc(nreqs, sizeof(*bufs));
    int64_t *lat = malloc((size_t)nreqs * sizeof(*lat));
    int64_t *lat_sorted = malloc((size_t)nreqs * sizeof(*lat_sorted));
    if (!lpns || !bufs || !lat || !lat_sorted) { perror("malloc"); return 1; }
    for (int i = 0; i < nreqs; i++) {
        lpns[i] = (long)i * K;   /* tile distinct K-page ranges, same as inflash_bench.c */
        bufs[i] = spdk_zmalloc((size_t)K * PAGE_SIZE, PAGE_SIZE, NULL,
                               SPDK_ENV_SOCKET_ID_ANY, SPDK_MALLOC_DMA);
        if (!bufs[i]) { fprintf(stderr, "spdk_zmalloc buf[%d] failed\n", i); return 1; }
    }

    /* ---- Multi-threaded host path setup (--threads T): one qpair/core per worker ---- */
    if (nthreads > nreqs) nthreads = nreqs;   /* no empty workers */

    /*
     * §15 channel-affine routing: reorder lpns[] so worker t's contiguous slice
     * holds exactly the logical indices == t (mod nthreads). Since LPN i lands on
     * physical channel (i*K) % 16 and the worker count divides 16 in our sweeps,
     * worker t then only ever touches channels {c : c % nthreads == t} — its SQ ->
     * dispatcher t -> a disjoint channel set, so each per-channel ch->lock has a
     * single owning dispatcher (zero cross-dispatcher contention). The union over
     * all workers still covers every plane once per 512-set, so the amortized
     * µs/512-set stays comparable to the §14 spread layout. Default (no flag)
     * keeps the §14 contiguous "spread" slices (each worker touches all channels).
     */
    if (chan_affine && nthreads > 1) {
        int rem = nreqs % nthreads;
        int base = 0;
        for (int t = 0; t < nthreads; t++) {
            int cnt = nreqs / nthreads + (t < rem ? 1 : 0);
            for (int k = 0; k < cnt; k++)
                lpns[base + k] = (long)(t + k * nthreads) * K;
            base += cnt;
        }
        fprintf(stderr, "[bench] --chan-affine: worker t -> logical idx == t (mod %d); "
                "channels {c: c%%%d==t}; each ch->lock single-owner\n",
                nthreads, nthreads);
    }

    struct worker *workers = NULL;
    struct timespec *sts_global = NULL;
    char host_stack[32];
    if (nthreads > 1) {
        workers = calloc(nthreads, sizeof(*workers));
        sts_global = calloc(nreqs, sizeof(*sts_global));
        if (!workers || !sts_global) { perror("calloc workers"); return 1; }
        int per_q = qdepth / nthreads; if (per_q < 1) per_q = 1;
        int rem = nreqs % nthreads;
        for (int t = 0; t < nthreads; t++) {
            struct worker *w = &workers[t];
            w->id = t;
            w->core = basecore + t;
            w->K = K;
            w->qdepth = per_q;
            w->nreqs = nreqs / nthreads + (t < rem ? 1 : 0);
            w->qpair = spdk_nvme_ctrlr_alloc_io_qpair(g_ctrlr, NULL, 0);
            if (!w->qpair) { fprintf(stderr, "alloc_io_qpair[w%d] failed\n", t); return 1; }
            w->cbs = calloc(w->nreqs, sizeof(*w->cbs));
            if (!w->cbs) { perror("calloc cbs"); return 1; }
            for (int i = 0; i < w->nreqs; i++) { w->cbs[i].w = w; w->cbs[i].idx = i; }
        }
        snprintf(host_stack, sizeof(host_stack), "spdk-t%d%s", nthreads,
                 chan_affine ? "-affine" : "");
        fprintf(stderr, "[bench] multi-thread: %d workers, per-worker qdepth=%d, cores %d..%d\n",
                nthreads, per_q, basecore, basecore + nthreads - 1);
    } else {
        snprintf(host_stack, sizeof(host_stack), "spdk");
    }

    /* CSV */
    FILE *csv = stdout; int is_stdout = 1;
    if (csv_path) {
        csv = fopen(csv_path, "a+");
        if (!csv) { perror("fopen csv"); return 1; }
        is_stdout = 0;
        fseek(csv, 0, SEEK_END);
        if (ftell(csv) == 0)
            fprintf(csv, "requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns,host_stack\n");
    } else {
        fprintf(csv, "requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns,host_stack\n");
    }

    fprintf(stderr, "[bench] bdf=%s requests=%d qdepth=%d trials=%d pages_per_req=%d compute=%d threads=%d\n",
            bdf, nreqs, qdepth, trials, K, compute, nthreads);

    for (int tr = 0; tr < trials; tr++) {
        int64_t e2e = 0;
        int rc = (nthreads > 1)
            ? run_trial_mt(workers, nthreads, nreqs, lpns, bufs, lat, sts_global, &e2e)
            : run_trial(qpair, nreqs, qdepth, lpns, bufs, K, lat, &e2e);
        if (rc < 0) {
            fprintf(stderr, "[bench] trial %d FAILED\n", tr);
            if (!is_stdout) fclose(csv);
            return 1;
        }
        memcpy(lat_sorted, lat, (size_t)nreqs * sizeof(*lat));
        qsort(lat_sorted, (size_t)nreqs, sizeof(*lat_sorted), cmp_i64);
        int64_t p50 = pct(lat_sorted, nreqs, 50);
        int64_t p99 = pct(lat_sorted, nreqs, 99);
        fprintf(csv, "%d,%d,%d,%ld,%ld,%ld,%s\n",
                nreqs, qdepth, tr, (long)e2e, (long)p50, (long)p99, host_stack);
        fflush(csv);
        fprintf(stderr, "  trial %3d:  e2e=%7ld us   p50=%7ld us   p99=%7ld us\n",
                tr, (long)(e2e/1000), (long)(p50/1000), (long)(p99/1000));
    }

    if (!is_stdout) fclose(csv);
    for (int i = 0; i < nreqs; i++) spdk_free(bufs[i]);
    free(lpns); free(bufs); free(lat); free(lat_sorted);
    if (workers) {
        for (int t = 0; t < nthreads; t++) {
            spdk_nvme_ctrlr_free_io_qpair(workers[t].qpair);
            free(workers[t].cbs);
        }
        free(workers); free(sts_global);
    }
    spdk_nvme_ctrlr_free_io_qpair(qpair);

    struct spdk_nvme_detach_ctx *dctx = NULL;
    spdk_nvme_detach_async(g_ctrlr, &dctx);
    if (dctx) while (spdk_nvme_detach_poll_async(dctx) == -EAGAIN) ;
    spdk_env_fini();
    return 0;
}
