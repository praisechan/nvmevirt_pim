#!/usr/bin/env bash
# scripts/run_compute_exp.sh — Option-1 experiment: decouple on-device sensing
# extent from host transfer size (in-flash-compute command shape).
#
# Reloads the freshly-built module, prepopulates, then measures host e2e and the
# device-observed latency for:
#   E1  OLD shape — one 256 KB command (64 LUNs), multi-page host read (baseline)
#   E2  NEW shape — one 1-page --compute command that senses ALL 512 planes
#   E3  NEW shape — 8 compute commands, qdepth 1 and qdepth 8 (scaling sanity)
#
# Must run as root (module reload + raw device access).
#   ! sudo bash scripts/run_compute_exp.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
DEV=/dev/nvme1n1
BENCH="$REPO/host/inflash_bench"
TASKSET="taskset -c 16-31"

echo "=================================================================="
echo "[exp] Reloading freshly-built module (COMPUTE_SENSE_PAGES decouple)"
echo "=================================================================="
rmmod nvmev 2>/dev/null || true
insmod "$REPO/nvmev.ko" memmap_start=96G memmap_size=16G cpus=7,8
sleep 1
lsblk | grep -i nvme1 || { echo "[exp] ERROR: $DEV not present"; exit 1; }

run() {  # $1=label  $2..=bench args
    local label="$1"; shift
    echo ""
    echo "------------------------------------------------------------------"
    echo "[exp] $label"
    echo "      args: $*"
    echo "------------------------------------------------------------------"
    dmesg -C
    $TASKSET "$BENCH" --dev "$DEV" "$@"
    echo "[exp] device-observed latency (model):"
    dmesg | grep inflash_dev_lat | tail -3
}

# E1: baseline OLD shape — one 256 KB command = 64 LUNs (4/ch). Prepopulate here.
run "E1  OLD shape: one 256 KB command (64 LUNs), multi-page host read" \
    --reqsize 262144 --requests 1 --qdepth 1 --trials 15 \
    --prepopulate --maxpages 8192

# E2: NEW compute shape — one 1-page host read, device senses all 512 planes.
run "E2  NEW compute shape: one 1-page command, all 512 planes sensed" \
    --compute --requests 1 --qdepth 1 --trials 15

# E3: NEW compute shape — 8 sequential compute ops (qdepth 1) and pipelined (qdepth 8).
run "E3a NEW compute shape: 8 commands, qdepth 1 (sequential)" \
    --compute --requests 8 --qdepth 1 --trials 15
run "E3b NEW compute shape: 8 commands, qdepth 8 (pipelined)" \
    --compute --requests 8 --qdepth 8 --trials 15

echo ""
echo "=================================================================="
echo "[exp] DONE. 'sensed N pages' in each dmesg block proves the on-device"
echo "      sensing extent; compare host e2e: E1 (256 KB, 64 planes) vs"
echo "      E2 (1 page, 512 planes)."
echo "=================================================================="
