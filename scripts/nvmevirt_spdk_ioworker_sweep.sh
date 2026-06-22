#!/usr/bin/env bash
# scripts/nvmevirt_spdk_ioworker_sweep.sh — does adding NVMeVirt io_workers lower
# the single-plane command-throughput floor (the §13.4 ~139 us/512-set asymptote)?
#
# NVMeVirt threading: cpus=<list> => first CPU is the (single) dispatcher, the rest
# are io_workers. So cpus=7,8 -> 1 worker; 7,8,9,10 -> 3; 7,8,9,10,11,12 -> 5.
# Single-plane mode (compute_sense_pages=1), SPDK host path, qd512.
#
# For each worker count: reload module, bind SPDK, prepopulate, measure
#   N=512  (one 512-plane set) and N=4096 (8 sets -> amortized floor = e2e/8).
# CSVs go to the REPO dir (a /tmp --csv open failure wedges the controller).
#
# GUARDED: RUN=1, root.   sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk bash scripts/nvmevirt_spdk_ioworker_sweep.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO"
SPDK_DIR="${SPDK_DIR:-/home/juchanlee/spdk}"
BENCH="$REPO/host/inflash_bench_spdk"; SETUP="$SPDK_DIR/scripts/setup.sh"
IDENT="$SPDK_DIR/build/bin/spdk_nvme_identify"
COREMASK="${COREMASK:-0x10000}"; HUGE="${HUGEPAGES:-1024}"; BDF=0001:10:00.0
[[ "${RUN:-0}" == "1" ]] || { echo "GUARD: set RUN=1"; exit 0; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

med() { python3 - "$1" <<'PY'
import csv,sys,statistics
r=[int(x["t_endtoend_ns"]) for x in csv.DictReader(open(sys.argv[1]))]
print(round(statistics.median(r)/1000,2) if r else -1)
PY
}

printf "%-9s %-8s %-15s %-18s %-12s\n" "workers" "cpus" "e2e_512_us" "amort_us/512set" "per_cmd_ns"
for SPEC in "1:7,8" "3:7,8,9,10" "5:7,8,9,10,11,12"; do
  W="${SPEC%%:*}"; CPUS="${SPEC##*:}"
  rmmod nvmev 2>/dev/null || true
  insmod "$REPO/nvmev.ko" memmap_start=96G memmap_size=16G cpus="$CPUS" compute_sense_pages=1
  sleep 1
  env PCI_ALLOWED=$BDF NRHUGE=$HUGE DRIVER_OVERRIDE=uio_pci_generic "$SETUP" >/dev/null 2>&1
  "$IDENT" -r "trtype:PCIe traddr:$BDF" >/dev/null 2>&1 || { echo "$W FAILED: identify"; \
        env PCI_ALLOWED=$BDF "$SETUP" reset >/dev/null 2>&1; continue; }
  # prepopulate
  "$BENCH" --bdf $BDF -m $COREMASK --compute --prepopulate --maxpages 8192 \
           --requests 1 --qdepth 1 --trials 1 --csv /dev/null >/dev/null 2>&1
  C512="$REPO/results_spdk_iow${W}_N512.csv";  : > "$C512"
  C4096="$REPO/results_spdk_iow${W}_N4096.csv"; : > "$C4096"
  "$BENCH" --bdf $BDF -m $COREMASK --compute --requests 512  --qdepth 512 --trials 10 --csv "$C512"  >/dev/null 2>"$REPO/.iow_err"
  "$BENCH" --bdf $BDF -m $COREMASK --compute --requests 4096 --qdepth 512 --trials 10 --csv "$C4096" >/dev/null 2>>"$REPO/.iow_err"
  E512="$(med "$C512")"; E4096="$(med "$C4096")"
  if [[ "$E512" == "-1" || "$E4096" == "-1" ]]; then
     echo "$W FAILED: $(tail -1 "$REPO/.iow_err")"
  else
     AMORT="$(python3 -c "print(round($E4096*512/4096,2))")"
     PERCMD="$(python3 -c "print(round($E4096*1000/4096,1))")"
     printf "%-9s %-8s %-15s %-18s %-12s\n" "$W" "$CPUS" "$E512" "$AMORT" "$PERCMD"
  fi
  env PCI_ALLOWED=$BDF "$SETUP" reset >/dev/null 2>&1
  sleep 1
done

echo "=== restore default all-plane (cpus=7,8, compute_sense_pages=512) ==="
rmmod nvmev 2>/dev/null || true
insmod "$REPO/nvmev.ko" memmap_start=96G memmap_size=16G cpus=7,8
echo 0 > /proc/sys/vm/nr_hugepages
sleep 1
echo "restored: param=$(cat /sys/module/nvmev/parameters/compute_sense_pages) dev=$(ls /dev/nvme1n1 2>/dev/null||echo NO)"
rm -f "$REPO/.iow_err"