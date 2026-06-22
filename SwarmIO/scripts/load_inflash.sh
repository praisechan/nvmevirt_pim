#!/bin/bash
# SwarmIO/scripts/load_inflash.sh — Load swarmio with inflash_pim params for i9-13900F
#
# Usage:
#   [RUN=1] [NUM_SERVICE_UNITS=8] [PIPELINED=1] bash load_inflash.sh
#
# Environment:
#   RUN=1                — actually execute the load (guards sudo modprobe behind this flag)
#   NUM_SERVICE_UNITS    — number of service units to activate (default: 8; sweep: 1 2 4 8)
#   PIPELINED=1          — use pipelined timing variant:
#                            read_sched_delay=8000 ns, read_min_delay=30000 ns
#                          Default (faithful):
#                            read_sched_delay=38000 ns, read_min_delay=0 ns
#
# Machine: i9-13900F, 32 logical CPUs
#   P-cores (HT): 0-15   E-cores: 16-31
#   Reserved DRAM: memmap=16G$96G  =>  memmap_start=96G, memmap_size=16G
#   Service-unit CPUs: 2-9  (P-cores, avoiding OS/IRQ on 0-1)
#   Benchmark CPUs:    16-31 (E-cores, fully disjoint)
#
# Pre-flight:
#   1. sudo rmmod nvmev   — nvmev and swarmio contend for the same memmap region
#   2. After load, discover the new device: lsblk | grep nvme
#      Check kernel messages:            sudo dmesg | tail -20

set -e

SCRIPT_DIR=$(dirname "$(realpath "$0")")

# ---- Parameters ----
S="${NUM_SERVICE_UNITS:-8}"
WORKERS_PER_SU=1

# SwarmIO pins one CPU per dispatcher AND one per worker, so it needs
#   num_service_units * (1 dispatcher + num_workers_per_service_unit)  CPUs.
# For S in {1,2,4,8} with 1 worker each that is {2,4,8,16} CPUs.
# We place service units on the P-core threads (0..15) and leave the
# E-cores (16..31) for fio / inflash_bench, so the two are always disjoint.
NCPUS=$(( S * (1 + WORKERS_PER_SU) ))
if (( NCPUS > 16 )); then
    echo "[ERROR] S=${S} needs ${NCPUS} CPUs but only 16 P-core threads (0-15) are reserved for service units." >&2
    echo "        Reduce NUM_SERVICE_UNITS (<=8) or widen the CPU plan (would overlap the E-cores used by fio)." >&2
    exit 1
fi
SU_CPUS="0-$(( NCPUS - 1 ))"

if [[ "${PIPELINED:-0}" == "1" ]]; then
    READ_SCHED_DELAY=8000
    READ_MIN_DELAY=30000
    VARIANT="pipelined (read_sched_delay=${READ_SCHED_DELAY} ns, read_min_delay=${READ_MIN_DELAY} ns)"
else
    READ_SCHED_DELAY=38000
    READ_MIN_DELAY=0
    VARIANT="faithful  (read_sched_delay=${READ_SCHED_DELAY} ns, read_min_delay=${READ_MIN_DELAY} ns)"
fi

echo "===== SwarmIO load_inflash.sh ====="
echo "  Variant           : ${VARIANT}"
echo "  num_service_units : ${S}"
echo "  service-unit CPUs : ${SU_CPUS}  (${NCPUS} cores = S*(1 disp + ${WORKERS_PER_SU} worker)); bench/fio use 16-31"
echo ""

# ---- Pre-flight checks (always run; no sudo) ----
echo "[pre-flight] Current module state (lsmod | grep nvmev/swarmio):"
lsmod | grep -E 'nvmev|swarmio' || echo "  (neither nvmev nor swarmio is loaded — good)"
echo ""
echo "[pre-flight] NVMe block devices (lsblk | grep nvme):"
lsblk | grep nvme || echo "  (no nvme devices visible)"
echo ""
if lsmod | grep -q '^nvmev'; then
    echo "[WARNING] nvmev is loaded. Unload it first or swarmio will fail to claim the memmap:"
    echo "    sudo rmmod nvmev"
    echo ""
fi

# ---- Build the load command ----
LOAD_CMD="${SCRIPT_DIR}/load.sh \
 --memmap-start 96G \
 --memmap-size 16G \
 --num-sched-insts 512 \
 --block-size 4096 \
 --read-sched-delay ${READ_SCHED_DELAY} \
 --read-min-delay ${READ_MIN_DELAY} \
 --num-service-units ${S} \
 --num-workers-per-service-unit ${WORKERS_PER_SU} \
 --cpus ${SU_CPUS}"
# Note: --use-disp-dma / --use-worker-dma intentionally omitted (no Intel DSA on this machine)

echo "[load] Command that will be executed:"
echo "  ${LOAD_CMD}"
echo ""

# ---- Execute or dry-run ----
if [[ "${RUN:-0}" == "1" ]]; then
    echo "[load] RUN=1 — executing..."
    eval "${LOAD_CMD}"
    echo ""
    echo "[post-load] NVMe block devices now:"
    lsblk | grep nvme || true
    echo ""
    echo "[post-load] Check kernel log: sudo dmesg | tail -20"
    echo "[post-load] Set DEV to the new device, e.g.: export DEV=/dev/nvme1n1"
else
    echo "[dry-run] Set RUN=1 to actually load the module, e.g.:"
    echo "  RUN=1 bash $0"
    echo "  RUN=1 NUM_SERVICE_UNITS=4 bash $0"
    echo "  RUN=1 PIPELINED=1 bash $0"
fi
