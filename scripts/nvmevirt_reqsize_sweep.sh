#!/usr/bin/env bash
# scripts/nvmevirt_reqsize_sweep.sh — multi-page (reqsize) sweep for NVMeVirt
# Experiment 4.A (prompts/NVMEVIRT_MULTIPAGE_FOLLOWUP_PROMPT.md §4.A)
#
# Emits extended schema CSV (scripts/swarmio_csv_schema.md + two trailing columns):
#   harness,num_service_units,N_or_iodepth,qdepth,threads,T_model_ns,measured_e2e_ns,
#   measured_MIOPS,abs_err,rel_err,reqsize_bytes,num_requests
# (T_model_ns/abs_err/rel_err left 0 — filled by scripts/swarmio_model.py)
#
# num_service_units = 0 for all nvmevirt rows.
#   Rationale: the CSV schema (scripts/swarmio_csv_schema.md col 2) specifies
#   "Set to 0 for nvmevirt rows (no service-unit concept)." NVMeVirt's 512
#   independent LUNs (16ch × 32lun/ch) are a fixed geometry property, not a
#   configurable service-unit count as in SwarmIO.
#
# N_or_iodepth = total_pages (= R × K pages), so swarmio_model.py enriches
#   correctly using T_model = 38000 × ceil(total_pages / 512) ns.
#
# Bench output format (host/inflash_bench.c):
#   CSV header:  requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns
#   Data row:    8,8,0,32600000,32500000,32700000
#   Parsing:     grep "^$R," | awk -F, '{print $4}'   → t_endtoend_ns (field 4)
#   Median over all TRIALS rows → measured_e2e_ns.
#
# USAGE:
#   Dry run (no device access):  bash scripts/nvmevirt_reqsize_sweep.sh [out.csv]
#   Live run (device required):  RUN=1 bash scripts/nvmevirt_reqsize_sweep.sh [out.csv]
#
# Environment overrides:
#   DEV     — block device (default /dev/nvme1n1; must not be /dev/nvme0*)
#   TRIALS  — measurement trials per point (default 15)
#
# Requires: host/inflash_bench built, sudo, scripts/load.sh. Run from repo root.

set -euo pipefail

REPO=/home/juchanlee/nvmevirt_pim
BENCH="$REPO/host/inflash_bench"
RAW="${1:-$REPO/results_nvmevirt_reqsize_raw.csv}"
BENCH_CPUS=16-31
TRIALS="${TRIALS:-15}"

# ---- Device detection ----
# Prefer /dev/nvme1n1; allow DEV env override.
# Safety: reject /dev/nvme0* (the ~1.8 TB boot disk).
detect_dev() {
  local d="${DEV:-/dev/nvme1n1}"
  if [[ "$d" == /dev/nvme0* ]]; then
    echo "ERR: refusing to use $d — that is the boot disk (nvme0*). Set DEV to nvme1n1." >&2
    exit 1
  fi
  if [[ ! -b "$d" ]]; then
    echo "ERR: $d not found as a block device." >&2
    echo "ERR: Load NVMeVirt first: bash scripts/load.sh" >&2
    echo "ERR: Then check: lsblk | grep nvme" >&2
    exit 1
  fi
  echo "$d"
}

# ---- Median helper (stdin: one number per line -> median) ----
median_ns() {
  sort -n | awk '{a[NR]=$1} END{print (NR? a[int((NR+1)/2)] : 0)}'
}

# ===========================================================================
# Dry-run: print planned sweep matrix and exit (default — RUN unset)
# ===========================================================================
if [[ -z "${RUN:-}" ]]; then
  echo "[dry-run] nvmevirt_reqsize_sweep.sh — planned sweep matrix" >&2
  echo "" >&2
  echo "  NVMeVirt geometry : 512 LUNs (16ch × 32lun/ch), FLASH_PAGE_SIZE=4KB" >&2
  echo "  MDTS=6 (ssd_config.h) → 2^6 × 4KB = 256KB = 64 pages max per NVMe command" >&2
  echo "  Runtime MDTS check: cat /sys/block/nvme1n1/queue/max_hw_sectors_kb  (expect ~256)" >&2
  echo "" >&2
  echo "  harness    : nvmevirt" >&2
  echo "  num_service_units : 0  (no service-unit concept for NVMeVirt; geometry is fixed)" >&2
  echo "  N_or_iodepth : total_pages = R × K  (used by swarmio_model.py enrichment)" >&2
  echo "" >&2
  echo "  (A) Saturated-round sweep (total_pages=512 each, MDTS=6 allows K up to 64):" >&2
  printf "  %-8s %-14s %-12s %-12s %-14s\n" "K_pages" "reqsize_bytes" "R=requests" "qdepth" "total_pages" >&2
  for K in 1 2 4 8 16 32 64; do
    reqsize=$((K * 4096))
    R=$((512 / K))
    total_pages=$((R * K))
    printf "  %-8s %-14s %-12s %-12s %-14s\n" "$K" "$reqsize" "$R" "$R" "$total_pages" >&2
  done
  echo "" >&2
  echo "  (B) Throughput-with-depth sweep (fixed K=64, reqsize=262144, multiple rounds):" >&2
  printf "  %-12s %-12s %-14s %-16s\n" "R=requests" "qdepth" "total_pages" "rounds(~512LUN)" >&2
  for R in 8 16 32 64 128; do
    total_pages=$((R * 64))
    rounds=$(( (total_pages + 511) / 512 ))
    printf "  %-12s %-12s %-14s %-16s\n" "$R" "$R" "$total_pages" "$rounds" >&2
  done
  echo "" >&2
  echo "  Output CSV : $RAW" >&2
  echo "  TRIALS     : $TRIALS" >&2
  echo "  Bench cmd  : sudo taskset -c $BENCH_CPUS $BENCH --dev DEV --reqsize R --requests N --qdepth N --trials $TRIALS" >&2
  echo "  CSV schema : harness,num_service_units,N_or_iodepth,qdepth,threads," >&2
  echo "               T_model_ns,measured_e2e_ns,measured_MIOPS,abs_err,rel_err," >&2
  echo "               reqsize_bytes,num_requests" >&2
  echo "" >&2
  echo "[dry-run] Set RUN=1 to execute against the NVMeVirt device." >&2
  exit 0
fi

# ===========================================================================
# Live run
# ===========================================================================
echo "harness,num_service_units,N_or_iodepth,qdepth,threads,T_model_ns,measured_e2e_ns,measured_MIOPS,abs_err,rel_err,reqsize_bytes,num_requests" > "$RAW"

echo "[sweep] Loading NVMeVirt (memmap_start=96G memmap_size=16G)..." >&2
bash "$REPO/scripts/load.sh"
sleep 2

DEV=$(detect_dev)
echo "[sweep] device=$DEV" >&2

# ---- MDTS runtime check ----
DEV_NAME=$(basename "$DEV")
MAX_HW_KB=$(cat /sys/block/"${DEV_NAME}"/queue/max_hw_sectors_kb 2>/dev/null || echo 0)
echo "[sweep] max_hw_sectors_kb=$MAX_HW_KB" >&2
if [[ "$MAX_HW_KB" -eq 256 ]]; then
  echo "[sweep] MDTS=6 confirmed: K<=64 pages/req (256KB max) is valid." >&2
  MAX_K=64
elif [[ "$MAX_HW_KB" -gt 0 ]]; then
  MAX_K=$(( MAX_HW_KB / 4 ))
  echo "[sweep] WARN: max_hw_sectors_kb=$MAX_HW_KB (expected 256 for MDTS=6)." >&2
  echo "[sweep] WARN: recomputed MAX_K=$MAX_K pages/req. Adjusting sweep accordingly." >&2
else
  echo "[sweep] WARN: could not read max_hw_sectors_kb; assuming MDTS=6 (MAX_K=64)." >&2
  MAX_K=64
fi

# ---- Prepopulate maptbl (REQUIRED on NVMeVirt) ----
# conv_read (conv_ftl.c:889) SKIPS unmapped/invalid LPNs — a read to a page that
# was never written charges ZERO NAND latency and returns instantly, producing
# false "convergence". (SwarmIO has no maptbl, so its port omits this step.)
# load.sh reloads the module above, wiping the maptbl, so we must prepopulate now.
# Max LPN touched: sweep (B) R=128,K=64 -> offsets tile LPN 0..8191, so cover 8192.
PREPOP_PAGES="${PREPOP_PAGES:-8192}"
echo "[sweep] Prepopulating $PREPOP_PAGES pages (writes valid maptbl entries so reads charge tR)..." >&2
sudo taskset -c $BENCH_CPUS "$BENCH" --dev "$DEV" --requests 1 --trials 0 \
     --prepopulate --maxpages "$PREPOP_PAGES" 2>&1 | grep -E '^\[prepopulate\]|ERROR' >&2 || true

# ---- run_point REQSIZE_BYTES R K_PAGES ----
# Issues inflash_bench, captures stdout, parses t_endtoend_ns (field 4 of each
# data row: requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns), takes median,
# and appends one CSV row to $RAW.
run_point() {
  local reqsize=$1 R=$2 K=$3
  local total_pages=$((R * K))
  local e
  # Bench prints CSV to stdout (no --csv flag). Header row starts with "requests,"
  # so grep "^$R," selects only data rows matching this R value.
  # Field 4 = t_endtoend_ns (batch wall-clock first-submit → last-completion, ns).
  e=$(sudo taskset -c $BENCH_CPUS "$BENCH" \
        --dev "$DEV" \
        --reqsize "$reqsize" \
        --requests "$R" \
        --qdepth   "$R" \
        --trials   "$TRIALS" \
        2>/dev/null \
      | grep -E "^$R," | awk -F, '{print $4}' | median_ns)
  local miops
  # MIOPS = total_pages × 10³ / e2e_ns  (pages per microsecond = pages × 10³ / ns)
  miops=$(awk "BEGIN{printf \"%.4f\", ($e>0 ? $total_pages*1000.0/$e : 0)}")
  echo "nvmevirt,0,$total_pages,$R,1,0,$e,$miops,0,0.0,$reqsize,$R" >> "$RAW"
  echo "  reqsize=${reqsize}B  K=${K}pages  R=$R  total_pages=$total_pages  e2e=$((e/1000))us" >&2
}

# ---- (A) Saturated-round sweep: total_pages=512, vary K (pages per req) ----
echo "[sweep] (A) Saturated-round sweep: K in {1,2,4,8,16,32,64} (total_pages=512)..." >&2
for K in 1 2 4 8 16 32 64; do
  if [[ "$K" -gt "$MAX_K" ]]; then
    echo "  SKIP K=$K (exceeds max_hw_sectors_kb=${MAX_HW_KB}KB = ${MAX_K} pages/req)" >&2
    continue
  fi
  reqsize=$((K * 4096))
  R=$((512 / K))
  run_point "$reqsize" "$R" "$K"
done

# ---- (B) Throughput-with-depth sweep: fixed K=64 (reqsize=262144), vary R ----
echo "[sweep] (B) Throughput-with-depth sweep: K=64 reqsize=262144, R in {8,16,32,64,128}..." >&2
if [[ 64 -le "$MAX_K" ]]; then
  for R in 8 16 32 64 128; do
    run_point 262144 "$R" 64
  done
else
  echo "  SKIP sweep (B): K=64 pages/req exceeds device limit MAX_K=$MAX_K" >&2
fi

echo "[sweep] Done. Raw CSV -> $RAW" >&2
echo "[sweep] Next step: python3 scripts/swarmio_model.py $RAW results_nvmevirt_reqsize_enriched.csv" >&2

# ===========================================================================
# Exp 4.B — MDTS=9 rebuild/revert procedure
# DOCUMENTATION ONLY — do NOT execute this section.
# Surface to the user for interactive execution in a shell.
#
# Purpose:
#   Raise MDTS from 6 → 9 so one NVMe command spans all 512 LUNs (2^9=512 pages=2MB).
#   This isolates the single-dispatcher bottleneck most cleanly: only one command to
#   fetch per round → zero dispatcher serialization → pure device timing observable.
#
# Expected result:
#   max_hw_sectors_kb ≈ 2048 (MDTS=9: 2^9 × 4KB = 2048KB).
#   One 2MB request → one command → all 512 LUNs active in parallel.
#   Device e2e ≈ tR + fully-emergent t_cmd ≈ 32.6µs (at default knobs:
#     COMPUTE_RESULT_SIZE=64B, NAND_CHANNEL_BANDWIDTH=800MB/s →
#     t_cmd = 32 LUNs/ch × 64B / 800MB/s × 16ch-serialize ≈ 2.6µs).
#
# CAUTION: edits ssd_config.h and rebuilds the kernel module.
#   Run as user, not via this script. Revert MDTS=6 afterward.
#
# Step 1 — Raise MDTS in ssd_config.h (do NOT use this script to do it):
#
#   cd /home/juchanlee/nvmevirt_pim
#   # Find the INFLASH_PIM MDTS line; it reads: #define MDTS (6)
#   grep -n 'define MDTS' ssd_config.h
#   # Edit the line manually or via sed:
#   sed -i 's/#define MDTS (6)/#define MDTS (9)/' ssd_config.h
#   grep 'define MDTS' ssd_config.h    # verify: #define MDTS (9)
#
# Step 2 — Rebuild NVMeVirt:
#
#   bash scripts/build.sh
#
# Step 3 — Unload old module and reload new .ko:
#
#   sudo rmmod nvmev 2>/dev/null || true
#   bash scripts/load.sh
#   # Confirm updated MDTS limit:
#   cat /sys/block/nvme1n1/queue/max_hw_sectors_kb    # expect ~2048
#
# Step 4 — Single-command 2MB request (one command → all 512 LUNs):
#
#   sudo taskset -c 16-31 host/inflash_bench \
#     --dev /dev/nvme1n1 \
#     --reqsize 2097152 \
#     --requests 1 --qdepth 1 \
#     --trials 15
#   # Expected: device e2e ≈ tR + fully-emergent t_cmd ≈ 32.6µs.
#   # Compare to K=64 (8 commands) baseline from sweep (A) above.
#
# Optional — extended sweep at MDTS=9 (reqsize in {256KB,512KB,1MB,2MB}, qdepth=1):
#
#   for bytes in 262144 524288 1048576 2097152; do
#     pages=$(( bytes / 4096 ))
#     sudo taskset -c 16-31 host/inflash_bench \
#       --dev /dev/nvme1n1 --reqsize $bytes --requests 1 --qdepth 1 --trials 15
#   done
#
# Step 5 — REVERT (restore MDTS=6; keep default profile realistic):
#
#   sed -i 's/#define MDTS (9)/#define MDTS (6)/' ssd_config.h
#   grep 'define MDTS' ssd_config.h    # verify: #define MDTS (6)
#   bash scripts/build.sh
#   sudo rmmod nvmev 2>/dev/null || true
#   bash scripts/load.sh
#   cat /sys/block/nvme1n1/queue/max_hw_sectors_kb    # expect ~256
#
# max_hw_sectors_kb derivation:
#   MDTS=6 → 2^6 × 4KB =  256KB → max_hw_sectors_kb ~256
#   MDTS=9 → 2^9 × 4KB = 2048KB → max_hw_sectors_kb ~2048
# ===========================================================================
