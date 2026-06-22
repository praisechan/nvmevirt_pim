#!/usr/bin/env bash
# SwarmIO/scripts/swarmio_microtest.sh — Calibration microtests for inflash_pim on SwarmIO
#
# Runs 3 microtests using host/inflash_bench to verify the timing model AFTER loading
# swarmio with load_inflash.sh. Does NOT load or unload the module.
#
# Tests:
#   A) Single request (1 req, qdepth=1)
#        → one scheduling round on one instance
#        Expected: ~38 us (faithful) / ~38 us (pipelined)
#
#   B) Two requests to the SAME instance (--samelun, qdepth=2)
#        LPN 0  → instance  0 % 512 = 0
#        LPN 512 → instance 512 % 512 = 0   (same instance!)
#        Second request serializes behind first on instance 0.
#        Expected faithful : ~76 us  (2 × 38 us sequential)
#        Expected pipelined: ~46 us  (8 us sched + 30 us min + 8 us sched overlap)
#
#   C) Saturated round: 512 concurrent requests, one per instance (qdepth=512)
#        All 512 instances fully utilized in a single scheduling round.
#        Expected: ~38 us (both variants — one round covers all instances)
#
# Usage:
#   DEV=/dev/nvme1n1 bash SwarmIO/scripts/swarmio_microtest.sh
#
# Environment:
#   DEV        — SwarmIO block device [required]; discover: lsblk | grep nvme
#   BENCH      — path to inflash_bench binary [default: REPO_DIR/host/inflash_bench]
#   TRIALS     — measurement trials per test   [default: 10]
#   BENCH_CPUS — CPU list for taskset          [default: 16-31, E-cores disjoint from SUs 2-9]
#   PIPELINED  — set to 1 to show pipelined expectations in summary

set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
REPO_DIR=$(realpath "${SCRIPT_DIR}/../..")
BENCH="${BENCH:-${REPO_DIR}/host/inflash_bench}"
DEV="${DEV:-}"
TRIALS="${TRIALS:-10}"
BENCH_CPUS="${BENCH_CPUS:-16-31}"
PIPELINED="${PIPELINED:-0}"

# ---- Validate ----
if [[ -z "${DEV}" ]]; then
    echo "Usage: DEV=/dev/nvme1n1 bash $0"
    echo ""
    echo "Discover the SwarmIO device after loading: lsblk | grep nvme"
    exit 1
fi

if [[ ! -x "${BENCH}" ]]; then
    echo "[microtest] ERROR: inflash_bench not found at ${BENCH}"
    echo "            Build with: make -C ${REPO_DIR}/host"
    exit 1
fi

# ---- Helper: run bench with optional taskset CPU pinning ----
run_bench() {
    if command -v taskset &>/dev/null; then
        taskset -c "${BENCH_CPUS}" "${BENCH}" "$@"
    else
        "${BENCH}" "$@"
    fi
}

# ---- Expected values ----
if [[ "${PIPELINED}" == "1" ]]; then
    EXP_A="~38 us  (single round, read_sched_delay=8000 + read_min_delay=30000 ns)"
    EXP_B="~46 us  (pipelined: sched(8us) + min(30us) + sched(8us) overlap)"
    EXP_C="~38 us  (one saturated round, all 512 instances)"
    VARIANT="PIPELINED (read_sched_delay=8000 ns, read_min_delay=30000 ns)"
else
    EXP_A="~38 us  (single scheduling round, read_sched_delay=38000 ns)"
    EXP_B="~76 us  (faithful: 2 × 38 us sequential on same instance)"
    EXP_C="~38 us  (one saturated round, all 512 instances)"
    VARIANT="FAITHFUL  (read_sched_delay=38000 ns, read_min_delay=0 ns)"
fi

echo "=========================================="
echo " SwarmIO/inflash_pim calibration microtests"
echo " Device    : ${DEV}"
echo " Bench     : ${BENCH}"
echo " Trials    : ${TRIALS}"
echo " Bench CPUs: ${BENCH_CPUS}  (E-cores, disjoint from service-unit CPUs 2-9)"
echo " Variant   : ${VARIANT}"
echo "=========================================="
echo ""

# ---- Test A: single request ----
echo "--- Test A: 1 request, qdepth=1 (one instance, one scheduling round) ---"
echo "    Expected: ${EXP_A}"
echo ""
run_bench \
    --dev    "${DEV}" \
    --requests 1 \
    --qdepth   1 \
    --trials   "${TRIALS}"
echo ""

# ---- Test B: two requests to the SAME instance ----
# --samelun issues LPN 0 and LPN 512.
#   unit_id = lpn % num_sched_insts  =>  0%512=0 and 512%512=0  (same instance)
echo "--- Test B: 2 requests to SAME instance (--samelun, qdepth=2) ---"
echo "    LPN 0 → instance 0,  LPN 512 → instance 0  (512 % 512 = 0)"
echo "    Second request serializes behind first; measures pipeline depth."
echo "    Expected: ${EXP_B}"
echo ""
run_bench \
    --dev    "${DEV}" \
    --samelun \
    --qdepth   2 \
    --trials   "${TRIALS}"
echo ""

# ---- Test C: saturated round — all 512 instances in parallel ----
echo "--- Test C: 512 requests, qdepth=512 (one per instance, saturated round) ---"
echo "    All 512 SwarmIO instances active simultaneously."
echo "    Expected: ${EXP_C}"
echo ""
run_bench \
    --dev    "${DEV}" \
    --requests 512 \
    --qdepth   512 \
    --trials   "${TRIALS}"
echo ""

echo "=========================================="
echo " Expected summary:"
echo "   Test A (1 req,   qdepth=1)   → ${EXP_A}"
echo "   Test B (2 req,   same inst)  → ${EXP_B}"
echo "   Test C (512 req, qdepth=512) → ${EXP_C}"
echo ""
echo " Primary metric: t_endtoend_ns (first submit → last completion)"
echo " Model formula:  T_model(N) = 38000 × ceil(N / 512) ns"
echo "=========================================="
