#!/usr/bin/env bash
# scripts/swarmio_reqsize_sweep.sh — multi-page (reqsize) sweep for Experiment 1
#
# Emits extended schema CSV (scripts/swarmio_csv_schema.md + two trailing columns):
#   harness,num_service_units,N_or_iodepth,qdepth,threads,T_model_ns,measured_e2e_ns,
#   measured_MIOPS,abs_err,rel_err,reqsize_bytes,num_requests
# (T_model_ns/abs_err/rel_err left 0 — filled by scripts/swarmio_model.py)
#
# USAGE:
#   Dry run (no device access):  bash scripts/swarmio_reqsize_sweep.sh [out.csv]
#   Live run (device required):  RUN=1 bash scripts/swarmio_reqsize_sweep.sh [out.csv]
#
# Requires: swarmio built+installed, sudo, host/inflash_bench. Run from repo root.
set -euo pipefail

REPO=/home/juchanlee/nvmevirt_pim
BENCH="$REPO/host/inflash_bench"
RAW="${1:-$REPO/results_reqsize_raw.csv}"
BENCH_CPUS=16-31
TRIALS="${TRIALS:-15}"

detect_dev() {  # SwarmIO storage is 12G; boot disk is 1.8T
  local d; d=$(lsblk -dno NAME,SIZE | awk '$2=="12G"{print "/dev/"$1; exit}')
  [[ -n "$d" ]] || { echo "ERR: swarmio device not found" >&2; exit 1; }
  echo "$d"
}

median_ns() {  # stdin: numbers -> median
  sort -n | awk '{a[NR]=$1} END{print (NR? a[int((NR+1)/2)] : 0)}'
}

# ---- Dry-run: print planned sweep matrix and exit ----
if [[ -z "${RUN:-}" ]]; then
  echo "[dry-run] swarmio_reqsize_sweep.sh — planned sweep matrix" >&2
  echo "" >&2
  echo "  (A) Saturated-round sweep (S=8, total_pages=512 each):" >&2
  printf "  %-8s %-14s %-12s %-12s %-14s\n" "K_pages" "reqsize_bytes" "R=requests" "qdepth" "total_pages" >&2
  for K in 1 2 4 8 16 32; do
    reqsize=$((K * 4096))
    R=$((512 / K))
    total_pages=$((R * K))
    printf "  %-8s %-14s %-12s %-12s %-14s\n" "$K" "$reqsize" "$R" "$R" "$total_pages" >&2
  done
  echo "" >&2
  echo "  (B) Throughput-with-depth sweep (S=8, K=32, reqsize=131072):" >&2
  printf "  %-12s %-12s %-14s\n" "R=requests" "qdepth" "total_pages" >&2
  for R in 16 32 64 128 256; do
    total_pages=$((R * 32))
    printf "  %-12s %-12s %-14s\n" "$R" "$R" "$total_pages" >&2
  done
  echo "" >&2
  echo "  Output CSV : $RAW" >&2
  echo "  TRIALS     : $TRIALS" >&2
  echo "" >&2
  echo "[dry-run] Set RUN=1 to execute against device." >&2
  exit 0
fi

# ---- Live run ----
echo "harness,num_service_units,N_or_iodepth,qdepth,threads,T_model_ns,measured_e2e_ns,measured_MIOPS,abs_err,rel_err,reqsize_bytes,num_requests" > "$RAW"

echo "[sweep] loading SwarmIO S=8 for reqsize sweep..." >&2
RUN=1 NUM_SERVICE_UNITS=8 bash "$REPO/SwarmIO/scripts/load_inflash.sh" >/dev/null 2>&1
sleep 1
DEV=$(detect_dev)
echo "[sweep] device=$DEV" >&2

# run_point REQSIZE_BYTES R K_PAGES
# Runs inflash_bench and appends one CSV row.
run_point() {
  local reqsize=$1 R=$2 K=$3
  local total_pages=$((R * K))
  local e
  e=$(sudo taskset -c $BENCH_CPUS "$BENCH" --dev "$DEV" \
        --reqsize "$reqsize" --requests "$R" --qdepth "$R" --trials "$TRIALS" 2>/dev/null \
        | grep -E "^$R," | awk -F, '{print $4}' | median_ns)
  local miops
  miops=$(awk "BEGIN{printf \"%.4f\", ($e>0 ? $total_pages*1000.0/$e : 0)}")
  echo "swarmio,8,$total_pages,$R,1,0,$e,$miops,0,0.0,$reqsize,$R" >> "$RAW"
  echo "  reqsize=${reqsize}B K=${K}pages R=$R total_pages=$total_pages e2e=$((e/1000))us" >&2
}

# ---- (A) Saturated-round sweep: total_pages=512, vary K (pages per req) ----
echo "[sweep] (A) Saturated-round sweep: K in 1 2 4 8 16 32 (total_pages=512 each)..." >&2
for K in 1 2 4 8 16 32; do
  reqsize=$((K * 4096))
  R=$((512 / K))
  run_point "$reqsize" "$R" "$K"
done

# ---- (B) Throughput-with-depth sweep: K=32 (reqsize=131072), vary R ----
echo "[sweep] (B) Throughput-with-depth sweep: K=32 reqsize=131072, R in 16 32 64 128 256..." >&2
for R in 16 32 64 128 256; do
  run_point 131072 "$R" 32
done

echo "[sweep] raw CSV -> $RAW" >&2
