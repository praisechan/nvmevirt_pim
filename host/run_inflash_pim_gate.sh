#!/usr/bin/env bash
set -euo pipefail

if [[ "${RUN:-0}" != "1" ]]; then
    echo 'Dry run only. Re-run with RUN=1 after booting with memmap=16G$96G.'
    echo "Example: RUN=1 SPDK_DIR=/home/juchanlee/spdk $0"
    exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPDK_DIR="${SPDK_DIR:-/home/juchanlee/spdk}"
DEVICE="${DEVICE:-/dev/nvme1n1}"
MEMMAP_START="${MEMMAP_START:-96G}"
MEMMAP_SIZE="${MEMMAP_SIZE:-16G}"
NVMEV_CPUS="${NVMEV_CPUS:-7,8}"
HOST_CPUS="${HOST_CPUS:-16-31}"
SPDK_CORE_MASK="${SPDK_CORE_MASK:-0xffff0000}"
NPAGES="${NPAGES:-512}"
QDEPTH="${QDEPTH:-1}"
TRIALS="${TRIALS:-15}"
CSV="${CSV:-$ROOT_DIR/results_pim_spdk.csv}"
DMESG_LOG="${DMESG_LOG:-$ROOT_DIR/dmesg_inflash_pim.txt}"

if ! grep -q 'memmap=16G\$96G' /proc/cmdline; then
    echo 'Missing expected boot argument memmap=16G$96G in /proc/cmdline' >&2
    exit 1
fi

cd "$ROOT_DIR"
make
make -C host SPDK_DIR="$SPDK_DIR"

sudo insmod ./nvmev.ko memmap_start="$MEMMAP_START" memmap_size="$MEMMAP_SIZE" cpus="$NVMEV_CPUS"
sleep 1
sudo dmesg | tail -50 | grep -iE 'nvmev|tt_luns|luns' || true

if [[ ! -b "$DEVICE" ]]; then
    echo "$DEVICE is not present under the kernel nvme driver" >&2
    exit 1
fi

sudo dd if=/dev/zero of="$DEVICE" bs=4K count=512 oflag=direct status=none

if [[ -z "${BDF:-}" ]]; then
    DEVNAME="$(basename "$DEVICE")"
    DEVPATH="$(readlink -f "/sys/block/$DEVNAME/device")"
    BDF="$(grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]' <<<"$DEVPATH" | tail -1)"
fi

if [[ -z "$BDF" ]]; then
    echo "Could not determine PCI BDF for $DEVICE; set BDF=dddd:bb:dd.f" >&2
    exit 1
fi

cleanup() {
    sudo "$SPDK_DIR/scripts/setup.sh" reset || true
}
trap cleanup EXIT

sudo DRIVER_OVERRIDE=uio_pci_generic PCI_ALLOWED="$BDF" "$SPDK_DIR/scripts/setup.sh"
grep -iE 'HugePages|Hugepagesize|Hugetlb' /proc/meminfo

IDENTIFY="$SPDK_DIR/build/examples/identify"
if [[ ! -x "$IDENTIFY" ]]; then
    IDENTIFY="$SPDK_DIR/build/bin/spdk_nvme_identify"
fi
sudo "$IDENTIFY" -r "trtype:PCIe traddr:$BDF"

sudo dmesg -C
sudo taskset -c "$HOST_CPUS" host/inflash_bench_spdk --bdf "$BDF" \
    --npages "$NPAGES" --qdepth "$QDEPTH" --trials "$TRIALS" --csv "$CSV" \
    --core-mask "$SPDK_CORE_MASK" ${EXTRA_BENCH_ARGS:-}

sudo dmesg | grep inflash_dev_lat | tee "$DMESG_LOG"
ROWS="$(awk -F, 'NR > 1 { n++ } END { print n + 0 }' "$CSV")"
SUCCESS="$(awk -F, 'NR > 1 && $6 == 0 { ok++ } END { print ok + 0 }' "$CSV")"
LAT_SORT="$(mktemp)"
awk -F, 'NR > 1 { print $5 }' "$CSV" | sort -n > "$LAT_SORT"
if [[ "$ROWS" -eq 0 ]]; then
    echo "No CSV rows" >&2
    rm -f "$LAT_SORT"
    exit 1
fi
MIN="$(head -1 "$LAT_SORT")"
MEDIAN="$(awk -v n="$ROWS" 'NR == int((n + 1) / 2) { print; exit }' "$LAT_SORT")"
MAX="$(tail -1 "$LAT_SORT")"
rm -f "$LAT_SORT"
echo "CSV successful=$SUCCESS/$ROWS host_min_ns=$MIN host_median_ns=$MEDIAN host_max_ns=$MAX"
if [[ "$SUCCESS" -ne "$ROWS" ]]; then
    echo "Gate failed: not all SPDK trials completed successfully" >&2
    exit 1
fi
if ! grep -q "requested $NPAGES pages, sensed $NPAGES pages" "$DMESG_LOG"; then
    echo "Gate failed: missing requested $NPAGES / sensed $NPAGES dmesg line" >&2
    exit 1
fi
echo "Gate run complete. Confirm inflash_dev_lat is near the 30 us NAND level, not 512x."
