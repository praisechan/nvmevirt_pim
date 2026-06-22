#!/usr/bin/env python3
"""
scripts/plot.py — Plot INFLASH_PIM latency sweep results

Reads results.csv produced by sweep.sh and saves two PNGs:
  (a) latency_vs_N.png   — end-to-end latency vs N: T_model vs measured
  (b) relative_error.png — relative error = (measured - model) / model × 100%

Usage:
    python3 scripts/plot.py [results.csv]

Default CSV path: results.csv in the same directory as this script.

Requires: pip install matplotlib pandas
"""

import sys
import os
import math
import csv
from pathlib import Path
from collections import defaultdict

# ------------------------------------------------------------------ #
# Import check                                                         #
# ------------------------------------------------------------------ #
try:
    import matplotlib
    matplotlib.use("Agg")          # non-interactive backend
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
except ImportError:
    print("ERROR: matplotlib not found. Install with:")
    print("  pip install matplotlib")
    sys.exit(1)

try:
    import pandas as pd
except ImportError:
    pd = None   # pandas optional — we have a CSV fallback


# ------------------------------------------------------------------ #
# Load CSV                                                             #
# ------------------------------------------------------------------ #

def load_csv(path: Path):
    """Return dict {N: {e2e_us: [...], model_us: float}}."""
    if pd is not None:
        df = pd.read_csv(path)
        # Rename for convenience
        df["e2e_us"]   = df["t_endtoend_ns"] / 1e3
        df["model_us"] = df["t_model_ns"]    / 1e3
        result = {}
        for n, grp in df.groupby("requests"):
            result[int(n)] = {
                "e2e_us":   grp["e2e_us"].tolist(),
                "model_us": grp["model_us"].iloc[0],
            }
        return result

    # Pure stdlib fallback
    data = defaultdict(list)
    header = None
    with open(path, newline="") as f:
        for row in csv.reader(f):
            if header is None:
                header = {name: idx for idx, name in enumerate(row)}
                continue
            n       = int(row[header["requests"]])
            e2e_us  = float(row[header["t_endtoend_ns"]]) / 1e3
            model_us= float(row[header["t_model_ns"]])    / 1e3
            data[n].append((e2e_us, model_us))

    result = {}
    for n, rows in data.items():
        result[n] = {
            "e2e_us":   [r[0] for r in rows],
            "model_us": rows[0][1],
        }
    return result


# ------------------------------------------------------------------ #
# Statistics helpers                                                   #
# ------------------------------------------------------------------ #

def median(vals):
    s = sorted(vals)
    m = len(s) // 2
    return (s[m] + s[m - 1]) / 2 if len(s) % 2 == 0 else s[m]

def pct(vals, p):
    s = sorted(vals)
    idx = int(p / 100 * (len(s) - 1) + 0.5)
    return s[max(0, min(idx, len(s) - 1))]


# ------------------------------------------------------------------ #
# Plots                                                                #
# ------------------------------------------------------------------ #

def plot_latency(data: dict, out_path: Path):
    """(a) Latency vs N — T_model vs measured."""
    ns      = sorted(data.keys())
    model   = [data[n]["model_us"]             for n in ns]
    med_e2e = [median(data[n]["e2e_us"])        for n in ns]
    p50_e2e = [pct(data[n]["e2e_us"], 50)       for n in ns]
    p99_e2e = [pct(data[n]["e2e_us"], 99)       for n in ns]

    fig, ax = plt.subplots(figsize=(9, 5))

    ax.plot(ns, model,   "k--",  linewidth=2,   label=r"$T_{model}(N) = 38\,\mu s \cdot \lceil N/512 \rceil$")
    ax.plot(ns, med_e2e, "b-o",  linewidth=1.5, markersize=5, label="Measured median end-to-end")
    ax.fill_between(ns, p50_e2e, p99_e2e, alpha=0.2, color="blue", label="p50–p99 band")

    ax.set_xscale("log", base=2)
    ax.set_xlabel("Number of requests (N)", fontsize=12)
    ax.set_ylabel("Latency (µs)", fontsize=12)
    ax.set_title("INFLASH_PIM: End-to-End Latency vs N", fontsize=13)
    ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
    ax.set_xticks(ns)
    ax.grid(True, which="both", linestyle="--", alpha=0.5)
    ax.legend(fontsize=10)

    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"[plot] Saved: {out_path}")


def plot_relative_error(data: dict, out_path: Path):
    """(b) Relative error vs N = (measured - model) / model × 100 %."""
    ns  = sorted(data.keys())
    err = []
    for n in ns:
        mod = data[n]["model_us"]
        med = median(data[n]["e2e_us"])
        err.append((med - mod) / mod * 100.0 if mod > 0 else 0.0)

    fig, ax = plt.subplots(figsize=(9, 4))

    ax.bar([str(n) for n in ns], err, color=["#d62728" if e > 0 else "#1f77b4" for e in err])
    ax.axhline(0, color="black", linewidth=0.8)
    ax.set_xlabel("Number of requests (N)", fontsize=12)
    ax.set_ylabel("Relative error (%)", fontsize=12)
    ax.set_title("INFLASH_PIM: (Measured − Model) / Model × 100%", fontsize=13)
    ax.tick_params(axis="x", rotation=45)
    ax.grid(True, axis="y", linestyle="--", alpha=0.5)

    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"[plot] Saved: {out_path}")


# ------------------------------------------------------------------ #
# Entry point                                                          #
# ------------------------------------------------------------------ #

def main():
    default_csv = Path(__file__).parent.parent / "results.csv"
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else default_csv

    if not csv_path.exists():
        print(f"ERROR: CSV not found: {csv_path}")
        print("Run scripts/sweep.sh first to generate results.csv")
        sys.exit(1)

    print(f"[plot] Reading: {csv_path}")
    data = load_csv(csv_path)
    print(f"[plot] {len(data)} distinct N values: {sorted(data.keys())}")

    base_dir = csv_path.parent
    plot_latency(       data, base_dir / "latency_vs_N.png")
    plot_relative_error(data, base_dir / "relative_error.png")

    print("[plot] Done.")


if __name__ == "__main__":
    main()
