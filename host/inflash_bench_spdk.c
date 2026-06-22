// SPDX-License-Identifier: BSD-3-Clause

#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <endian.h>

#include "spdk/env.h"
#include "spdk/nvme.h"

#include "../inflash_pim.h"

struct bench_config {
	const char *bdf;
	const char *csv_path;
	const char *core_mask;
	uint32_t npages;
	uint32_t qdepth;
	uint32_t trials;
	uint64_t start_lpn;
	uint64_t lpn_stride;
	uint32_t nchs;
	bool chan_affine;
};

/*
 * Fill the LPN list for one command. The conv_ftl write pointer stripes pages
 * channel-first, so LPN n lands on NAND channel (n % nchs). In FTL-aware
 * (channel-affine) mode we emit the LPNs grouped by that residue, so a command
 * spanning a contiguous LPN window provably places ceil/floor(npages/nchs)
 * pages on every channel (32 each for 512 pages over 16 channels) by
 * construction, rather than relying on the list happening to be sequential.
 */
static void fill_lpn_list(uint64_t *lpns, uint64_t base, uint32_t npages,
			  uint32_t nchs, bool chan_affine)
{
	uint32_t idx = 0, ch;
	uint64_t lpn;

	if (!chan_affine || nchs == 0) {
		for (idx = 0; idx < npages; idx++)
			lpns[idx] = htole64(base + idx);
		return;
	}

	for (ch = 0; ch < nchs; ch++) {
		uint64_t first = base + ((ch + nchs - (base % nchs)) % nchs);

		for (lpn = first; lpn < base + npages; lpn += nchs)
			lpns[idx++] = htole64(lpn);
	}
}

struct bench_device {
	struct spdk_nvme_ctrlr *ctrlr;
	struct spdk_nvme_ns *ns;
};

struct trial_ctx {
	volatile bool done;
	uint16_t status;
	uint64_t start_ticks;
	uint64_t end_ticks;
};

static struct bench_device g_dev;

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s --bdf <BDF> --npages N --qdepth 1 --trials T --csv <path>\n"
		"          [--core-mask M] [--start-lpn S] [--lpn-stride D]\n"
		"          [--chan-affine] [--nchs C]\n"
		"  Trial k issues a command over LPNs [S + k*D .. S + k*D + N-1].\n"
		"  Default S=0, D=0 (every trial reuses LPNs 0..N-1).\n"
		"  --chan-affine: emit the LPN list FTL-aware (grouped by channel = lpn %% C,\n"
		"                 C=--nchs, default 16) so the N pages spread evenly across\n"
		"                 all channels by construction.\n",
		prog);
}

static int parse_u32(const char *s, uint32_t *value)
{
	char *end = NULL;
	unsigned long v;

	errno = 0;
	v = strtoul(s, &end, 0);
	if (errno || end == s || *end != '\0' || v > UINT32_MAX)
		return -1;

	*value = (uint32_t)v;
	return 0;
}

static int parse_u64(const char *s, uint64_t *value)
{
	char *end = NULL;
	unsigned long long v;

	errno = 0;
	v = strtoull(s, &end, 0);
	if (errno || end == s || *end != '\0')
		return -1;

	*value = (uint64_t)v;
	return 0;
}

static int parse_args(int argc, char **argv, struct bench_config *cfg)
{
	static const struct option long_opts[] = {
		{ "bdf", required_argument, NULL, 'b' },
		{ "npages", required_argument, NULL, 'n' },
		{ "qdepth", required_argument, NULL, 'q' },
		{ "trials", required_argument, NULL, 't' },
		{ "csv", required_argument, NULL, 'c' },
		{ "core-mask", required_argument, NULL, 'm' },
		{ "start-lpn", required_argument, NULL, 's' },
		{ "lpn-stride", required_argument, NULL, 'd' },
		{ "nchs", required_argument, NULL, 'C' },
		{ "chan-affine", no_argument, NULL, 'a' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	int opt;

	*cfg = (struct bench_config){
		.npages = INFLASH_PIM_MAX_PAGES,
		.qdepth = 1,
		.trials = 15,
		.core_mask = "0x1",
		.start_lpn = 0,
		.lpn_stride = 0,
		.nchs = 16,
		.chan_affine = false,
	};

	while ((opt = getopt_long(argc, argv, "", long_opts, NULL)) != -1) {
		switch (opt) {
		case 'b':
			cfg->bdf = optarg;
			break;
		case 'n':
			if (parse_u32(optarg, &cfg->npages) != 0)
				return -1;
			break;
		case 'q':
			if (parse_u32(optarg, &cfg->qdepth) != 0)
				return -1;
			break;
		case 't':
			if (parse_u32(optarg, &cfg->trials) != 0)
				return -1;
			break;
		case 'c':
			cfg->csv_path = optarg;
			break;
		case 'm':
			cfg->core_mask = optarg;
			break;
		case 's':
			if (parse_u64(optarg, &cfg->start_lpn) != 0)
				return -1;
			break;
		case 'd':
			if (parse_u64(optarg, &cfg->lpn_stride) != 0)
				return -1;
			break;
		case 'C':
			if (parse_u32(optarg, &cfg->nchs) != 0 || cfg->nchs == 0)
				return -1;
			break;
		case 'a':
			cfg->chan_affine = true;
			break;
		case 'h':
			usage(argv[0]);
			exit(0);
		default:
			return -1;
		}
	}

	if (!cfg->bdf || !cfg->csv_path || cfg->npages == 0 ||
	    cfg->npages > INFLASH_PIM_MAX_PAGES || cfg->trials == 0)
		return -1;

	if (cfg->qdepth != 1) {
		fprintf(stderr, "Only --qdepth 1 is supported for this gate benchmark\n");
		return -1;
	}

	return 0;
}

static bool probe_cb(void *cb_ctx, const struct spdk_nvme_transport_id *trid,
		     struct spdk_nvme_ctrlr_opts *opts)
{
	(void)cb_ctx;

	printf("[spdk] probe: attaching %s\n", trid->traddr);
	opts->num_io_queues = 1;
	return true;
}

static void attach_cb(void *cb_ctx, const struct spdk_nvme_transport_id *trid,
		      struct spdk_nvme_ctrlr *ctrlr,
		      const struct spdk_nvme_ctrlr_opts *opts)
{
	struct bench_device *dev = cb_ctx;

	(void)opts;

	printf("[spdk] attached %s\n", trid->traddr);
	dev->ctrlr = ctrlr;
}

static void completion_cb(void *arg, const struct spdk_nvme_cpl *cpl)
{
	struct trial_ctx *ctx = arg;

	ctx->end_ticks = spdk_get_ticks();
	ctx->status = (uint16_t)((cpl->status.sct << 8) | cpl->status.sc);
	ctx->done = true;
}

static uint64_t ticks_to_ns(uint64_t ticks)
{
	return ticks * 1000000000ULL / spdk_get_ticks_hz();
}

static int cmp_u64(const void *a, const void *b)
{
	uint64_t av = *(const uint64_t *)a;
	uint64_t bv = *(const uint64_t *)b;

	return (av > bv) - (av < bv);
}

static int run_trial(struct bench_device *dev, struct spdk_nvme_qpair *qpair,
		     void *buf, uint32_t npages, uint64_t *lat_ns,
		     uint16_t *status)
{
	struct spdk_nvme_cmd cmd = {};
	struct trial_ctx ctx = {};
	uint32_t len = npages * sizeof(uint64_t);
	int rc;

	cmd.opc = INFLASH_PIM_OPCODE;
	cmd.nsid = spdk_nvme_ns_get_id(dev->ns);
	cmd.cdw10 = npages;
	cmd.cdw11 = 0;

	ctx.start_ticks = spdk_get_ticks();
	rc = spdk_nvme_ctrlr_cmd_io_raw(dev->ctrlr, qpair, &cmd, buf, len,
					completion_cb, &ctx);
	if (rc != 0) {
		fprintf(stderr, "spdk_nvme_ctrlr_cmd_io_raw failed: %d\n", rc);
		return rc;
	}

	while (!ctx.done) {
		rc = spdk_nvme_qpair_process_completions(qpair, 0);
		if (rc < 0) {
			fprintf(stderr, "spdk_nvme_qpair_process_completions failed: %d\n", rc);
			return rc;
		}
	}

	*lat_ns = ticks_to_ns(ctx.end_ticks - ctx.start_ticks);
	*status = ctx.status;
	return 0;
}

int main(int argc, char **argv)
{
	struct bench_config cfg;
	struct spdk_env_opts env_opts;
	struct spdk_nvme_transport_id trid = {};
	struct spdk_nvme_qpair *qpair = NULL;
	uint64_t *latencies = NULL;
	uint64_t *lpns;
	void *buf = NULL;
	FILE *csv = NULL;
	uint32_t successes = 0;
	int rc = 1;
	uint32_t i;

	if (parse_args(argc, argv, &cfg) != 0) {
		usage(argv[0]);
		return 1;
	}

	env_opts.opts_size = sizeof(env_opts);
	spdk_env_opts_init(&env_opts);
	env_opts.name = "inflash_bench_spdk";
	env_opts.core_mask = cfg.core_mask;

	printf("[spdk] env core_mask=%s\n", cfg.core_mask);
	if (spdk_env_init(&env_opts) < 0) {
		fprintf(stderr, "spdk_env_init failed\n");
		return 1;
	}

	spdk_nvme_trid_populate_transport(&trid, SPDK_NVME_TRANSPORT_PCIE);
	snprintf(trid.traddr, sizeof(trid.traddr), "%s", cfg.bdf);

	printf("[spdk] probing %s ...\n", cfg.bdf);
	if (spdk_nvme_probe(&trid, &g_dev, probe_cb, attach_cb, NULL) != 0 || !g_dev.ctrlr) {
		fprintf(stderr, "spdk_nvme_probe failed / no controller attached for %s\n",
			cfg.bdf);
		goto out;
	}

	g_dev.ns = spdk_nvme_ctrlr_get_ns(g_dev.ctrlr, 1);
	if (!g_dev.ns || !spdk_nvme_ns_is_active(g_dev.ns)) {
		fprintf(stderr, "namespace 1 is not active\n");
		goto out;
	}

	qpair = spdk_nvme_ctrlr_alloc_io_qpair(g_dev.ctrlr, NULL, 0);
	if (!qpair) {
		fprintf(stderr, "spdk_nvme_ctrlr_alloc_io_qpair failed\n");
		goto out;
	}

	buf = spdk_zmalloc(4096, 4096, NULL, SPDK_ENV_NUMA_ID_ANY, SPDK_MALLOC_DMA);
	if (!buf) {
		fprintf(stderr, "spdk_zmalloc failed\n");
		goto out;
	}

	lpns = buf;

	csv = fopen(cfg.csv_path, "w");
	if (!csv) {
		perror(cfg.csv_path);
		goto out;
	}
	fprintf(csv, "host_stack,n_pages,qdepth,trial,t_e2e_ns,status\n");

	latencies = calloc(cfg.trials, sizeof(*latencies));
	if (!latencies) {
		perror("calloc");
		goto out;
	}

	for (i = 0; i < cfg.trials; i++) {
		uint16_t status = 0xffff;
		uint64_t lat_ns = 0;
		uint64_t base = cfg.start_lpn + (uint64_t)i * cfg.lpn_stride;

		fill_lpn_list(lpns, base, cfg.npages, cfg.nchs, cfg.chan_affine);

		if (run_trial(&g_dev, qpair, buf, cfg.npages, &lat_ns, &status) != 0)
			goto out;

		latencies[i] = lat_ns;
		if (status == 0)
			successes++;

		fprintf(csv, "spdk,%u,%u,%u,%" PRIu64 ",%u\n",
			cfg.npages, cfg.qdepth, i, lat_ns, status);
		fflush(csv);
	}

	qsort(latencies, cfg.trials, sizeof(*latencies), cmp_u64);
	printf("[result] successful=%u/%u host_min_ns=%" PRIu64
	       " host_median_ns=%" PRIu64 " host_max_ns=%" PRIu64 "\n",
	       successes, cfg.trials, latencies[0], latencies[cfg.trials / 2],
	       latencies[cfg.trials - 1]);

	rc = (successes == cfg.trials) ? 0 : 2;

out:
	if (csv)
		fclose(csv);
	free(latencies);
	if (buf)
		spdk_free(buf);
	if (qpair)
		spdk_nvme_ctrlr_free_io_qpair(qpair);
	if (g_dev.ctrlr)
		spdk_nvme_detach(g_dev.ctrlr);
	spdk_env_fini();
	return rc;
}
