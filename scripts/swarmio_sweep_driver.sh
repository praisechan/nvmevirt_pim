#!/usr/bin/env bash
# scripts/swarmio_sweep_driver.sh — full in-flash-compute sweep on SwarmIO (i9-13900F)
#
# Emits schema-compliant raw CSV (scripts/swarmio_csv_schema.md):
#   harness,num_service_units,N_or_iodepth,qdepth,threads,T_model_ns,measured_e2e_ns,measured_MIOPS,abs_err,rel_err
# (T_model_ns/abs_err/rel_err left 0 — filled by scripts/swarmio_model.py)
#
# Requires: swarmio built+installed, sudo, fio, host/inflash_bench. Reloads the
# module once per num_service_units value. Run from repo root.
set -euo pipefail

REPO=/home/juchanlee/nvmevirt_pim
BENCH="$REPO/host/inflash_bench"
RAW="${1:-$REPO/results_raw.csv}"
BENCH_CPUS=16-31
FIO_RUNTIME="${FIO_RUNTIME:-2}"
TRIALS="${TRIALS:-11}"

detect_dev() {  # SwarmIO storage is 12G; boot disk is 1.8T
  local d; d=$(lsblk -dno NAME,SIZE | awk '$2=="12G"{print "/dev/"$1; exit}')
  [[ -n "$d" ]] || { echo "ERR: swarmio device not found" >&2; exit 1; }
  echo "$d"
}

median_ns() {  # stdin: numbers -> median
  sort -n | awk '{a[NR]=$1} END{print (NR? a[int((NR+1)/2)] : 0)}'
}

echo "harness,num_service_units,N_or_iodepth,qdepth,threads,T_model_ns,measured_e2e_ns,measured_MIOPS,abs_err,rel_err" > "$RAW"

# ---- NVMeVirt baseline (from prompt §1.1; num_service_units=0) ----
# N : e2e_ns
declare -A NV=( [1]=36000 [4]=40000 [8]=45000 [64]=116000 [512]=557000 [4096]=4240000 )
for N in 1 4 8 64 512 4096; do
  e=${NV[$N]}; miops=$(awk "BEGIN{printf \"%.4f\", $N*1000.0/$e}")
  echo "nvmevirt,0,$N,$N,1,0,$e,$miops,0,0.0" >> "$RAW"
done

# ---- inflash_bench latency-vs-N (single ring; load at S=8) ----
echo "[driver] loading swarmio S=8 for inflash_bench sweep..." >&2
RUN=1 NUM_SERVICE_UNITS=8 bash "$REPO/SwarmIO/scripts/load_inflash.sh" >/dev/null 2>&1
sleep 1; DEV=$(detect_dev); echo "[driver] device=$DEV" >&2
for N in 1 2 4 8 16 32 64 128 256 512 1024 2048 4096; do
  e=$(sudo taskset -c $BENCH_CPUS "$BENCH" --dev "$DEV" --requests "$N" --qdepth "$N" --trials "$TRIALS" 2>/dev/null \
        | grep -E "^$N," | awk -F, '{print $4}' | median_ns)
  miops=$(awk "BEGIN{printf \"%.4f\", ($e>0? $N*1000.0/$e : 0)}")
  echo "swarmio,8,$N,$N,1,0,$e,$miops,0,0.0" >> "$RAW"
  echo "  bench N=$N e2e=$((e/1000))us" >&2
done

# ---- fio frontend-scaling matrix: S x numjobs (iodepth=32) ----
for S in 1 2 4 8; do
  echo "[driver] reloading swarmio S=$S for fio sweep..." >&2
  RUN=1 bash "$REPO/SwarmIO/scripts/unload_inflash.sh" >/dev/null 2>&1 || true
  RUN=1 NUM_SERVICE_UNITS=$S bash "$REPO/SwarmIO/scripts/load_inflash.sh" >/dev/null 2>&1
  sleep 1; DEV=$(detect_dev)
  for J in 1 2 4 8; do
    conc=$((J*32))
    out=$(sudo fio --name=s --filename="$DEV" --direct=1 --rw=randread --bs=4k \
            --ioengine=io_uring --iodepth=32 --numjobs=$J --group_reporting \
            --runtime=$FIO_RUNTIME --time_based --cpus_allowed=$BENCH_CPUS \
            --cpus_allowed_policy=split --norandommap --randrepeat=0 2>/dev/null)
    # IOPS (handle k/M suffixes) and avg clat (usec -> ns)
    iops=$(echo "$out" | grep -oE 'IOPS=[0-9.]+[kM]?' | head -1 | sed 's/IOPS=//')
    iops_n=$(awk -v v="$iops" 'BEGIN{u=v; m=1; if(v~/k/){m=1e3;sub(/k/,"",u)} else if(v~/M/){m=1e6;sub(/M/,"",u)}; printf "%.0f", u*m}')
    miops=$(awk "BEGIN{printf \"%.4f\", $iops_n/1e6}")
    clat_us=$(echo "$out" | grep -A3 'clat (usec)' | grep -oE 'avg=[0-9.]+' | head -1 | sed 's/avg=//')
    clat_ns=$(awk "BEGIN{printf \"%.0f\", ${clat_us:-0}*1000}")
    echo "swarmio_fio,$S,$conc,32,$J,0,$clat_ns,$miops,0,0.0" >> "$RAW"
    echo "  fio S=$S J=$J conc=$conc IOPS=$iops clat=${clat_us}us" >&2
  done
done

echo "[driver] raw CSV -> $RAW" >&2
