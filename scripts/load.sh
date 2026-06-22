#!/usr/bin/env bash
# scripts/load.sh — Load nvmev.ko with INFLASH_PIM memmap region
#
# Usage:
#   bash scripts/load.sh
#   CPUS=7,8 bash scripts/load.sh
#
# Environment:
#   CPUS      — comma-separated CPU list for NVMeVirt polling threads [default: 7,8]
#   KO_PATH   — path to nvmev.ko                                      [default: ./nvmev.ko]
#
# Lines marked [sudo] require root privileges.

set -euo pipefail

CPUS="${CPUS:-7,8}"
KO_PATH="${KO_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nvmev.ko}"
MEMMAP_START="96G"
MEMMAP_SIZE="16G"

echo "[load] KO      : ${KO_PATH}"
echo "[load] CPUs    : ${CPUS}"
echo "[load] memmap  : start=${MEMMAP_START} size=${MEMMAP_SIZE}"
echo ""

if [[ ! -f "${KO_PATH}" ]]; then
    echo "[load] ERROR: ${KO_PATH} not found. Run scripts/build.sh first."
    exit 1
fi

# ---------- unload existing nvmev instance ----------
# NOTE: use `grep >/dev/null` (NOT `grep -q`): under `set -o pipefail`, grep -q
# closes the pipe on first match, lsmod gets SIGPIPE, the pipeline returns
# non-zero, and a loaded module is wrongly reported as absent → insmod "File exists".
if lsmod | grep '^nvmev' >/dev/null 2>&1; then
    LOADED_MOD=$(lsmod | grep '^nvmev' | awk '{print $1}')
    echo "[load] WARNING: NVMeVirt module '${LOADED_MOD}' is currently loaded."
    echo "[load] Removing it now..."
    echo ""
    CMD="rmmod ${LOADED_MOD}"
    echo "[sudo] ${CMD}"
    sudo ${CMD}
    echo "[load] rmmod done."
else
    echo "[load] No nvmev module loaded — skipping rmmod."
fi

echo ""

# ---------- load new module ----------
CMD="insmod ${KO_PATH} memmap_start=${MEMMAP_START} memmap_size=${MEMMAP_SIZE} cpus=${CPUS}"
echo "[load] Loading module:"
echo "[sudo] ${CMD}"
sudo ${CMD}

echo ""
echo "[load] Module loaded. Verify with:"
echo "         lsmod | grep nvmev"
echo "         dmesg | tail -30"
echo "         lsblk"
echo ""
echo "[load] Expected virtual NVMe device: /dev/nvme1n1 (or next free nvmeX)"
echo "[load] Confirm with: lsblk | grep nvme"
