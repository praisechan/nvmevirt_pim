#!/usr/bin/env bash
# scripts/sweep.sh — Sweep N requests across all LUN-parallelism regimes
#
# Prepopulates the device once, then loops N over a geometric sequence.
# Appends results to results.csv with an extra T_model_ns column.
#
# T_model(N) = 38000 * ceil(N / 512)  ns
#
# Usage:
#   DEV=/dev/nvme1n1 bash scripts/sweep.sh
#   DEV=/dev/nvme1n1 OUTCSV=my_results.csv bash scripts/sweep.sh
#
# Environment variables:
#   DEV         — NVMeVirt block device                  [required]
#   BENCH       — path to inflash_bench binary           [default: ../host/inflash_bench]
#   OUTCSV      — output CSV file                        [default: results.csv next to this script]
#   TRIALS      — trials per N                           [default: 20]
#   MAXPAGES    — pages to prepopulate                   [default: 8192 (covers up to N=4096 × 2)]
#   SKIP_PREPOP — set to 1 to skip prepopulate phase     [default: 0]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="${BENCH:-${REPO_DIR}/host/inflash_bench}"
DEV="${DEV:-}"
OUTCSV="${OUTCSV:-${REPO_DIR}/results.csv}"
TRIALS="${TRIALS:-20}"
MAXPAGES="${MAXPAGES:-8192}"
SKIP_PREPOP="${SKIP_PREPOP:-0}"

# N sweep values
N_LIST="1 2 4 8 16 32 64 128 256 512 1024 2048 4096"

if [[ -z "${DEV}" ]]; then
    echo "Usage: DEV=/dev/nvme1n1 bash $0"
    echo ""
    echo "Set DEV to the NVMeVirt block device (check: lsblk | grep nvme)"
    exit 1
fi

if [[ ! -x "${BENCH}" ]]; then
    echo "[sweep] ERROR: benchmark not found at ${BENCH}"
    echo "        Build with: make -C ${REPO_DIR}/host"
    exit 1
fi

echo "========================================"
echo " INFLASH_PIM latency sweep"
echo " Device    : ${DEV}"
echo " Output CSV: ${OUTCSV}"
echo " Trials    : ${TRIALS}"
echo " N values  : ${N_LIST}"
echo "========================================"
echo ""

# Write CSV header (overwrite if file doesn't exist yet)
if [[ ! -f "${OUTCSV}" ]]; then
    echo "requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns,t_model_ns" \
        > "${OUTCSV}"
    echo "[sweep] Created ${OUTCSV}"
fi

# ---------- Prepopulate once ----------
if [[ "${SKIP_PREPOP}" != "1" ]]; then
    echo "[sweep] Prepopulating ${MAXPAGES} pages on ${DEV}..."
    "${BENCH}" --dev "${DEV}" \
               --requests 1 \
               --trials 0 \
               --prepopulate \
               --maxpages "${MAXPAGES}" \
        2>&1 | grep -E '^\[prepopulate\]|ERROR'
    echo "[sweep] Prepopulate done."
else
    echo "[sweep] Skipping prepopulate (SKIP_PREPOP=1)."
fi
echo ""

# Temp file for per-N bench output (no header, raw rows only)
TMPCSV=$(mktemp /tmp/inflash_sweep_XXXXXX.csv)
trap "rm -f '${TMPCSV}'" EXIT

# ---------- Sweep ----------
for N in ${N_LIST}; do
    # T_model(N) = 38000 * ceil(N / 512) ns   (integer arithmetic)
    T_MODEL=$(( 38000 * ( (N + 511) / 512 ) ))

    echo "[sweep] N=${N}  T_model=${T_MODEL} ns  (${TRIALS} trials)..."

    # Run bench; capture CSV rows without header
    > "${TMPCSV}"
    "${BENCH}" --dev  "${DEV}" \
               --requests "${N}" \
               --qdepth   "${N}" \
               --trials   "${TRIALS}" \
               --csv      "${TMPCSV}" \
        2>/dev/null

    # Append rows with T_model_ns column (skip header line from bench CSV)
    tail -n +2 "${TMPCSV}" \
        | awk -F',' -v tm="${T_MODEL}" 'NF>=6 {print $0","tm}' \
        >> "${OUTCSV}"

    # Print summary (last trial end-to-end)
    LAST_E2E=$(tail -1 "${TMPCSV}" | cut -d',' -f4)
    echo "        last trial e2e = $((LAST_E2E / 1000)) us  (model = $((T_MODEL / 1000)) us)"
done

echo ""
echo "[sweep] Done. Results in: ${OUTCSV}"
wc -l "${OUTCSV}"
