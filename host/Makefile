# host/Makefile — INFLASH_PIM benchmark
#
# Primary (preferred): requires liburing
#   sudo apt install liburing-dev
#
# Fallback:            requires libaio
#   sudo apt install libaio-dev
#   make libaio

CC      = cc
CFLAGS  = -O2 -Wall -Wextra
LDFLAGS = -luring

# ---- SPDK build (host-path-elimination leg) ----
# Out-of-tree link via SPDK's pkg-config files (build/lib/pkgconfig).
# Override SPDK_DIR if SPDK lives elsewhere:  make spdk SPDK_DIR=/path/to/spdk
SPDK_DIR    ?= /home/juchanlee/spdk
PKG_CONFIG_PATH := $(SPDK_DIR)/build/lib/pkgconfig
SPDK_PC      = PKG_CONFIG_PATH=$(PKG_CONFIG_PATH) pkg-config
SPDK_DEPS    = spdk_nvme spdk_env_dpdk
SPDK_CFLAGS  = $(shell $(SPDK_PC) --cflags $(SPDK_DEPS) 2>/dev/null)
# Whole-archive the SPDK libs (they register via constructors), then append syslibs.
# Bake DPDK/SPDK shared-lib dirs into the binary so librte_*.so resolve at runtime.
# --disable-new-dtags forces DT_RPATH (searched for transitive deps too, e.g.
# librte_power -> librte_timer) rather than DT_RUNPATH (direct deps only).
# Matters because sudo strips LD_LIBRARY_PATH.
SPDK_RPATH   = -Wl,--disable-new-dtags -Wl,-rpath,$(SPDK_DIR)/build/lib -Wl,-rpath,$(SPDK_DIR)/dpdk/build/lib
SPDK_LDFLAGS = -Wl,--whole-archive -Wl,--no-as-needed \
               $(shell $(SPDK_PC) --libs $(SPDK_DEPS) 2>/dev/null) \
               -Wl,--no-whole-archive \
               $(shell $(SPDK_PC) --libs --static spdk_syslibs 2>/dev/null) \
               $(SPDK_RPATH)

.PHONY: all libaio spdk clean

all: inflash_bench

inflash_bench: inflash_bench.c
	$(CC) $(CFLAGS) $< $(LDFLAGS) -o $@

# libaio fallback — compiled via USE_LIBAIO preprocessor guard in inflash_bench.c
libaio: inflash_bench.c
	$(CC) $(CFLAGS) -DUSE_LIBAIO $< -laio -o inflash_bench_libaio

# SPDK kernel-bypass bench. Requires SPDK built at $(SPDK_DIR).
spdk: inflash_bench_spdk.c
	@test -d "$(PKG_CONFIG_PATH)" || { echo "ERROR: SPDK pkgconfig not found at $(PKG_CONFIG_PATH); build SPDK first (SPDK_DIR=$(SPDK_DIR))"; exit 1; }
	$(CC) $(CFLAGS) $(SPDK_CFLAGS) $< -o inflash_bench_spdk $(SPDK_LDFLAGS)

clean:
	rm -f inflash_bench inflash_bench_libaio inflash_bench_spdk
