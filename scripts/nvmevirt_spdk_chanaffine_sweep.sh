#!/usr/bin/env bash
# scripts/nvmevirt_spdk_chanaffine_sweep.sh — Experiment A (report §15):
# isolate per-channel media-lock contention by making each dispatcher's SQ carry
# ONLY its own channel(s), so each ch->lock is owned by exactly one dispatcher
# (uncontended), and compare against §14's spread routing at matched N.
#
# Design (host-side routing change ONLY — module config identical between arms):
#   spread  : host thread t gets a CONTIGUOUS LPN slice -> touches all 16 channels
#             -> all N dispatchers contend on all per-channel locks (= §14).
#   affine  : host thread t gets logical indices == t (mod N) (--chan-affine)
#             -> touches only channels {c: c%N==t} -> each ch->lock single-owner.
# Verified map: LPN i -> channel i%16; with N | 16, LPN i belongs to worker i%N.
#
# Direct contention evidence (Task CB) via /proc/nvmev/chstat (CONFIG_LOCK_STAT
# is OFF in this kernel, so we use the in-module trylock-fail counter): spread
# total_contended > 0 and grows with N; affine ~ 0. Affinity proof (Task CC):
# the per-(cpu,channel) hit matrix in chstat — under affine each channel column
# has exactly one non-zero CPU (dispatcher) row.
#
# Phases (single-plane = compute_sense_pages=1; SPDK host path; default knobs):
#   CA1  map/affinity verify  : affine chstat must show one cpu per channel.
#   CA2  headline             : single-plane 4096 cmds (8x512-set) @ qd512, T=N,
#                               spread vs affine for N in {4,8,16}. amortized us/512-set.
#   CA3  direct contention    : chstat total_contended spread vs affine, each N.
#   CA4  faithfulness         : dmesg per-op 30152 ns (single) / 34152 ns (all-plane).
#
# CSVs to the REPO dir.  Summary -> results_nvmevirt_spdk_chanaffine_sweep.csv
# Per-run chstat dumps -> results_chstat_N${N}_{spread,affine}.txt
#
# GUARDED.  sudo -v first, then:
#   sudo RUN=1 SPDK_DIR=/home/juchanlee/spdk bash scripts/nvmevirt_spdk_chanaffine_sweep.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO"
SPDK_DIR="${SPDK_DIR:-/home/juchanlee/spdk}"
BENCH="$REPO/host/inflash_bench_spdk"; SETUP="$SPDK_DIR/scripts/setup.sh"
IDENT="$SPDK_DIR/build/bin/spdk_nvme_identify"
COREMASK="${COREMASK:-0x10000}"
HUGE="${HUGEPAGES:-1024}"; BDF=0001:10:00.0
MEM="memmap_start=96G memmap_size=16G"
SUMMARY="$REPO/results_nvmevirt_spdk_chanaffine_sweep.csv"
CHSTAT=/proc/nvmev/chstat
[[ "${RUN:-0}" == "1" ]] || { echo "GUARD: set RUN=1"; exit 0; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

# N:cpus — first N cpus are dispatchers, the rest io_workers.
#   N=4,8 fit cleanly on P-cores (cpu0-15); N=16 oversubscribes cpu0,1 with the
#   two io_workers (documented confound, §3.4). Host on E-cores (--basecore 16).
SPECS=("4:0,1,2,3,4,5" "8:0,1,2,3,4,5,6,7,8,9" "16:0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,0,1")

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
chstat_reset() { echo 1 > "$CHSTAT" 2>/dev/null || true; }
# total_contended from chstat header line "total_acquired X total_contended Y"
chstat_contended() { grep -m1 '^total_acquired' "$CHSTAT" 2>/dev/null | awk '{print $4}'; }
chstat_acquired()  { grep -m1 '^total_acquired' "$CHSTAT" 2>/dev/null | awk '{print $2}'; }
# count of distinct CPUs touching each channel — affinity proof. Prints worst case
# (max cpus seen on any single channel): 1 => perfect affinity, >1 => contention.
chstat_max_cpus_per_ch() { python3 - "$CHSTAT" <<'PY'
import sys,collections
ch=collections.defaultdict(set)
try:
    for ln in open(sys.argv[1]):
        p=ln.split()
        if len(p)==5 and p[0]=="cpu" and p[2]=="ch":
            ch[int(p[3])].add(int(p[1]))
    print(max((len(v) for v in ch.values()), default=0))
except Exception:
    print(-1)
PY
}

echo "phase,nr_dispatchers,cpus,io_workers,host_threads,routing,requests,qdepth,e2e_med_us,amort_us_per_512set,per_cmd_ns,contended,acquired,max_cpus_per_ch,dev_lat" > "$SUMMARY"

# one single-plane 4096-cmd (8x512-set) run @ qd512, host threads T=N, given routing.
run_one() { # $1=phase $2=N $3=cpus $4=iow $5=routing(spread|affine)
  local PH="$1" N="$2" CPUS="$3" IOW="$4" RT="$5"
  local C="$REPO/results_chanaffine_N${N}_${RT}.csv"; : > "$C"
  local AFF=""; [[ "$RT" == "affine" ]] && AFF="--chan-affine"
  chstat_reset
  "$BENCH" --bdf $BDF -m $COREMASK --compute --requests 4096 --qdepth 512 --trials 10 \
           --threads "$N" --basecore 16 $AFF --csv "$C" >/dev/null 2>>"$REPO/.ca_err"
  local E; E="$(med "$C")"
  local CON ACQ MAXC; CON="$(chstat_contended)"; ACQ="$(chstat_acquired)"; MAXC="$(chstat_max_cpus_per_ch)"
  cp "$CHSTAT" "$REPO/results_chstat_N${N}_${RT}.txt" 2>/dev/null || true
  local DLAT; DLAT="$(dev_lat)"
  if [[ "$E" == "-1" ]]; then echo "  N=$N $RT FAILED: $(tail -1 "$REPO/.ca_err" 2>/dev/null)"; return; fi
  local AMORT PERCMD
  AMORT="$(python3 -c "print(round($E*512/4096,2))")"
  PERCMD="$(python3 -c "print(round($E*1000/4096,1))")"
  printf "  %-3s %-7s e2e=%-9s amort/512=%-9s ns/cmd=%-8s contended=%-10s max_cpus/ch=%-3s dev=%s\n" \
         "$N" "$RT" "$E" "$AMORT" "$PERCMD" "${CON:-NA}" "${MAXC:-NA}" "$DLAT"
  echo "$PH,$N,${CPUS//,/;},$IOW,$N,$RT,4096,512,$E,$AMORT,$PERCMD,${CON:-},${ACQ:-},${MAXC:-},$DLAT" >> "$SUMMARY"
}

############### CA2/CA3/CA1: single-plane, spread vs affine, N in {4,8,16} ###############
echo "=== CA2/CA3: single-plane 4096-cmd (8x512-set) @ qd512, T=N, spread vs affine ==="
for SPEC in "${SPECS[@]}"; do
  N="${SPEC%%:*}"; CPUS="${SPEC##*:}"; IOW="$(iow_of "$CPUS" "$N")"
  echo "--- nr_dispatchers=$N cpus=$CPUS io_workers=$IOW ---"
  load_mod "$CPUS" "$N" 1
  if ! bind_spdk; then echo "N=$N FAILED: identify"; unbind_spdk; continue; fi
  prepop
  run_one "CA2" "$N" "$CPUS" "$IOW" spread
  run_one "CA2" "$N" "$CPUS" "$IOW" affine    # CA1 affinity proof captured in chstat dump
  unbind_spdk
done

############### CA4: all-plane unaffected (compute_sense_pages=512), 1 cmd ###############
echo "=== CA4: all-plane (compute_sense_pages=512) 1 cmd — dmesg must stay 34152 ns ==="
for SPEC in "${SPECS[@]}"; do
  N="${SPEC%%:*}"; CPUS="${SPEC##*:}"; IOW="$(iow_of "$CPUS" "$N")"
  load_mod "$CPUS" "$N" 512
  if ! bind_spdk; then echo "N=$N FAILED: identify"; unbind_spdk; continue; fi
  prepop
  CAP="$REPO/results_chanaffine_N${N}_allplane.csv"; : > "$CAP"
  "$BENCH" --bdf $BDF -m $COREMASK --compute --requests 1 --qdepth 1 --trials 15 --csv "$CAP" >/dev/null 2>>"$REPO/.ca_err"
  EAP="$(med "$CAP")"; DLAT="$(dev_lat)"
  printf "  N=%-3s all-plane e2e=%-9s dev=%s\n" "$N" "$EAP" "$DLAT"
  echo "CA4,$N,${CPUS//,/;},$IOW,1,allplane,1,1,$EAP,,,,,,$DLAT" >> "$SUMMARY"
  unbind_spdk
done

############### restore default ###############
echo "=== restore default (cpus=7,8, nr_dispatchers=1, compute_sense_pages=512) ==="
rmmod nvmev 2>/dev/null || true
insmod "$REPO/nvmev.ko" $MEM cpus=7,8
echo 0 > /proc/sys/vm/nr_hugepages; sleep 1
echo "restored: nr_dispatchers=$(cat /sys/module/nvmev/parameters/nr_dispatchers) compute_sense_pages=$(cat /sys/module/nvmev/parameters/compute_sense_pages) dev=$(ls /dev/nvme1n1 2>/dev/null || echo NO)"
rm -f "$REPO/.ca_err"
echo "=== summary -> $SUMMARY ==="
cat "$SUMMARY"
