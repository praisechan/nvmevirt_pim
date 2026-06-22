#!/usr/bin/env bash
# scripts/nvmevirt_plot.sh — Plot NVMeVirt multi-page in-flash compute results via gnuplot
#
# Produces 3 figures reflecting the MEASURED findings of the NVMeVirt follow-up:
#   (a) fig_nvmevirt_e2e_vs_cmdcount.png   — HOST e2e (µs) vs command-count-per-round R
#         (saturated 512-LUN round). Overlays: 512×4KB baseline, multi-page measured
#         curve, 38µs analytic T_model reference, and the flat ~30µs DEVICE-latency floor.
#         KEY RESULT: host e2e only falls modestly (single io_worker per-page sim cost);
#         it never reaches the device floor — multi-page packing helps but does not converge.
#   (b) fig_nvmevirt_tcmd_vs_lunsperch.png — emergent t_cmd (DEVICE latency − tR) vs active
#         LUNs/channel, from results_nvmevirt_tcmd_raw.csv. Two series:
#         COMPUTE_RESULT_SIZE=64B (default → flat ~0.15µs) and =4096B (§5 side-run → scales).
#         KEY RESULT: at the default 64B result the emergent t_cmd is ~152ns and FLAT;
#         the channel model only serializes (t_cmd grows with LUNs/ch) for large results.
#   (c) fig_nvmevirt_vs_swarmio.png        — NVMeVirt vs SwarmIO host-e2e-vs-R overlay.
#
# Usage:
#   bash scripts/nvmevirt_plot.sh [ENRICHED_CSV [TCMD_CSV [SWARMIO_CSV [OUTPUT_DIR]]]]
#     ENRICHED_CSV  default results_nvmevirt_reqsize_enriched.csv  (12-col extended schema)
#     TCMD_CSV      default results_nvmevirt_tcmd_raw.csv
#                   (cols: compute_result_size,reqsize_bytes,pages,luns_total,luns_per_ch,device_lat_ns,t_cmd_ns)
#     SWARMIO_CSV   default results_reqsize_enriched.csv
#     OUTPUT_DIR    default repo root
#
# Each figure is skipped gracefully if its input is absent. gnuplot 5.4; matplotlib/pip3 NOT used.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENRICHED_CSV="${1:-${REPO_DIR}/results_nvmevirt_reqsize_enriched.csv}"
TCMD_CSV="${2:-${REPO_DIR}/results_nvmevirt_tcmd_raw.csv}"
SWARMIO_CSV="${3:-${REPO_DIR}/results_reqsize_enriched.csv}"
OUTPUT_DIR="${4:-${REPO_DIR}}"

echo "[nvmevirt_plot] enriched : ${ENRICHED_CSV}"
echo "[nvmevirt_plot] tcmd     : ${TCMD_CSV}"
echo "[nvmevirt_plot] swarmio  : ${SWARMIO_CSV}"
echo "[nvmevirt_plot] outdir   : ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

command -v gnuplot >/dev/null 2>&1 || { echo "[nvmevirt_plot] ERROR: gnuplot not found"; exit 1; }

TMP=$(mktemp -d /tmp/nvmevirt_plot_XXXXXX); trap "rm -rf '${TMP}'" EXIT

# --- (a) host e2e vs R for the saturated round (N_or_iodepth=512) ---
# Output: R  host_e2e_us   (dedup R, take min e2e if duplicated)
extract_satround() {  # csv dat harness
  awk -F',' -v hf="$3" '
    NR==1 { for(i=1;i<=NF;i++){h=tolower($i);gsub(/[[:space:]]/,"",h);c[h]=i}
            hc=c["harness"];nc=c["n_or_iodepth"];ec=c["measured_e2e_ns"];rc=c["num_requests"];next }
    hc&&$(hc)==hf && nc&&$(nc)+0==512 && ec&&$(ec)+0>0 {
      r=(rc?$(rc)+0:$(nc)+0); e=$(ec)/1000.0; if(!(r in m)||e<m[r]) m[r]=e }
    END { for(r in m) print r, m[r] }
  ' "$1" | sort -k1,1n > "$2"
}

# --- (b) device t_cmd vs luns/channel, split by compute_result_size ---
extract_tcmd() {  # csv crs dat
  awk -F',' -v crs="$2" '
    NR==1 { for(i=1;i<=NF;i++){h=tolower($i);gsub(/[[:space:]]/,"",h);c[h]=i}
            sc=c["compute_result_size"];lc=c["luns_per_ch"];tc=c["t_cmd_ns"];next }
    sc&&$(sc)+0==crs+0 { print $(lc)+0, ($(tc)/1000.0) }
  ' "$1" | sort -k1,1n > "$3"
}

[[ -f "$ENRICHED_CSV" ]] && extract_satround "$ENRICHED_CSV" "$TMP/nv_sat.dat" "nvmevirt" || : > "$TMP/nv_sat.dat"
[[ -f "$SWARMIO_CSV"  ]] && extract_satround "$SWARMIO_CSV"  "$TMP/sw_sat.dat" "swarmio"  || : > "$TMP/sw_sat.dat"
[[ -f "$TCMD_CSV" ]] && { extract_tcmd "$TCMD_CSV" 64 "$TMP/tcmd_64.dat"; extract_tcmd "$TCMD_CSV" 4096 "$TMP/tcmd_4096.dat"; } || { : > "$TMP/tcmd_64.dat"; : > "$TMP/tcmd_4096.dat"; }

has() { [[ -s "$1" ]]; }

# baseline (max R) and device floor
BASE=$(awk 'END{printf "%.1f", (NR? $2:557.0)}' "$TMP/nv_sat.dat" 2>/dev/null || echo 557.0)
[[ -z "$BASE" ]] && BASE=557.0
DEV_FLOOR_US=30.15   # measured device latency (nsecs_target-nsecs_start), flat across load
REF_38=38.0

GP="$TMP/p.gp"
cat > "$GP" <<EOF
set datafile separator whitespace
set grid lt 0 lw 1 lc rgb "#bbbbbb"
set border lw 1.5
set style line 1 lt 1 lc rgb "#d73027" lw 2.2 pt 7 ps 1.3
set style line 2 lt 1 lc rgb "#1a6faf" lw 2.2 pt 9 ps 1.3
set style line 3 lt 1 lc rgb "#4dac26" lw 2.2 pt 5 ps 1.3
set terminal pngcairo size 920,540 enhanced font "Sans,11" linewidth 1.5
EOF

# ---- (a) ----
cat >> "$GP" <<EOF
set output '${OUTPUT_DIR}/fig_nvmevirt_e2e_vs_cmdcount.png'
set title "NVMeVirt INFLASH_PIM: Host E2E vs Command Count per 512-LUN Round\\n{/*0.82 MDTS=6; single dispatcher+io\\_worker (cpus=7,8); device latency (nsecs\\_target-nsecs\\_start) is flat ~30µs}"
set xlabel "Commands per round  R = 512/K  (K = pages per command)"
set ylabel "Latency (µs)"
set logscale x 2
set format x "2^{%L}"
set yrange [0:*]
set key top left font ",10"
EOF
if has "$TMP/nv_sat.dat"; then
cat >> "$GP" <<EOF
plot ${REF_38} w lines dt 3 lw 1.5 lc rgb "#555555" title 'T_{model}=38µs (analytic ref)', \\
     ${DEV_FLOOR_US} w lines dt 2 lw 2.0 lc rgb "#1a6faf" title 'Device latency floor ~30.15µs (faithful model)', \\
     '$TMP/nv_sat.dat' u 1:2 w linespoints ls 1 title 'NVMeVirt host e2e (measured)'
EOF
else
echo "set label 1 'No NVMeVirt data' at graph 0.5,0.5 center; plot 1/0 notitle" >> "$GP"
fi

# ---- (b) ----
cat >> "$GP" <<EOF
unset logscale x
unset format x
unset label 1
set output '${OUTPUT_DIR}/fig_nvmevirt_tcmd_vs_lunsperch.png'
set title "NVMeVirt INFLASH_PIM: Emergent t_{cmd} vs Active LUNs per Channel\\n{/*0.82 t_{cmd}=device latency − tR(30µs), one command (MDTS=9 probe). Channel: UNIT\\_XFER=128B, 26 credits/4µs}"
set xlabel "Active LUNs per channel (single command spanning that many LUNs/ch)"
set ylabel "Emergent t_{cmd} = device latency − tR  (µs)"
set xrange [0:34]
set yrange [0:*]
set key top left font ",10"
EOF
if has "$TMP/tcmd_64.dat" || has "$TMP/tcmd_4096.dat"; then
  PB=()
  has "$TMP/tcmd_64.dat"   && PB+=("'$TMP/tcmd_64.dat' u 1:2 w linespoints ls 3 title 'COMPUTE\\_RESULT\\_SIZE=64B (default → flat ~0.15µs)'")
  has "$TMP/tcmd_4096.dat" && PB+=("'$TMP/tcmd_4096.dat' u 1:2 w linespoints ls 1 title 'COMPUTE\\_RESULT\\_SIZE=4096B (§5 side-run → emergent, scales)'")
  J="${PB[0]}"; for ((i=1;i<${#PB[@]};i++)); do J="$J, \\
     ${PB[$i]}"; done
  echo "plot $J" >> "$GP"
else
echo "set label 2 'No t_cmd data' at graph 0.5,0.5 center; plot 1/0 notitle" >> "$GP"
fi

# ---- (c) ----
cat >> "$GP" <<EOF
unset label 2
set output '${OUTPUT_DIR}/fig_nvmevirt_vs_swarmio.png'
set title "NVMeVirt vs SwarmIO: Host E2E vs Command Count per Round\\n{/*0.82 Both present a 512-unit round; NVMeVirt=faithful plane+channel model, SwarmIO=parameterized delay}"
set xlabel "Commands / submissions per round (R)"
set ylabel "Host e2e latency (µs)"
set logscale x 2
set format x "2^{%L}"
set yrange [0:*]
set key top left font ",10"
EOF
PC=()
( has "$TMP/nv_sat.dat" || has "$TMP/sw_sat.dat" ) && PC+=("${REF_38} w lines dt 3 lw 1.5 lc rgb '#555555' title 'T_{model}=38µs'")
has "$TMP/nv_sat.dat" && PC+=("'$TMP/nv_sat.dat' u 1:2 w linespoints ls 1 title 'NVMeVirt (faithful model)'")
has "$TMP/sw_sat.dat" && PC+=("'$TMP/sw_sat.dat' u 1:2 w linespoints ls 2 title 'SwarmIO (parameterized sched\\_delay)'")
if [[ ${#PC[@]} -gt 0 ]]; then
  J="${PC[0]}"; for ((i=1;i<${#PC[@]};i++)); do J="$J, \\
     ${PC[$i]}"; done
  echo "plot $J" >> "$GP"
else
echo "set label 3 'No data' at graph 0.5,0.5 center; plot 1/0 notitle" >> "$GP"
fi

echo "[nvmevirt_plot] running gnuplot..."
gnuplot "$GP"
echo "[nvmevirt_plot] done:"
ls -lh "${OUTPUT_DIR}"/fig_nvmevirt_*.png 2>/dev/null || echo "(none)"
