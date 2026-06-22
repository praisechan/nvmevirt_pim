SPDK_DIR ?= /home/juchanlee/spdk
PKG_CONFIG ?= pkg-config
PKG_CONFIG_PATH := $(SPDK_DIR)/build/lib/pkgconfig

CC ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra
CPPFLAGS += -I..
SPDK_PACKAGES := spdk_nvme spdk_env_dpdk spdk_dpdklibs spdk_syslibs
SPDK_CFLAGS := $(shell PKG_CONFIG_PATH=$(PKG_CONFIG_PATH) $(PKG_CONFIG) --cflags $(SPDK_PACKAGES))
SPDK_RAW_LIBS := $(shell PKG_CONFIG_PATH=$(PKG_CONFIG_PATH) $(PKG_CONFIG) --libs --static $(SPDK_PACKAGES))

# SPDK registers its NVMe transports (e.g. PCIe) via constructors inside
# libspdk_nvme.a. Static linking strips those objects unless the SPDK archives
# are wrapped in --whole-archive, exactly as SPDK's own mk/spdk.app_vars.mk does.
# DPDK and system libs stay outside the whole-archive group.
SPDK_LDIRS := $(filter -L%,$(SPDK_RAW_LIBS))
SPDK_ONLY_LIBS := $(filter -lspdk_%,$(SPDK_RAW_LIBS))
SPDK_OTHER_LIBS := $(filter-out -L% -lspdk_%,$(SPDK_RAW_LIBS))
SPDK_LIBS := $(SPDK_LDIRS) -Wl,--whole-archive -Wl,--no-as-needed $(SPDK_ONLY_LIBS) -Wl,--no-whole-archive $(SPDK_OTHER_LIBS)
RPATH_LDFLAGS := -Wl,--disable-new-dtags -Wl,-rpath,$(SPDK_DIR)/build/lib -Wl,-rpath,$(SPDK_DIR)/dpdk/build/lib

.PHONY: all clean

all: inflash_bench_spdk

inflash_bench_spdk: inflash_bench_spdk.c ../inflash_pim.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(SPDK_CFLAGS) $(RPATH_LDFLAGS) -o $@ $< $(SPDK_LIBS)

clean:
	rm -f inflash_bench_spdk
