/*
 * inflash_bench.c — liburing-based INFLASH_PIM latency benchmark
 *
 * Primary build (preferred):
 *   cc -O2 inflash_bench.c -luring -o inflash_bench
 *   Requires: sudo apt install liburing-dev
 *
 * Fallback build (libaio):
 *   cc -O2 -DUSE_LIBAIO inflash_bench.c -laio -o inflash_bench_libaio
 *   Requires: sudo apt install libaio-dev
 *
 * CSV output columns:
 *   requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns
 *
 * Under round-robin striping across 512 LUNs (16 ch × 32 LUNs/ch),
 * LPN k maps to LUN (k % 512). So LPN 0 and LPN 512 hit the same LUN —
 * used by --samelun to test serialized same-LUN latency (~2×tR).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <sched.h>
#include <getopt.h>

#ifdef USE_LIBAIO
#  include <libaio.h>
#else
#  include <liburing.h>
#endif

#define PAGE_SIZE   4096U
#define NLUNS       512          /* 16 channels × 32 LUNs/ch */

/* File-scope reqsize — set from --reqsize / --pages-per-req before run_trial */
static unsigned g_reqsize = PAGE_SIZE;

/* ------------------------------------------------------------------ */
/* Timing helpers                                                       */
/* ------------------------------------------------------------------ */

static inline int64_t ts_ns(const struct timespec *ts)
{
    return (int64_t)ts->tv_sec * 1000000000LL + (int64_t)ts->tv_nsec;
}

static int cmp_i64(const void *a, const void *b)
{
    int64_t ia = *(const int64_t *)a;
    int64_t ib = *(const int64_t *)b;
    return (ia > ib) - (ia < ib);
}

/* p = 0..100 */
static int64_t pct(int64_t *sorted, int n, int p)
{
    if (n <= 0) return 0;
    int idx = (int)((double)p / 100.0 * (n - 1) + 0.5);
    if (idx < 0) idx = 0;
    if (idx >= n) idx = n - 1;
    return sorted[idx];
}

/* ------------------------------------------------------------------ */
/* Prepopulate: sequential pwrite to populate maptbl                   */
/* ------------------------------------------------------------------ */

static int prepopulate(int fd, long max_pages)
{
    void *buf;
    if (posix_memalign(&buf, PAGE_SIZE, PAGE_SIZE) != 0) {
        perror("posix_memalign(prepopulate)");
        return -1;
    }
    memset(buf, 0xAB, PAGE_SIZE);
    fprintf(stderr, "[prepopulate] writing %ld pages (%ld MiB) "
            "to stripe across all %d LUNs...\n",
            max_pages, max_pages * (long)PAGE_SIZE / (1024 * 1024), NLUNS);

    for (long lpn = 0; lpn < max_pages; lpn++) {
        ssize_t r = pwrite(fd, buf, PAGE_SIZE, (off_t)lpn * PAGE_SIZE);
        if (r != (ssize_t)PAGE_SIZE) {
            fprintf(stderr, "[prepopulate] pwrite lpn=%ld: %s\n",
                    lpn, strerror(errno));
            free(buf);
            return -1;
        }
        if (lpn > 0 && (lpn % 512) == 0)
            fprintf(stderr, "  [prepopulate] %ld / %ld pages\n",
                    lpn, max_pages);
    }
    fsync(fd);
    free(buf);
    fprintf(stderr, "[prepopulate] done.\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Trial execution                                                      */
/* ------------------------------------------------------------------ */

#ifdef USE_LIBAIO
/* ---------- libaio fallback ---------- */

static int run_trial(int fd, int nreqs, int qdepth,
                     const long *lpns,
                     int64_t *lat_ns,   /* [nreqs]: per-request latency */
                     int64_t *e2e_ns)   /* batch end-to-end             */
{
    io_context_t     ctx  = {0};
    struct iocb    **cbs  = NULL;
    struct io_event *evs  = NULL;
    void           **bufs = NULL;
    struct timespec *sts  = NULL;
    int ret = 0;

    if (io_setup(qdepth, &ctx) < 0) {
        perror("io_setup");
        return -1;
    }

    cbs  = calloc(nreqs, sizeof(*cbs));
    evs  = calloc(nreqs, sizeof(*evs));
    bufs = calloc(nreqs, sizeof(*bufs));
    sts  = calloc(nreqs, sizeof(*sts));
    if (!cbs || !evs || !bufs || !sts) {
        perror("calloc");
        ret = -1;
        goto cleanup;
    }

    for (int i = 0; i < nreqs; i++) {
        if (posix_memalign(&bufs[i], PAGE_SIZE, g_reqsize) != 0) {
            perror("posix_memalign");
            ret = -1;
            goto cleanup;
        }
        cbs[i] = calloc(1, sizeof(struct iocb));
        if (!cbs[i]) {
            perror("calloc(iocb)");
            ret = -1;
            goto cleanup;
        }
        io_prep_pread(cbs[i], fd, bufs[i], g_reqsize,
                      (off_t)lpns[i] * PAGE_SIZE);
        cbs[i]->data = (void *)(uintptr_t)i;
    }

    int sub = 0, reaped = 0, inflight = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    while (reaped < nreqs) {
        /* Submit up to qdepth at once */
        while (inflight < qdepth && sub < nreqs) {
            int batch = qdepth - inflight;
            if (batch > nreqs - sub) batch = nreqs - sub;
            /* Stamp submit times */
            for (int i = sub; i < sub + batch; i++)
                clock_gettime(CLOCK_MONOTONIC, &sts[i]);
            int r = io_submit(ctx, batch, &cbs[sub]);
            if (r < 0) {
                errno = -r;
                perror("io_submit");
                ret = -1;
                goto cleanup;
            }
            inflight += r;
            sub      += r;
        }

        /* Reap at least 1 */
        int r = io_getevents(ctx, 1, inflight, evs, NULL);
        if (r < 0) {
            errno = -r;
            perror("io_getevents");
            ret = -1;
            goto cleanup;
        }
        struct timespec tnow;
        clock_gettime(CLOCK_MONOTONIC, &tnow);
        for (int i = 0; i < r; i++) {
            int idx = (int)(uintptr_t)evs[i].data;
            lat_ns[idx] = ts_ns(&tnow) - ts_ns(&sts[idx]);
        }
        inflight -= r;
        reaped   += r;
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    *e2e_ns = ts_ns(&t1) - ts_ns(&t0);

cleanup:
    for (int i = 0; i < nreqs; i++) {
        if (bufs && bufs[i]) free(bufs[i]);
        if (cbs  && cbs[i])  free(cbs[i]);
    }
    free(cbs); free(evs); free(bufs); free(sts);
    io_destroy(ctx);
    return ret;
}

#else  /* USE_LIBAIO not defined — use liburing */
/* ---------- liburing (preferred) ---------- */

static int run_trial(int fd, int nreqs, int qdepth,
                     const long *lpns,
                     int64_t *lat_ns,
                     int64_t *e2e_ns)
{
    struct io_uring  ring;
    void           **bufs = NULL;
    struct timespec *sts  = NULL;
    int ret = 0;

    ret = io_uring_queue_init((unsigned)qdepth, &ring, 0);
    if (ret < 0) {
        fprintf(stderr, "io_uring_queue_init: %s\n", strerror(-ret));
        return -1;
    }
    ret = 0;

    bufs = calloc(nreqs, sizeof(*bufs));
    sts  = calloc(nreqs, sizeof(*sts));
    if (!bufs || !sts) {
        perror("calloc");
        ret = -1;
        goto cleanup;
    }

    for (int i = 0; i < nreqs; i++) {
        if (posix_memalign(&bufs[i], PAGE_SIZE, g_reqsize) != 0) {
            perror("posix_memalign");
            ret = -1;
            goto cleanup;
        }
    }

    int sub = 0, reaped = 0, inflight = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    while (reaped < nreqs) {
        /* Fill SQ ring up to qdepth */
        int queued = 0;
        while (inflight < qdepth && sub < nreqs) {
            struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
            if (!sqe) break;
            clock_gettime(CLOCK_MONOTONIC, &sts[sub]);
            io_uring_prep_read(sqe, fd, bufs[sub], g_reqsize,
                               (uint64_t)lpns[sub] * PAGE_SIZE);
            io_uring_sqe_set_data(sqe, (void *)(uintptr_t)sub);
            sub++;
            inflight++;
            queued++;
        }

        if (queued > 0) {
            int r = io_uring_submit(&ring);
            if (r < 0) {
                fprintf(stderr, "io_uring_submit: %s\n", strerror(-r));
                ret = -1;
                goto cleanup;
            }
        }

        /* Wait for at least one completion */
        struct io_uring_cqe *cqe;
        int r = io_uring_wait_cqe(&ring, &cqe);
        if (r < 0) {
            fprintf(stderr, "io_uring_wait_cqe: %s\n", strerror(-r));
            ret = -1;
            goto cleanup;
        }

        /* Drain all ready CQEs atomically */
        struct timespec tnow;
        clock_gettime(CLOCK_MONOTONIC, &tnow);

        unsigned head;
        int cnt = 0;
        io_uring_for_each_cqe(&ring, head, cqe) {
            int idx = (int)(uintptr_t)io_uring_cqe_get_data(cqe);
            if (cqe->res < 0)
                fprintf(stderr, "  cqe[%d] error: %s\n",
                        idx, strerror(-cqe->res));
            lat_ns[idx] = ts_ns(&tnow) - ts_ns(&sts[idx]);
            cnt++;
        }
        io_uring_cq_advance(&ring, cnt);
        inflight -= cnt;
        reaped   += cnt;
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    *e2e_ns = ts_ns(&t1) - ts_ns(&t0);

cleanup:
    if (bufs) {
        for (int i = 0; i < nreqs; i++)
            if (bufs[i]) free(bufs[i]);
    }
    free(bufs);
    free(sts);
    io_uring_queue_exit(&ring);
    return ret;
}

#endif /* USE_LIBAIO */

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [OPTIONS]\n"
        "\n"
        "INFLASH_PIM latency benchmark — issues multi-page reads via O_DIRECT.\n"
        "\n"
        "Options:\n"
        "  --dev PATH        NVMe block device, e.g. /dev/nvme1n1  [required]\n"
        "  --requests N      Reads per trial                        [default: 512]\n"
        "  --qdepth Q        IO queue depth                         [default: N]\n"
        "  --trials T        Number of measurement trials           [default: 1]\n"
        "  --cpu C           Pin process to CPU C (sched_setaffinity)\n"
        "  --csv PATH        Append CSV rows to PATH                [default: stdout]\n"
        "  --prepopulate     Sequentially write LPNs [0, maxpages) first\n"
        "  --maxpages M      LPN range for prepopulate              [default: 4096]\n"
        "  --samelun         Issue 2 reads to same LUN (LPN 0 & LPN %d)\n"
        "  --reqsize BYTES   Bytes per request; must be a positive multiple\n"
        "                    of 4096                                [default: 4096]\n"
        "  --pages-per-req K Alias: sets reqsize = K*4096 (K >= 1).\n"
        "                    If both --reqsize and --pages-per-req are given,\n"
        "                    the last one on the command line wins.\n"
        "  --compute         In-flash-compute command shape: force reqsize=4096\n"
        "                    (host pins ONE page); the device senses all planes\n"
        "                    internally (COMPUTE_SENSE_PAGES). Decouples host\n"
        "                    O_DIRECT page cost from on-device all-plane sensing.\n"
        "\n"
        "CSV columns: requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns\n"
        "\n"
        "Primary metric: t_endtoend_ns = first_submit → last_completion.\n"
        "Compare to T_model(N) = 38000 * ceil(N * K / 512) ns  (K = pages/req).\n"
        "\n"
#ifdef USE_LIBAIO
        "Backend : libaio fallback  (install: sudo apt install libaio-dev)\n"
#else
        "Backend : liburing         (install: sudo apt install liburing-dev)\n"
#endif
        , prog, NLUNS);
}

int main(int argc, char *argv[])
{
    const char *dev      = NULL;
    const char *csv_path = NULL;
    int nreqs            = 512;
    int qdepth           = -1;    /* -1 → set to nreqs after arg parse */
    int trials           = 1;
    int cpu              = -1;
    int do_prepop        = 0;
    long max_pages       = 4096;
    int samelun          = 0;
    int reqsize          = (int)PAGE_SIZE;  /* bytes per request; default 4096 */
    int compute          = 0;               /* --compute: in-flash-compute command shape */

    enum {
        OPT_DEV = 'd', OPT_REQUESTS = 'n', OPT_QDEPTH = 'q',
        OPT_TRIALS = 't', OPT_CPU = 'c', OPT_CSV = 'o',
        OPT_PREPOP = 'p', OPT_MAXPAGES = 'm', OPT_SAMELUN = 's',
        OPT_HELP = 'h',
        OPT_REQSIZE = 256, OPT_PPR = 257, OPT_COMPUTE = 258
    };
    static const struct option longopts[] = {
        {"dev",          required_argument, 0, OPT_DEV},
        {"requests",     required_argument, 0, OPT_REQUESTS},
        {"qdepth",       required_argument, 0, OPT_QDEPTH},
        {"trials",       required_argument, 0, OPT_TRIALS},
        {"cpu",          required_argument, 0, OPT_CPU},
        {"csv",          required_argument, 0, OPT_CSV},
        {"prepopulate",  no_argument,       0, OPT_PREPOP},
        {"maxpages",     required_argument, 0, OPT_MAXPAGES},
        {"samelun",      no_argument,       0, OPT_SAMELUN},
        {"reqsize",      required_argument, 0, OPT_REQSIZE},
        {"pages-per-req",required_argument, 0, OPT_PPR},
        {"compute",      no_argument,       0, OPT_COMPUTE},
        {"help",         no_argument,       0, OPT_HELP},
        {0, 0, 0, 0}
    };

    int opt, lidx = 0;
    while ((opt = getopt_long(argc, argv, "h", longopts, &lidx)) != -1) {
        switch (opt) {
        case OPT_DEV:      dev       = optarg;       break;
        case OPT_REQUESTS: nreqs     = atoi(optarg); break;
        case OPT_QDEPTH:   qdepth    = atoi(optarg); break;
        case OPT_TRIALS:   trials    = atoi(optarg); break;
        case OPT_CPU:      cpu       = atoi(optarg); break;
        case OPT_CSV:      csv_path  = optarg;       break;
        case OPT_PREPOP:   do_prepop = 1;            break;
        case OPT_MAXPAGES: max_pages = atol(optarg); break;
        case OPT_SAMELUN:  samelun   = 1;                              break;
        case OPT_REQSIZE:  reqsize   = atoi(optarg);                   break;
        case OPT_PPR:      reqsize   = atoi(optarg) * (int)PAGE_SIZE;  break;
        case OPT_COMPUTE:  compute   = 1;                              break;
        case OPT_HELP:     usage(argv[0]); return 0;
        default:           usage(argv[0]); return 1;
        }
    }

    if (!dev) {
        fprintf(stderr, "Error: --dev is required\n\n");
        usage(argv[0]);
        return 1;
    }

    /* --compute: an in-flash-compute command is a single-page host read. The host
     * therefore pins exactly one page (O(1) O_DIRECT cost); the device expands the
     * sensing to COMPUTE_SENSE_PAGES planes internally (see conv_read). */
    if (compute) {
        reqsize = (int)PAGE_SIZE;
        fprintf(stderr, "[bench] --compute: in-flash-compute shape — 1-page host reads "
                "(reqsize=%u), device senses all planes internally\n", PAGE_SIZE);
    }

    /* Validate reqsize: must be a positive multiple of PAGE_SIZE */
    if (reqsize <= 0 || reqsize % (int)PAGE_SIZE != 0) {
        fprintf(stderr,
                "Error: --reqsize must be a positive multiple of %u (got %d)\n",
                PAGE_SIZE, reqsize);
        return 1;
    }
    g_reqsize = (unsigned)reqsize;
    int K = reqsize / (int)PAGE_SIZE;   /* pages per request */

    /* --samelun: override to 2 requests at LPN 0 and LPN NLUNS */
    if (samelun) {
        nreqs = 2;
        fprintf(stderr, "[bench] --samelun: 2 reads — LPN 0 and LPN %d "
                "(both map to LUN 0 under round-robin striping)\n", NLUNS);
    }

    if (qdepth <= 0) qdepth = nreqs;
    if (qdepth <  1) qdepth = 1;

    /* CPU affinity */
    if (cpu >= 0) {
        cpu_set_t cpuset;
        CPU_ZERO(&cpuset);
        CPU_SET((size_t)cpu, &cpuset);
        if (sched_setaffinity(0, sizeof(cpuset), &cpuset) < 0) {
            perror("sched_setaffinity");
            return 1;
        }
        fprintf(stderr, "[bench] pinned to CPU %d\n", cpu);
    }

    /* Open device with O_DIRECT */
    int fd = open(dev, O_RDWR | O_DIRECT);
    if (fd < 0) {
        fprintf(stderr, "open(%s): %s\n", dev, strerror(errno));
        return 1;
    }

    /* Prepopulate maptbl */
    if (do_prepop) {
        if (prepopulate(fd, max_pages) < 0) {
            close(fd);
            return 1;
        }
    }

    /* LPN array */
    long *lpns = malloc((size_t)nreqs * sizeof(*lpns));
    if (!lpns) { perror("malloc(lpns)"); close(fd); return 1; }

    if (samelun) {
        lpns[0] = 0;
        lpns[1] = NLUNS;   /* LPN 512 → LUN 0, same as LPN 0 */
    } else {
        for (int i = 0; i < nreqs; i++)
            lpns[i] = (long)i * K;   /* tile distinct K-page ranges */
    }

    /* Latency buffers */
    int64_t *lat_ns     = malloc((size_t)nreqs * sizeof(*lat_ns));
    int64_t *lat_sorted = malloc((size_t)nreqs * sizeof(*lat_sorted));
    if (!lat_ns || !lat_sorted) {
        perror("malloc(lat_ns)");
        close(fd); free(lpns);
        return 1;
    }

    /* CSV file (append mode; write header if empty) */
    FILE *csv_fp = NULL;
    int   csv_is_stdout = 0;
    if (csv_path) {
        csv_fp = fopen(csv_path, "a+");
        if (!csv_fp) {
            fprintf(stderr, "fopen(%s): %s\n", csv_path, strerror(errno));
            close(fd); free(lpns); free(lat_ns); free(lat_sorted);
            return 1;
        }
        /* Write CSV header only if file was empty */
        fseek(csv_fp, 0, SEEK_END);
        if (ftell(csv_fp) == 0)
            fprintf(csv_fp,
                    "requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns\n");
    } else {
        csv_fp = stdout;
        csv_is_stdout = 1;
        fprintf(csv_fp,
                "requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns\n");
    }

    fprintf(stderr, "[bench] dev=%s requests=%d qdepth=%d trials=%d reqsize=%d pages_per_req=%d\n",
            dev, nreqs, qdepth, trials, reqsize, K);

    for (int tr = 0; tr < trials; tr++) {
        memset(lat_ns, 0, (size_t)nreqs * sizeof(*lat_ns));
        int64_t e2e = 0;

        if (run_trial(fd, nreqs, qdepth, lpns, lat_ns, &e2e) < 0) {
            fprintf(stderr, "[bench] trial %d FAILED\n", tr);
            if (!csv_is_stdout) fclose(csv_fp);
            close(fd);
            return 1;
        }

        /* Percentiles via qsort */
        memcpy(lat_sorted, lat_ns, (size_t)nreqs * sizeof(*lat_ns));
        qsort(lat_sorted, (size_t)nreqs, sizeof(*lat_sorted), cmp_i64);

        int64_t p50 = pct(lat_sorted, nreqs, 50);
        int64_t p99 = pct(lat_sorted, nreqs, 99);

        fprintf(csv_fp, "%d,%d,%d,%ld,%ld,%ld\n",
                nreqs, qdepth, tr,
                (long)e2e, (long)p50, (long)p99);
        fflush(csv_fp);

        fprintf(stderr, "  trial %3d:  e2e=%7ld us   p50=%7ld us   p99=%7ld us\n",
                tr,
                (long)(e2e  / 1000),
                (long)(p50  / 1000),
                (long)(p99  / 1000));
    }

    if (!csv_is_stdout) fclose(csv_fp);
    free(lpns);
    free(lat_ns);
    free(lat_sorted);
    close(fd);
    return 0;
}
