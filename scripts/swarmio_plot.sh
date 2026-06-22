#!/usr/bin/env bash
# scripts/swarmio_plot.sh — Plot SwarmIO in-flash compute results via gnuplot
#
# Reads an ENRICHED CSV (produced by scripts/swarmio_model.py) and emits 3 figures:
#   (a) fig_latency_vs_N.png    — latency vs N (log-x), curves: NVMeVirt baseline,
#                                   SwarmIO S={1,2,4,8}, T_model overlaid
#   (b) fig_rel_error_vs_N.png  — relative error (%) vs N (log-x)
#   (c) fig_miops_vs_N.png      — achieved MIOPS vs N (log-x)
#
# Usage:
#   bash scripts/swarmio_plot.sh [ENRICHED_CSV [OUTPUT_DIR]]
#
#   ENRICHED_CSV  default: results_enriched.csv (repo root)
#   OUTPUT_DIR    default: same directory as ENRICHED_CSV
#
# If gnuplot is NOT installed this script:
#   1. Prints a clear "gnuplot not found" message with install hint.
#   2. Falls back to generating markdown-table summaries of the same data.
#
# CSV column positions (see scripts/swarmio_csv_schema.md):
#   1:harness  2:num_service_units  3:N_or_iodepth  4:qdepth  5:threads
#   6:T_model_ns  7:measured_e2e_ns  8:measured_MIOPS  9:abs_err  10:rel_err

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENRICHED_CSV="${1:-${REPO_DIR}/results_enriched.csv}"
OUTPUT_DIR="${2:-$(dirname "${ENRICHED_CSV}")}"

if [[ ! -f "${ENRICHED_CSV}" ]]; then
    echo "[swarmio_plot] ERROR: CSV not found: ${ENRICHED_CSV}"
    echo "               Produce it with:"
    echo "               python3 scripts/swarmio_model.py raw.csv ${ENRICHED_CSV}"
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

echo "[swarmio_plot] Input CSV : ${ENRICHED_CSV}"
echo "[swarmio_plot] Output dir: ${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Helper: extract one data series from CSV into a gnuplot-friendly dat file
#   extract_series <csv> <out_dat> <harness_filter> <svc_units_filter>
#   Columns in dat: col1=N  col2=latency_us  col3=rel_err_pct  col4=miops  col5=tmodel_us
# ---------------------------------------------------------------------------
extract_series() {
    local csv="$1" dat="$2" harness="$3" svc="$4"
    # Skip header, filter by harness + num_service_units, sort by N, convert to µs
    awk -F',' -v h="$harness" -v s="$svc" '
        NR==1 { next }
        $1==h && ($2==s || (h=="nvmevirt" && s=="0")) {
            n     = $3 + 0
            tm_us = ($6 > 0 ? $6/1000.0 : 0)
            e2e_us= ($7 > 0 ? $7/1000.0 : 0)
            miops = $8 + 0
            rel_p = $10 * 100.0
            print n, e2e_us, rel_p, miops, tm_us
        }
    ' "$csv" | sort -k1,1n > "$dat"
}

# ---------------------------------------------------------------------------
# Build temp data files
# ---------------------------------------------------------------------------
TMPDIR_PLOT=$(mktemp -d /tmp/swarmio_plot_XXXXXX)
trap "rm -rf '${TMPDIR_PLOT}'" EXIT

extract_series "${ENRICHED_CSV}" "${TMPDIR_PLOT}/nvmevirt.dat"  "nvmevirt" "0"
extract_series "${ENRICHED_CSV}" "${TMPDIR_PLOT}/swarmio_s1.dat" "swarmio"  "1"
extract_series "${ENRICHED_CSV}" "${TMPDIR_PLOT}/swarmio_s2.dat" "swarmio"  "2"
extract_series "${ENRICHED_CSV}" "${TMPDIR_PLOT}/swarmio_s4.dat" "swarmio"  "4"
extract_series "${ENRICHED_CSV}" "${TMPDIR_PLOT}/swarmio_s8.dat" "swarmio"  "8"
# T_model from nvmevirt rows (same formula, harness-independent)
awk -F',' 'NR==1{next} $6>0 {n=$3+0; tm=$6/1000.0; print n, tm}' \
    "${ENRICHED_CSV}" | sort -k1,1n | uniq > "${TMPDIR_PLOT}/tmodel.dat"

# ---------------------------------------------------------------------------
# Reqsize experiment opt-in: activated when CSV contains 'num_requests' column
# ---------------------------------------------------------------------------
HAS_REQSIZE=0
if head -1 "${ENRICHED_CSV}" | grep -q "num_requests"; then
    HAS_REQSIZE=1
    # Saturated-round rows (N_or_iodepth==512): emit (num_requests, latency_us)
    awk -F',' '
        NR==1 {
            for (i=1;i<=NF;i++) {
                if ($i=="num_requests")    nr_col=i
                if ($i=="measured_e2e_ns") e2e_col=i
            }
            next
        }
        nr_col>0 && e2e_col>0 && $3+0==512 && $e2e_col+0>0 {
            print $nr_col+0, $e2e_col/1000.0
        }
    ' "${ENRICHED_CSV}" | sort -k1,1n > "${TMPDIR_PLOT}/reqsize_latency.dat"
    has_reqsize_dat=0
    [[ -s "${TMPDIR_PLOT}/reqsize_latency.dat" ]] && has_reqsize_dat=1
fi

echo "[swarmio_plot] Extracted data series."

# Count non-empty series
has_nvmevirt=0; [[ -s "${TMPDIR_PLOT}/nvmevirt.dat"  ]] && has_nvmevirt=1
has_s1=0;       [[ -s "${TMPDIR_PLOT}/swarmio_s1.dat" ]] && has_s1=1
has_s2=0;       [[ -s "${TMPDIR_PLOT}/swarmio_s2.dat" ]] && has_s2=1
has_s4=0;       [[ -s "${TMPDIR_PLOT}/swarmio_s4.dat" ]] && has_s4=1
has_s8=0;       [[ -s "${TMPDIR_PLOT}/swarmio_s8.dat" ]] && has_s8=1
has_tmodel=0;   [[ -s "${TMPDIR_PLOT}/tmodel.dat"     ]] && has_tmodel=1

# ===========================================================================
# GNUPLOT PATH
# ===========================================================================
if command -v gnuplot >/dev/null 2>&1; then
    echo "[swarmio_plot] gnuplot found: $(gnuplot --version)"

    # -----------------------------------------------------------------------
    # Build a multi-plot gnuplot script
    # -----------------------------------------------------------------------
    GPSCRIPT="${TMPDIR_PLOT}/swarmio_plots.gp"
    cat > "${GPSCRIPT}" << GNUPLOT_EOF
# Auto-generated by scripts/swarmio_plot.sh — do not edit by hand

set datafile separator whitespace
set key top left font ",10"
set grid xtics ytics lt 0 lw 1 lc rgb "#aaaaaa"
set border lw 1.5

# Common x-axis: log2 scale, labelled at powers of 2
set logscale x 2
set format x "2^{%L}"
set xlabel "Number of concurrent requests (N)" font ",11"

# ---------------------------------------------------------------------------
# (a) Latency vs N
# ---------------------------------------------------------------------------
set terminal pngcairo size 900,520 enhanced font "Sans,11" linewidth 1.5
set output '${OUTPUT_DIR}/fig_latency_vs_N.png'

set title "SwarmIO In-Flash Compute: End-to-End Latency vs N\n{/*0.85 i9-13900F, no DSA, num\\_sched\\_insts=512, T_{model}=38µs·⌈N/512⌉}" font ",12"
set ylabel "End-to-end latency (µs)" font ",11"
set yrange [0:*]

# Linestyles
set style line 1  lt 1 lc rgb "#555555" lw 2.5 dt 2   # T_model (dashed)
set style line 2  lt 1 lc rgb "#999999" lw 2   pt 4    # NVMeVirt baseline (grey)
set style line 3  lt 1 lc rgb "#d73027" lw 1.8 pt 6    # SwarmIO S=1
set style line 4  lt 1 lc rgb "#fc8d59" lw 1.8 pt 8    # SwarmIO S=2
set style line 5  lt 1 lc rgb "#4dac26" lw 1.8 pt 10   # SwarmIO S=4
set style line 6  lt 1 lc rgb "#1a6faf" lw 1.8 pt 12   # SwarmIO S=8

plot \\
GNUPLOT_EOF

    # Build plot command dynamically based on which series have data
    PLOT_CMDS=()
    [[ $has_tmodel  -eq 1 ]] && PLOT_CMDS+=("'${TMPDIR_PLOT}/tmodel.dat'     using 1:2 with lines ls 1 title 'T_{model}=38µs·⌈N/512⌉'")
    [[ $has_nvmevirt -eq 1 ]] && PLOT_CMDS+=("'${TMPDIR_PLOT}/nvmevirt.dat'  using 1:2 with linespoints ls 2 title 'NVMeVirt baseline'")
    [[ $has_s1      -eq 1 ]] && PLOT_CMDS+=("'${TMPDIR_PLOT}/swarmio_s1.dat' using 1:2 with linespoints ls 3 title 'SwarmIO S=1'")
    [[ $has_s2      -eq 1 ]] && PLOT_CMDS+=("'${TMPDIR_PLOT}/swarmio_s2.dat' using 1:2 with linespoints ls 4 title 'SwarmIO S=2'")
    [[ $has_s4      -eq 1 ]] && PLOT_CMDS+=("'${TMPDIR_PLOT}/swarmio_s4.dat' using 1:2 with linespoints ls 5 title 'SwarmIO S=4'")
    [[ $has_s8      -eq 1 ]] && PLOT_CMDS+=("'${TMPDIR_PLOT}/swarmio_s8.dat' using 1:2 with linespoints ls 6 title 'SwarmIO S=8'")

    if [[ ${#PLOT_CMDS[@]} -eq 0 ]]; then
        echo "set label 'No data' at graph 0.5,0.5 center" >> "${GPSCRIPT}"
        echo "plot 1/0 notitle" >> "${GPSCRIPT}"
    else
        # Join with gnuplot line-continuation (", \" + newline + indent)
        JOINED=""
        for c in "${PLOT_CMDS[@]}"; do
            if [[ -n "$JOINED" ]]; then JOINED="$JOINED, \\"$'\n'"     $c"; else JOINED="$c"; fi
        done
        echo "${JOINED}" >> "${GPSCRIPT}"
    fi

    # -----------------------------------------------------------------------
    # (b) Relative error vs N
    # -----------------------------------------------------------------------
    cat >> "${GPSCRIPT}" << GNUPLOT_EOF2

# ---------------------------------------------------------------------------
# (b) Relative error vs N
# ---------------------------------------------------------------------------
set output '${OUTPUT_DIR}/fig_rel_error_vs_N.png'
set title "SwarmIO In-Flash Compute: Relative Error vs N\n{/*0.85 (measured − T_{model}) / T_{model} × 100%}" font ",12"
set ylabel "Relative error (%)" font ",11"
set yrange [*:*]

plot \\
GNUPLOT_EOF2

    PLOT_CMDS2=()
    [[ $has_nvmevirt -eq 1 ]] && PLOT_CMDS2+=("'${TMPDIR_PLOT}/nvmevirt.dat'  using 1:3 with linespoints ls 2 title 'NVMeVirt baseline'")
    [[ $has_s1      -eq 1 ]] && PLOT_CMDS2+=("'${TMPDIR_PLOT}/swarmio_s1.dat' using 1:3 with linespoints ls 3 title 'SwarmIO S=1'")
    [[ $has_s2      -eq 1 ]] && PLOT_CMDS2+=("'${TMPDIR_PLOT}/swarmio_s2.dat' using 1:3 with linespoints ls 4 title 'SwarmIO S=2'")
    [[ $has_s4      -eq 1 ]] && PLOT_CMDS2+=("'${TMPDIR_PLOT}/swarmio_s4.dat' using 1:3 with linespoints ls 5 title 'SwarmIO S=4'")
    [[ $has_s8      -eq 1 ]] && PLOT_CMDS2+=("'${TMPDIR_PLOT}/swarmio_s8.dat' using 1:3 with linespoints ls 6 title 'SwarmIO S=8'")

    if [[ ${#PLOT_CMDS2[@]} -eq 0 ]]; then
        echo "plot 1/0 notitle" >> "${GPSCRIPT}"
    else
        JOINED2=""
        for c in "${PLOT_CMDS2[@]}"; do
            if [[ -n "$JOINED2" ]]; then JOINED2="$JOINED2, \\"$'\n'"     $c"; else JOINED2="$c"; fi
        done
        echo "${JOINED2}" >> "${GPSCRIPT}"
    fi

    # -----------------------------------------------------------------------
    # (c) MIOPS vs N
    # -----------------------------------------------------------------------
    cat >> "${GPSCRIPT}" << GNUPLOT_EOF3

# ---------------------------------------------------------------------------
# (c) Achieved MIOPS vs N
# ---------------------------------------------------------------------------
set output '${OUTPUT_DIR}/fig_miops_vs_N.png'
set title "SwarmIO In-Flash Compute: Achieved MIOPS vs N\n{/*0.85 T_{max}(faithful)≈13.5 MIOPS; T_{max}(pipelined)=64 MIOPS}" font ",12"
set ylabel "Achieved MIOPS" font ",11"
set yrange [0:*]

# T_max reference lines
set arrow 1 from graph 0, first 13.47 to graph 1, first 13.47 nohead lt 0 lw 1.5 lc rgb "#555555"
set label 1 "T_{max}≈13.5 (faithful)" at graph 0.02, first 14.2 font ",9" tc rgb "#555555"

plot \\
GNUPLOT_EOF3

    PLOT_CMDS3=()
    [[ $has_nvmevirt -eq 1 ]] && PLOT_CMDS3+=("'${TMPDIR_PLOT}/nvmevirt.dat'  using 1:4 with linespoints ls 2 title 'NVMeVirt baseline'")
    [[ $has_s1      -eq 1 ]] && PLOT_CMDS3+=("'${TMPDIR_PLOT}/swarmio_s1.dat' using 1:4 with linespoints ls 3 title 'SwarmIO S=1'")
    [[ $has_s2      -eq 1 ]] && PLOT_CMDS3+=("'${TMPDIR_PLOT}/swarmio_s2.dat' using 1:4 with linespoints ls 4 title 'SwarmIO S=2'")
    [[ $has_s4      -eq 1 ]] && PLOT_CMDS3+=("'${TMPDIR_PLOT}/swarmio_s4.dat' using 1:4 with linespoints ls 5 title 'SwarmIO S=4'")
    [[ $has_s8      -eq 1 ]] && PLOT_CMDS3+=("'${TMPDIR_PLOT}/swarmio_s8.dat' using 1:4 with linespoints ls 6 title 'SwarmIO S=8'")

    if [[ ${#PLOT_CMDS3[@]} -eq 0 ]]; then
        echo "plot 1/0 notitle" >> "${GPSCRIPT}"
    else
        JOINED3=""
        for c in "${PLOT_CMDS3[@]}"; do
            if [[ -n "$JOINED3" ]]; then JOINED3="$JOINED3, \\"$'\n'"     $c"; else JOINED3="$c"; fi
        done
        echo "${JOINED3}" >> "${GPSCRIPT}"
    fi

    # -----------------------------------------------------------------------
    # (d) Reqsize: latency vs submission count (opt-in, reqsize CSV only)
    # -----------------------------------------------------------------------
    if [[ $HAS_REQSIZE -eq 1 ]]; then
        cat >> "${GPSCRIPT}" << GNUPLOT_EOF4

# ---------------------------------------------------------------------------
# (d) Latency vs host submission count (reqsize experiment, N_or_iodepth==512)
# ---------------------------------------------------------------------------
unset arrow 1
unset label 1
set output '${OUTPUT_DIR}/fig_latency_vs_submissions.png'
set title "SwarmIO In-Flash Compute: Latency vs Host Submission Count\n{/*0.85 Saturated-round rows (total\\_pages=512); T_{model}=38 µs}" font ",12"
set xlabel "Host submission count (num\\_requests)" font ",11"
set ylabel "End-to-end latency (µs)" font ",11"
set yrange [0:*]
set arrow 2 from graph 0, first 38 to graph 1, first 38 nohead lt 0 lw 1.5 lc rgb "#555555"
set label 2 "T_{model}=38 µs (1 round)" at graph 0.02, first 40 font ",9" tc rgb "#555555"
GNUPLOT_EOF4

        if [[ $has_reqsize_dat -eq 1 ]]; then
            echo "plot '${TMPDIR_PLOT}/reqsize_latency.dat' using 1:2 with linespoints lt 1 lc rgb \"#d73027\" lw 1.8 pt 6 title 'measured e2e (µs)'" >> "${GPSCRIPT}"
        else
            echo "plot 1/0 notitle" >> "${GPSCRIPT}"
        fi
    fi

    # Run gnuplot
    gnuplot "${GPSCRIPT}"
    echo "[swarmio_plot] Figures written to ${OUTPUT_DIR}/"
    ls -lh "${OUTPUT_DIR}"/fig_*.png 2>/dev/null || true

# ===========================================================================
# FALLBACK: gnuplot absent — emit markdown tables
# ===========================================================================
else
    echo ""
    echo "============================================================"
    echo " WARNING: gnuplot not found — cannot produce PNG figures."
    echo " Install with:  sudo apt install gnuplot"
    echo " Then re-run:   bash scripts/swarmio_plot.sh ${ENRICHED_CSV}"
    echo ""
    echo " Falling back to markdown-table summary of available data."
    echo "============================================================"
    echo ""

    MDOUT="${OUTPUT_DIR}/fig_tables_fallback.md"
    {
        echo "# SwarmIO Plot Fallback — Markdown Tables"
        echo ""
        echo "> **gnuplot not available.** Run \`sudo apt install gnuplot\` then"
        echo "> re-run \`bash scripts/swarmio_plot.sh\` to generate PNG figures."
        echo "> These tables cover the same data as the three planned figures."
        echo ""

        # -----------------------------------------------------------------------
        # Table (a): Latency vs N
        # -----------------------------------------------------------------------
        echo "## (a) End-to-End Latency vs N (µs)"
        echo ""
        echo "| N | T_model (µs) | NVMeVirt (µs) | SwarmIO S=1 | S=2 | S=4 | S=8 |"
        echo "|--:|-------------:|--------------:|------------:|----:|----:|----:|"

        # Collect all N values
        ALL_N=$(awk -F',' 'NR>1 {print $3+0}' "${ENRICHED_CSV}" | sort -n | uniq)

        for n in $ALL_N; do
            tm=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $6>0 {print $6/1000.0; exit}' "${ENRICHED_CSV}")
            nv=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="nvmevirt"  && $7>0 {print $7/1000.0; exit}' "${ENRICHED_CSV}")
            s1=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==1 && $7>0 {print $7/1000.0; exit}' "${ENRICHED_CSV}")
            s2=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==2 && $7>0 {print $7/1000.0; exit}' "${ENRICHED_CSV}")
            s4=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==4 && $7>0 {print $7/1000.0; exit}' "${ENRICHED_CSV}")
            s8=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==8 && $7>0 {print $7/1000.0; exit}' "${ENRICHED_CSV}")
            printf "| %5d | %12s | %13s | %11s | %3s | %3s | %3s |\n" \
                "$n" "${tm:----}" "${nv:----}" "${s1:----}" "${s2:----}" "${s4:----}" "${s8:----}"
        done

        echo ""

        # -----------------------------------------------------------------------
        # Table (b): Relative error vs N (%)
        # -----------------------------------------------------------------------
        echo "## (b) Relative Error vs N (%)"
        echo ""
        echo "| N | NVMeVirt | SwarmIO S=1 | S=2 | S=4 | S=8 |"
        echo "|--:|---------:|------------:|----:|----:|----:|"

        for n in $ALL_N; do
            nv=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="nvmevirt" && $10!="0.0" && $10!="0" {printf "%.1f%%", $10*100; exit}' "${ENRICHED_CSV}")
            s1=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==1 && $10!="0.0" {printf "%.1f%%", $10*100; exit}' "${ENRICHED_CSV}")
            s2=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==2 && $10!="0.0" {printf "%.1f%%", $10*100; exit}' "${ENRICHED_CSV}")
            s4=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==4 && $10!="0.0" {printf "%.1f%%", $10*100; exit}' "${ENRICHED_CSV}")
            s8=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==8 && $10!="0.0" {printf "%.1f%%", $10*100; exit}' "${ENRICHED_CSV}")
            printf "| %5d | %8s | %11s | %3s | %3s | %3s |\n" \
                "$n" "${nv:----}" "${s1:----}" "${s2:----}" "${s4:----}" "${s8:----}"
        done

        echo ""

        # -----------------------------------------------------------------------
        # Table (c): MIOPS vs N
        # -----------------------------------------------------------------------
        echo "## (c) Achieved MIOPS vs N"
        echo ""
        echo "| N | NVMeVirt | SwarmIO S=1 | S=2 | S=4 | S=8 |"
        echo "|--:|---------:|------------:|----:|----:|----:|"

        for n in $ALL_N; do
            nv=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="nvmevirt" && $8+0>0 {printf "%.3f", $8+0; exit}' "${ENRICHED_CSV}")
            s1=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==1 && $8+0>0 {printf "%.3f", $8+0; exit}' "${ENRICHED_CSV}")
            s2=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==2 && $8+0>0 {printf "%.3f", $8+0; exit}' "${ENRICHED_CSV}")
            s4=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==4 && $8+0>0 {printf "%.3f", $8+0; exit}' "${ENRICHED_CSV}")
            s8=$(awk -F',' -v n="$n" 'NR>1 && $3+0==n && $1=="swarmio" && $2+0==8 && $8+0>0 {printf "%.3f", $8+0; exit}' "${ENRICHED_CSV}")
            printf "| %5d | %8s | %11s | %3s | %3s | %3s |\n" \
                "$n" "${nv:----}" "${s1:----}" "${s2:----}" "${s4:----}" "${s8:----}"
        done

        echo ""
        echo "_T_max (faithful) ≈ 13.47 MIOPS; T_max (pipelined) = 64 MIOPS_"

        # -----------------------------------------------------------------------
        # Table (d): Reqsize — latency vs submission count (opt-in)
        # -----------------------------------------------------------------------
        if [[ $HAS_REQSIZE -eq 1 && ${has_reqsize_dat:-0} -eq 1 ]]; then
            echo ""
            echo "## (d) Latency vs Host Submission Count (Saturated-round rows, N=512)"
            echo ""
            echo "| num_requests | Latency (µs) |"
            echo "|-------------:|-------------:|"
            while IFS=' ' read -r nr lat; do
                printf "| %12d | %12.1f |\n" "$nr" "$lat"
            done < "${TMPDIR_PLOT}/reqsize_latency.dat"
            echo ""
            echo "_Horizontal reference: T_model = 38 µs (1 saturated round)_"
        fi

    } > "${MDOUT}"

    echo "[swarmio_plot] Fallback tables written to: ${MDOUT}"
fi
