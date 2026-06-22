#!/usr/bin/env bash
# scripts/nvmevirt_spdk_exp.sh — Experiment S: SPDK (kernel-bypass) host path
# for the NVMeVirt in-flash-compute command.
#
# Pipeline:  bind device to SPDK (uio/vfio) -> identify GATE -> prepopulate ->
#            S1a/S1b/S1c -> dmesg device-model read-back -> restore kernel driver.
#
# This is the SPDK counterpart to scripts/run_compute_exp.sh. It measures host
# e2e for the 1-page --compute command through SPDK and compares to the io_uring
# numbers in results_nvmevirt_compute_raw.csv (report §11). The device model
# (inflash_dev_lat ... sensed 512 pages) must be UNCHANGED — read it from dmesg.
#
# GUARDED: does nothing unless RUN=1 (it binds the device away from the kernel
# nvme driver, which removes /dev/nvme1n1). Run as root.
#
#   sudo RUN=1 bash scripts/nvmevirt_spdk_exp.sh
#
# Env:
#   RUN=1            required to actually execute
#   BDF=0001:10:00.0 NVMeVirt PCI address (default: resolve from /dev/nvme1n1)
#   SPDK_DIR=~/spdk  SPDK source/build tree
#   HUGEPAGES=1024   2MB hugepages to reserve (default 1024 = 2 GiB)
#   CSV=results_nvmevirt_spdk_raw.csv
#   COREMASK=0xFFFF0000  SPDK core mask (E-cores 16-31), disjoint from cpus=7,8
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SPDK_DIR="${SPDK_DIR:-/home/juchanlee/spdk}"
HUGEPAGES="${HUGEPAGES:-1024}"
CSV="${CSV:-$REPO/results_nvmevirt_spdk_raw.csv}"
COREMASK="${COREMASK:-0x10000}"   # single E-core (CPU 16); disjoint from cpus=7,8
BENCH="$REPO/host/inflash_bench_spdk"
SETUP="$SPDK_DIR/scripts/setup.sh"
IDENTIFY="$SPDK_DIR/build/bin/spdk_nvme_identify"

if [[ "${RUN:-0}" != "1" ]]; then
    echo "[spdk-exp] GUARD: set RUN=1 to execute (binds device away from kernel nvme)."
    echo "          sudo RUN=1 bash scripts/nvmevirt_spdk_exp.sh"
    exit 0
fi
if [[ $EUID -ne 0 ]]; then echo "[spdk-exp] must run as root"; exit 1; fi

# ---- resolve BDF from /dev/nvme1n1 if not given ----
if [[ -z "${BDF:-}" ]]; then
    if [[ -e /sys/block/nvme1n1/device ]]; then
        BDF="$(basename "$(readlink -f /sys/block/nvme1n1/device | sed 's,/nvme/.*,,')")"
    fi
    BDF="${BDF:-0001:10:00.0}"
fi
echo "[spdk-exp] REPO=$REPO  SPDK_DIR=$SPDK_DIR  BDF=$BDF  CSV=$CSV  COREMASK=$COREMASK"
[[ -x "$BENCH" ]]    || { echo "ERROR: $BENCH not built (make -C host spdk)"; exit 1; }
[[ -x "$SETUP" ]]    || { echo "ERROR: $SETUP not found"; exit 1; }

restore() {
    echo "[spdk-exp] ===== restoring kernel nvme driver (setup.sh reset) ====="
    PCI_ALLOWED="$BDF" "$SETUP" reset || "$SETUP" reset || true
    sleep 1; ls -l /dev/nvme1n1 2>/dev/null && echo "[spdk-exp] /dev/nvme1n1 restored" \
        || echo "[spdk-exp] WARN: /dev/nvme1n1 not back — check 'dmesg' / re-run scripts/load.sh"
}
trap restore EXIT

# ---- bind: only the NVMeVirt BDF, never the real boot SSD ----
echo "[spdk-exp] ===== binding $BDF to SPDK (hugepages=$HUGEPAGES) ====="
# Force uio_pci_generic: the emulated device has no IOMMU group (synthetic PCI
# root bus), so vfio-pci cannot bind it (probe fails -22). PCI_ALLOWED scopes the
# bind to ONLY this BDF so the boot SSD / other NVMeVirt devices are untouched.
export PCI_ALLOWED="$BDF" NRHUGE="$HUGEPAGES" DRIVER_OVERRIDE="uio_pci_generic"
"$SETUP" status || true
"$SETUP"
echo "[spdk-exp] post-bind status:"; "$SETUP" status || true

# ---- GATE: identify must enumerate the controller ----
echo "[spdk-exp] ===== GATE: identify ====="
if [[ -x "$IDENTIFY" ]]; then
    # Capture first, THEN truncate for display — piping identify into `head`
    # makes head close the pipe early, identify gets SIGPIPE (rc 141), and a
    # successful enumeration is wrongly read as a gate failure.
    IDENT_OUT="$("$IDENTIFY" -r "trtype:PCIe traddr:$BDF" 2>&1)"; GATE_RC=$?
    echo "$IDENT_OUT" | head -40
    echo "[spdk-exp] identify rc=$GATE_RC"
    [[ $GATE_RC -eq 0 ]] || { echo "[spdk-exp] GATE FAILED — SPDK could not enumerate $BDF"; exit 2; }
else
    echo "[spdk-exp] WARN: $IDENTIFY missing; relying on bench probe as the gate"
fi

run() {  # $1=label  $2..=bench args
    local label="$1"; shift
    echo ""; echo "------------------------------------------------------------------"
    echo "[spdk-exp] $label  args: $*"
    echo "------------------------------------------------------------------"
    dmesg -C
    "$BENCH" --bdf "$BDF" -m "$COREMASK" "$@"
    echo "[spdk-exp] device-observed latency (model, source of truth):"
    dmesg | grep inflash_dev_lat | tail -3
}

# Prepopulate once (mandatory: cold LPNs read instantly and fake convergence).
echo "[spdk-exp] ===== prepopulate 4096 pages ====="
dmesg -C
"$BENCH" --bdf "$BDF" -m "$COREMASK" --compute --prepopulate --maxpages 4096 \
         --requests 1 --qdepth 1 --trials 1 --csv /dev/null

# S1a — single compute command (headline vs io_uring ~48us, device ~34us)
run "S1a single compute cmd"      --compute --requests 1 --qdepth 1 --trials 15 --csv "$CSV"
# S1b — pipelined compute commands (vs io_uring E3b ~52us)
run "S1b pipelined (qd8)"         --compute --requests 8 --qdepth 8 --trials 15 --csv "$CSV"
# S1c — sequential compute commands (vs io_uring E3a ~337us; per-op p50)
run "S1c sequential (qd1)"        --compute --requests 8 --qdepth 1 --trials 15 --csv "$CSV"

echo ""; echo "[spdk-exp] ===== done. CSV: $CSV ====="
# restore() runs via EXIT trap
