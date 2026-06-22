#!/usr/bin/env bash
# scripts/nvmevirt_spdk_dispatcher_sweep.sh — does scaling NVMeVirt's dispatcher
# (controller-core) count lower the single-plane 512-plane-activation floor toward
# the ~30 µs flash-media round? (report §14)
#
# Faithful model: the FLASH ARRAY is fixed (16 ch x 32 LUN, tR, ch bandwidth). We
# add N dispatcher threads, each polling a disjoint subset of submission queues
# ((sqid-1)%N), and serialize the shared per-channel/LUN timing state under a
# per-channel spinlock so N controller cores contend on the one physical media
# exactly as hardware would. nr_dispatchers=1 reproduces the legacy single
# dispatcher bit-for-bit (lock uncontended).
#
# cpus= assignment: first nr_dispatchers CPUs -> dispatchers, the rest -> io_workers.
#
# Phases (single-plane = compute_sense_pages=1 unless noted; SPDK host path; default knobs):
#   D1  N=1 regression           : 1 cmd->1 plane, and 512 cmds->512 planes (qd512); amortized floor via 4096.
#   D2  dispatcher sweep (head)  : single-plane 512/4096 cmds @ qd512 across N in {1,2,4,8}.
#   D4  all-plane unaffected     : compute_sense_pages=512, 1 cmd, across the same N (dmesg must stay 34152).
#   D3  host scaling cross-check : best N, single-plane 4096 cmds @ qd512, --threads {1,2,4}.
#   D5  faithfulness (dmesg)     : single-plane per-op device latency stays 30152 ns for every N (no fabricated speedup).
#
# CSVs are written to the REPO dir (a /tmp --csv open failure wedges the controller).
# Summary -> results_nvmevirt_spdk_dispatcher_sweep.csv
#
# GUARDED.  sudo -v first, then:
#   sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk bash scripts/nvmevirt_spdk_dispatcher_sweep.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO"
SPDK_DIR="${SPDK_DIR:-/home/juchanlee/spdk}"
BENCH="$REPO/host/inflash_bench_spdk"; SETUP="$SPDK_DIR/scripts/setup.sh"
IDENT="$SPDK_DIR/build/bin/spdk_nvme_identify"
COREMASK="${COREMASK:-0x10000}"          # single E-core (cpu16) for 1-thread host path
HUGE="${HUGEPAGES:-1024}"; BDF=0001:10:00.0
MEM="memmap_start=96G memmap_size=16G"
SUMMARY="$REPO/results_nvmevirt_spdk_dispatcher_sweep.csv"
[[ "${RUN:-0}" == "1" ]] || { echo "GUARD: set RUN=1"; exit 0; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

# D2 sweep specs "N:cpus" — first N cpus are dispatchers, rest io_workers.
SPECS=("1:7,8" "2:7,8,9,10" "4:7,8,9,10,11,12" "8:1,2,3,4,5,6,7,8,9,10")
BEST_N=8; BEST_CPUS="1,2,3,4,5,6,7,8,9,10"   # for D3 host-scaling

med() { python3 - "$1" <<'PY'
import csv,sys,statistics
try:
    r=[int(x["t_endtoend_ns"]) for x in csv.DictReader(open(sys.argv[1]))]
    print(round(statistics.median(r)/1000,2) if r else -1)
except Exception:
    print(-1)
PY
}

load_mod() { # $1=cpus $2=nr_dispatchers $3=compute_sense_pages
  rmmod nvmev 2>/dev/null || true
  insmod "$REPO/nvmev.ko" $MEM cpus="$1" nr_dispatchers="$2" compute_sense_pages="$3"
  sleep 1
}
bind_spdk() {
  env PCI_ALLOWED=$BDF NRHUGE=$HUGE DRIVER_OVERRIDE=uio_pci_generic "$SETUP" >/dev/null 2>&1
  local out; out="$("$IDENT" -r "trtype:PCIe traddr:$BDF" 2>/dev/null)"   # avoid SIGPIPE from head
  echo "$out" | grep -q "NVMe Controller" && return 0 || return 1
}
unbind_spdk() { env PCI_ALLOWED=$BDF "$SETUP" reset >/dev/null 2>&1; sleep 1; }
prepop() { "$BENCH" --bdf $BDF -m $COREMASK --compute --prepopulate --maxpages 8192 \
                    --requests 1 --qdepth 1 --trials 1 --csv /dev/null >/dev/null 2>&1; }
# read the most-recent inflash_dev_lat line after issuing one fresh op
dev_lat() { dmesg 2>/dev/null | grep "inflash_dev_lat" | tail -1 | sed 's/.*inflash_dev_lat //'; }

iow_of() { # io_workers = (#cpus in list) - N
  local cpus="$1" n="$2"; local cnt; cnt=$(awk -F, '{print NF}' <<<"$cpus"); echo $((cnt - n)); }

echo "phase,nr_dispatchers,cpus,io_workers,host_threads,mode,requests,qdepth,e2e_med_us,amort_us_per_512set,per_cmd_ns,dev_lat" > "$SUMMARY"

# run a single-plane 4096-cmd (8x512-set) bench at dispatcher N, host threads T.
# Each host thread owns its own qpair => its own SQ => SQ (qid-1)%N maps to a
# dispatcher. Effective controller parallelism = min(T, N). Appends to SUMMARY.
run_sp4096() { # $1=phase $2=N $3=cpus $4=iow $5=T
  local PH="$1" N="$2" CPUS="$3" IOW="$4" T="$5"
  local C="$REPO/results_disp_N${N}_sp_4096_t${T}.csv"; : > "$C"
  if [[ "$T" == "1" ]]; then
    "$BENCH" --bdf $BDF -m $COREMASK --compute --requests 4096 --qdepth 512 --trials 10 \
             --csv "$C" >/dev/null 2>>"$REPO/.disp_err"
  else
    "$BENCH" --bdf $BDF -m $COREMASK --compute --requests 4096 --qdepth 512 --trials 10 \
             --threads "$T" --basecore 16 --csv "$C" >/dev/null 2>>"$REPO/.disp_err"
  fi
  local E; E="$(med "$C")"
  if [[ "$E" == "-1" ]]; then echo "  N=$N T=$T FAILED: $(tail -1 "$REPO/.disp_err" 2>/dev/null)"; return; fi
  local AMORT PERCMD
  AMORT="$(python3 -c "print(round($E*512/4096,2))")"
  PERCMD="$(python3 -c "print(round($E*1000/4096,1))")"
  printf "  %-3s %-3s %-12s %-12s %-12s\n" "$N" "$T" "$E" "$AMORT" "$PERCMD"
  echo "$PH,$N,${CPUS//,/;},$IOW,$T,single-plane,4096,512,$E,$AMORT,$PERCMD," >> "$SUMMARY"
}

############################ D1 + D2 : single-plane dispatcher sweep ############################
echo "=== D1/D2: single-plane dispatcher sweep. Effective parallelism = min(host_threads, nr_dispatchers). ==="
echo "    For each N: T=1 (one SQ -> one dispatcher works: flat) and T=N (N SQs -> N dispatchers: scales)."
for SPEC in "${SPECS[@]}"; do
  N="${SPEC%%:*}"; CPUS="${SPEC##*:}"; IOW="$(iow_of "$CPUS" "$N")"
  echo "--- nr_dispatchers=$N  cpus=$CPUS  io_workers=$IOW ---"
  load_mod "$CPUS" "$N" 1
  if ! bind_spdk; then echo "N=$N FAILED: identify"; unbind_spdk; continue; fi
  prepop
  # single-op (1 cmd) for D1 and dev_lat read-back
  C1="$REPO/results_disp_N${N}_sp_1.csv"; : > "$C1"
  "$BENCH" --bdf $BDF -m $COREMASK --compute --requests 1 --qdepth 1 --trials 15 --csv "$C1" >/dev/null 2>>"$REPO/.disp_err"
  E1="$(med "$C1")"; DLAT="$(dev_lat)"
  PH="D2"; [[ "$N" == "1" ]] && PH="D1"
  echo "$PH,$N,${CPUS//,/;},$IOW,1,single-plane,1,1,$E1,,,$DLAT" >> "$SUMMARY"
  echo "  single-op e2e=${E1}us  dev_lat=${DLAT}"
  printf "  %-3s %-3s %-12s %-12s %-12s\n" "N" "T" "e2e_4096us" "amort/512set" "per_cmd_ns"
  # T=1 (single host queue): adding dispatchers cannot help — proves the SQ-partition coupling
  run_sp4096 "$PH" "$N" "$CPUS" "$IOW" 1
  # T=N (host queues matched to controller cores): the headline scaling curve
  if [[ "$N" != "1" ]]; then run_sp4096 "$PH" "$N" "$CPUS" "$IOW" "$N"; fi
  # D3 host-thread sweep folded into the best-N iteration (no extra reload)
  if [[ "$N" == "$BEST_N" ]]; then
    for T in 2 4; do run_sp4096 "D3" "$N" "$CPUS" "$IOW" "$T"; done
  fi
  unbind_spdk
done

############################ D4 : all-plane unaffected by N ############################
echo "=== D4: all-plane (compute_sense_pages=512), 1 cmd, across N ==="
printf "%-3s %-22s %-10s %-22s\n" "N" "cpus" "e2e_us" "dev_lat(all-plane)"
for SPEC in "${SPECS[@]}"; do
  N="${SPEC%%:*}"; CPUS="${SPEC##*:}"; IOW="$(iow_of "$CPUS" "$N")"
  load_mod "$CPUS" "$N" 512
  if ! bind_spdk; then echo "N=$N FAILED: identify"; unbind_spdk; continue; fi
  prepop
  CAP="$REPO/results_disp_N${N}_ap_1.csv"; : > "$CAP"
  "$BENCH" --bdf $BDF -m $COREMASK --compute --requests 1 --qdepth 1 --trials 15 --csv "$CAP" >/dev/null 2>>"$REPO/.disp_err"
  EAP="$(med "$CAP")"; DLAT="$(dev_lat)"
  printf "%-3s %-22s %-10s %-22s\n" "$N" "$CPUS" "$EAP" "$DLAT"
  echo "D4,$N,${CPUS//,/;},$IOW,1,all-plane,1,1,$EAP,,,$DLAT" >> "$SUMMARY"
  unbind_spdk
done

############################ restore default ############################
echo "=== restore default (cpus=7,8, nr_dispatchers=1, compute_sense_pages=512) ==="
rmmod nvmev 2>/dev/null || true
insmod "$REPO/nvmev.ko" $MEM cpus=7,8
echo 0 > /proc/sys/vm/nr_hugepages
sleep 1
echo "restored: nr_dispatchers=$(cat /sys/module/nvmev/parameters/nr_dispatchers) compute_sense_pages=$(cat /sys/module/nvmev/parameters/compute_sense_pages) dev=$(ls /dev/nvme1n1 2>/dev/null || echo NO)"
rm -f "$REPO/.disp_err"
echo "=== summary -> $SUMMARY ==="
cat "$SUMMARY"
