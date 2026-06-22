#!/usr/bin/env bash
# scripts/nvmevirt_spdk_mode_exp.sh — compare all-plane vs single-plane compute
# modes through the SPDK host path.
#
#   ALL-PLANE   (compute_sense_pages=512): 1 single-page NVMe req senses all 512 planes
#   SINGLE-PLANE(compute_sense_pages=1)  : 1 single-page NVMe req senses 1 plane;
#                                          512 planes => 512 NVMe reqs
#
# For each mode: rmmod+insmod nvmev with the param, bind the NVMeVirt BDF to SPDK
# (uio_pci_generic), prepopulate, run the relevant request counts, read the device
# latency from dmesg, then restore the kernel nvme driver.
#
# GUARDED: RUN=1 required. Run as root.
#   sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk bash scripts/nvmevirt_spdk_mode_exp.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
SPDK_DIR="${SPDK_DIR:-/home/juchanlee/spdk}"
HUGEPAGES="${HUGEPAGES:-1024}"
COREMASK="${COREMASK:-0x10000}"
BENCH="$REPO/host/inflash_bench_spdk"
SETUP="$SPDK_DIR/scripts/setup.sh"
IDENTIFY="$SPDK_DIR/build/bin/spdk_nvme_identify"
KO="$REPO/nvmev.ko"
CSV="${CSV:-$REPO/results_nvmevirt_spdk_modes_raw.csv}"

if [[ "${RUN:-0}" != "1" ]]; then echo "GUARD: set RUN=1"; exit 0; fi
if [[ $EUID -ne 0 ]]; then echo "must run as root"; exit 1; fi
[[ -x "$BENCH" ]] || { echo "ERROR: build bench: make -C host spdk"; exit 1; }

: > "$CSV"   # fresh; bench appends header on first write

resolve_bdf() {  # nvmev device (not nvmev_rr) reclaims 0001:10:00.0
    local b; b="$(readlink -f /sys/block/nvme1n1/device 2>/dev/null | sed 's,/nvme/.*,,')"
    echo "${b##*/}"
}

run_mode() {  # $1=sense_pages  $2=label
    local SENSE="$1" LABEL="$2"
    echo ""; echo "=================================================================="
    echo "[mode] $LABEL  (compute_sense_pages=$SENSE)"
    echo "=================================================================="
    # reload module with the mode param
    rmmod nvmev 2>/dev/null || true
    insmod "$KO" memmap_start=96G memmap_size=16G cpus=7,8 compute_sense_pages="$SENSE"
    sleep 1
    local BDF; BDF="$(resolve_bdf)"
    echo "[mode] BDF=$BDF  /dev/nvme1n1 present? $(ls /dev/nvme1n1 2>/dev/null || echo NO)"
    echo "[mode] dmesg param check:"; dmesg | grep -iE 'compute_sense|nvme1:' | tail -2

    # bind to SPDK
    PCI_ALLOWED="$BDF" NRHUGE="$HUGEPAGES" DRIVER_OVERRIDE="uio_pci_generic" "$SETUP" >/dev/null 2>&1
    IDENT="$("$IDENTIFY" -r "trtype:PCIe traddr:$BDF" 2>&1)"; echo "[mode] identify rc=$? ($(echo "$IDENT" | grep -c PCIE) ctrlr)"

    # prepopulate
    "$BENCH" --bdf "$BDF" -m "$COREMASK" --compute --prepopulate --maxpages 4096 \
             --requests 1 --qdepth 1 --trials 1 --csv /dev/null 2>/dev/null

    bench_run() {  # $1=reqs $2=qd $3=tag(sanitized)
        local tagcsv="$REPO/results_spdk_${3}.csv"; : > "$tagcsv"
        echo "------ $LABEL: $3  (requests=$1 qdepth=$2)  -> $tagcsv ------"
        dmesg -C
        "$BENCH" --bdf "$BDF" -m "$COREMASK" --compute --requests "$1" --qdepth "$2" \
                 --trials 15 --csv "$tagcsv" 2>&1 | grep -E 'trial'
        echo "  [dmesg] device latency / sensed pages (first 3):"
        dmesg | grep inflash_dev_lat | head -3
        echo "  [dmesg] inflash_dev_lat lines this run: $(dmesg | grep -c inflash_dev_lat)"
    }

    if [[ "$SENSE" == "512" ]]; then
        bench_run 1 1     "allplane_1req_512planes"     # all-plane: one command, all planes
    else
        bench_run 1 1     "singleplane_1req_1plane"          # single-plane: one command, one plane
        bench_run 512 512 "singleplane_512req_512planes_qd512"  # 512 cmds, max parallel
        bench_run 512 64  "singleplane_512req_512planes_qd64"
    fi

    PCI_ALLOWED="$BDF" "$SETUP" reset >/dev/null 2>&1
    sleep 1; echo "[mode] restored: $(ls /dev/nvme1n1 2>/dev/null || echo NO-nvme1n1)"
}

run_mode 512 "ALL-PLANE"
run_mode 1   "SINGLE-PLANE"

echo ""; echo "[mode-exp] done. CSV rows tagged by requests/qdepth in: $CSV"