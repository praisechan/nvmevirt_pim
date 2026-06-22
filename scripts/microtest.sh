#!/usr/bin/env bash
# scripts/microtest.sh — Quick sanity latency check for INFLASH_PIM
#
# Tests two scenarios:
#   (A) 512 reads, one per LUN, qdepth=512 → all 512 LUNs active in parallel
#       Expected end-to-end ≈ 38 us  (T_model(512) = 38us * ceil(512/512) = 38us)
#
#   (B) 2 reads to the SAME LUN, qdepth=2 → second queues behind first on same LUN
#       Expected end-to-end ≈ 2 × tR = 60 us
#       Uses --samelun: LPN 0 and LPN 512 both map to LUN 0 under round-robin.
#
# Usage:
#   DEV=/dev/nvme1n1 bash scripts/microtest.sh
#   DEV=/dev/nvme1n1 BENCH=./host/inflash_bench bash scripts/microtest.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="${BENCH:-${REPO_DIR}/host/inflash_bench}"
DEV="${DEV:-}"
TRIALS=5

if [[ -z "${DEV}" ]]; then
    echo "Usage: DEV=/dev/nvme1n1 bash $0"
    echo ""
    echo "Set DEV to the NVMeVirt block device (check: lsblk | grep nvme)"
    exit 1
fi

if [[ ! -x "${BENCH}" ]]; then
    echo "[microtest] ERROR: benchmark not found at ${BENCH}"
    echo "           Build with: make -C ${REPO_DIR}/host"
    exit 1
fi

echo "=========================================="
echo " INFLASH_PIM microtest"
echo " Device : ${DEV}"
echo " Bench  : ${BENCH}"
echo " Trials : ${TRIALS}"
echo "=========================================="
echo ""

# ---------- Test A: 512 reads, all LUNs in parallel ----------
echo "--- Test A: 512 reads (one per LUN), qdepth=512 ---"
echo "    Expected end-to-end ≈ 38 us"
echo ""
"${BENCH}" --dev "${DEV}" \
           --requests 512 \
           --qdepth 512 \
           --trials "${TRIALS}"
echo ""

# ---------- Test B: 2 reads to same LUN ----------
echo "--- Test B: 2 reads to SAME LUN (LPN 0 and LPN 512), qdepth=2 ---"
echo "    Expected end-to-end ≈ 60 us  (2 × tR = 2 × 30 us)"
echo ""
"${BENCH}" --dev "${DEV}" \
           --samelun \
           --qdepth 2 \
           --trials "${TRIALS}"
echo ""

echo "=========================================="
echo " Compare:"
echo "   Test A e2e  → should be ~38 us"
echo "   Test B e2e  → should be ~60 us (2 × tR)"
echo "=========================================="
