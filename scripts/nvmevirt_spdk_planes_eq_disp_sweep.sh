#!/usr/bin/env bash
# scripts/nvmevirt_spdk_planes_eq_disp_sweep.sh — Experiment B (report §16):
# remove the per-dispatcher SERIAL command intake by setting the number of
# activated planes equal to the number of dispatchers (P = N), so each dispatcher
# processes exactly ONE command for one plane (maximal parallelism / minimal
# serialization). Channel-affine ON => the N planes sit on N distinct channels:
# fully independent, no shared-LUN and no per-channel-lock contention, so we
# measure the pure intake/fan-out floor.
#
# Arms (single-plane = compute_sense_pages=1; SPDK host path; default knobs):
#   B1 parallel : nr_dispatchers=N, --planes N (= --threads N --requests N
#                 --chan-affine): N dispatchers, N queues, 1 cmd each.
#   B2 serial   : nr_dispatchers=1, --threads 1 --requests N --qdepth N: the SAME
#                 N planes activated by ONE dispatcher / ONE queue / N commands
#                 (the per-dispatcher serial intake baseline).
#   Sweep N = P in {1,2,4,8,16}  (<=16, the channel count).
#
#   B3 batch-depth variant (§10.4): fix N=8 (channel-affine), sweep activated
#       plane count P in {8,32,128,512} (= {N,4N,16N,64N}) so each dispatcher
#       serially processes P/N in {1,4,16,64} commands. Any climb is PURELY
#       per-dispatcher serial intake (zero cross-dispatcher lock contention).
#       P=512 (batch 64) must agree with Experiment A's N=8 affine point.
#       Optional spread overlay at P=512 separates serial-intake from contention.
#
# Metric: e2e (median over trials) to activate P planes; per-plane ns = e2e/P.
#
# CSVs to the REPO dir.  Summary -> results_nvmevirt_spdk_planes_eq_disp.csv
#                        Batch    -> results_nvmevirt_spdk_batchdepth_N8.csv
#
# GUARDED.  sudo -v first, then:
#   sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk bash scripts/nvmevirt_spdk_planes_eq_disp_sweep.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO"
SPDK_DIR="${SPDK_DIR:-/home/juchanlee/spdk}"
BENCH="$REPO/host/inflash_bench_spdk"; SETUP="$SPDK_DIR/scripts/setup.sh"
IDENT="$SPDK_DIR/build/bin/spdk_nvme_identify"
COREMASK="${COREMASK:-0x10000}"
HUGE="${HUGEPAGES:-1024}"; BDF=0001:10:00.0
MEM="memmap_start=96G memmap_size=16G"
TRIALS="${TRIALS:-30}"
SUMMARY="$REPO/results_nvmevirt_spdk_planes_eq_disp.csv"
BATCH="$REPO/results_nvmevirt_spdk_batchdepth_N8.csv"
[[ "${RUN:-0}" == "1" ]] || { echo "GUARD: set RUN=1"; exit 0; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

# N:cpus for the parallel arm — first N dispatchers, rest io_workers (>=1).
PSPECS=("1:0,1" "2:0,1,2" "4:0,1,2,3,4,5" "8:0,1,2,3,4,5,6,7,8,9" \
        "16:0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,0,1")
N8_CPUS="0,1,2,3,4,5,6,7,8,9"

med() { python3 - "$1" <<'PY'
import csv,sys,statistics
try:
    r=[int(x["t_endtoend_ns"]) for x in csv.DictReader(open(sys.argv[1]))]
    print(round(statistics.median(r)/1000,2) if r else -1)
except Exception:
    print(-1)
PY
}
load_mod() { rmmod nvmev 2>/dev/null || true
  insmod "$REPO/nvmev.ko" $MEM cpus="$1" nr_dispatchers="$2" compute_sense_pages="$3"; sleep 1; }
bind_spdk() {
  env PCI_ALLOWED=$BDF NRHUGE=$HUGE DRIVER_OVERRIDE=uio_pci_generic "$SETUP" >/dev/null 2>&1
  local out; out="$("$IDENT" -r "trtype:PCIe traddr:$BDF" 2>/dev/null)"
  echo "$out" | grep -q "NVMe Controller" && return 0 || return 1; }
unbind_spdk() { env PCI_ALLOWED=$BDF "$SETUP" reset >/dev/null 2>&1; sleep 1; }
prepop() { "$BENCH" --bdf $BDF -m $COREMASK --compute --prepopulate --maxpages 8192 \
                    --requests 1 --qdepth 1 --trials 1 --csv /dev/null >/dev/null 2>&1; }
dev_lat() { dmesg 2>/dev/null | grep "inflash_dev_lat" | tail -1 | sed 's/.*inflash_dev_lat //'; }
iow_of() { local cpus="$1" n="$2"; local cnt; cnt=$(awk -F, '{print NF}' <<<"$cpus"); echo $((cnt - n)); }

echo "phase,nr_dispatchers,cpus,io_workers,host_threads,routing,planes,qdepth,e2e_med_us,per_plane_ns,batch_depth,dev_lat" > "$SUMMARY"
cp "$SUMMARY" "$BATCH"

############### B1: parallel — P=N planes, 1 cmd/dispatcher (channel-affine) ###############
echo "=== B1 parallel: nr_dispatchers=N, --planes N (1 channel-affine cmd/dispatcher) ==="
for SPEC in "${PSPECS[@]}"; do
  N="${SPEC%%:*}"; CPUS="${SPEC##*:}"; IOW="$(iow_of "$CPUS" "$N")"
  load_mod "$CPUS" "$N" 1
  if ! bind_spdk; then echo "N=$N FAILED: identify"; unbind_spdk; continue; fi
  prepop
  C="$REPO/results_planes_par_N${N}.csv"; : > "$C"
  if [[ "$N" == "1" ]]; then
    "$BENCH" --bdf $BDF -m $COREMASK --compute --requests 1 --qdepth 1 --trials "$TRIALS" --csv "$C" >/dev/null 2>>"$REPO/.pe_err"
  else
    "$BENCH" --bdf $BDF -m $COREMASK --compute --planes "$N" --qdepth "$N" --basecore 16 --trials "$TRIALS" --csv "$C" >/dev/null 2>>"$REPO/.pe_err"
  fi
  E="$(med "$C")"; DLAT="$(dev_lat)"
  PP="$(python3 -c "print(round($E*1000/$N,1))" 2>/dev/null || echo NA)"
  printf "  N=%-3s parallel  e2e=%-9s per_plane_ns=%-9s dev=%s\n" "$N" "$E" "$PP" "$DLAT"
  echo "B1,$N,${CPUS//,/;},$IOW,$N,affine,$N,$N,$E,$PP,1,$DLAT" >> "$SUMMARY"
  unbind_spdk
done

############### B2: serial — same N planes on 1 dispatcher / 1 queue / N cmds ###############
echo "=== B2 serial: nr_dispatchers=1, --threads 1 --requests N --qdepth N ==="
load_mod "0,1" 1 1
if bind_spdk; then
  prepop
  for N in 1 2 4 8 16; do
    C="$REPO/results_planes_ser_N${N}.csv"; : > "$C"
    "$BENCH" --bdf $BDF -m $COREMASK --compute --requests "$N" --qdepth "$N" --trials "$TRIALS" --csv "$C" >/dev/null 2>>"$REPO/.pe_err"
    E="$(med "$C")"; DLAT="$(dev_lat)"
    PP="$(python3 -c "print(round($E*1000/$N,1))" 2>/dev/null || echo NA)"
    printf "  N=%-3s serial    e2e=%-9s per_plane_ns=%-9s dev=%s\n" "$N" "$E" "$PP" "$DLAT"
    echo "B2,1,0;1,1,1,serial,$N,$N,$E,$PP,$N,$DLAT" >> "$SUMMARY"
  done
  unbind_spdk
else echo "B2 FAILED: identify"; unbind_spdk; fi

############### B3: batch-depth variant — fix N=8 affine, sweep P in {8,32,128,512} ###############
echo "=== B3 batch-depth: nr_dispatchers=8 channel-affine, P in {8,32,128,512} (batch P/8) ==="
load_mod "$N8_CPUS" 8 1
if bind_spdk; then
  prepop
  IOW="$(iow_of "$N8_CPUS" 8)"
  for P in 8 32 128 512; do
    BD=$((P / 8))
    C="$REPO/results_batch_N8_P${P}.csv"; : > "$C"
    "$BENCH" --bdf $BDF -m $COREMASK --compute --requests "$P" --qdepth "$P" --threads 8 --basecore 16 --chan-affine --trials "$TRIALS" --csv "$C" >/dev/null 2>>"$REPO/.pe_err"
    E="$(med "$C")"; DLAT="$(dev_lat)"
    PP="$(python3 -c "print(round($E*1000/$P,1))" 2>/dev/null || echo NA)"
    printf "  P=%-4s batch=%-3s affine  e2e=%-9s per_plane_ns=%-9s dev=%s\n" "$P" "$BD" "$E" "$PP" "$DLAT"
    echo "B3,8,${N8_CPUS//,/;},$IOW,8,affine,$P,$P,$E,$PP,$BD,$DLAT" >> "$BATCH"
  done
  # optional spread overlay at P=512: contention adds on top of serial-intake climb
  C="$REPO/results_batch_N8_P512_spread.csv"; : > "$C"
  "$BENCH" --bdf $BDF -m $COREMASK --compute --requests 512 --qdepth 512 --threads 8 --basecore 16 --trials "$TRIALS" --csv "$C" >/dev/null 2>>"$REPO/.pe_err"
  E="$(med "$C")"; DLAT="$(dev_lat)"; PP="$(python3 -c "print(round($E*1000/512,1))" 2>/dev/null || echo NA)"
  printf "  P=512  batch=64  SPREAD  e2e=%-9s per_plane_ns=%-9s dev=%s\n" "$E" "$PP" "$DLAT"
  echo "B3,8,${N8_CPUS//,/;},$IOW,8,spread,512,512,$E,$PP,64,$DLAT" >> "$BATCH"
  unbind_spdk
else echo "B3 FAILED: identify"; unbind_spdk; fi

############### restore default ###############
echo "=== restore default (cpus=7,8, nr_dispatchers=1, compute_sense_pages=512) ==="
rmmod nvmev 2>/dev/null || true
insmod "$REPO/nvmev.ko" $MEM cpus=7,8
echo 0 > /proc/sys/vm/nr_hugepages; sleep 1
echo "restored: nr_dispatchers=$(cat /sys/module/nvmev/parameters/nr_dispatchers) compute_sense_pages=$(cat /sys/module/nvmev/parameters/compute_sense_pages) dev=$(ls /dev/nvme1n1 2>/dev/null || echo NO)"
rm -f "$REPO/.pe_err"
echo "=== summary -> $SUMMARY ==="; cat "$SUMMARY"
echo "=== batch-depth -> $BATCH ==="; cat "$BATCH"
