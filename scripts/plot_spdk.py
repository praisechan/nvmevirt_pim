#!/usr/bin/env python3
"""
plot_spdk.py — Experiment S (SPDK host path) figures.

Produces two figures for report §12:
  1. fig_nvmevirt_spdk_e2e.png      — host e2e for the 1-page --compute command,
                                       io_uring vs SPDK, over the flat 34 us device floor;
                                       annotates the removed O(1) host residual.
  2. fig_nvmevirt_spdk_variance.png — jitter: io_uring (cold 46->200 us spread) vs
                                       SPDK (tight ~1 us band) for S1a.

SPDK numbers are read from results_nvmevirt_spdk_raw.csv (S1a rows: requests==1,qdepth==1).
io_uring numbers are the measured values from report §11 / results_nvmevirt_compute_raw.csv.
Device floor = 34,152 ns (modeled, identical across host stacks; dmesg-verified).
"""
import csv, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPDK_CSV = os.path.join(REPO, "results_nvmevirt_spdk_raw.csv")

DEVICE_FLOOR_NS = 34152.0

# --- io_uring measured values (report §11, 1-page --compute command) ---
IOURING_E2E_US   = 48.0           # E2 median host e2e
IOURING_MIN_US   = 46.0           # warm
IOURING_MED_US   = 48.0
IOURING_MAX_US   = 200.0          # cold outlier (report §0/§11: swung 46->82->200)

def load_spdk_s1a():
    e2e = []
    with open(SPDK_CSV) as f:
        for row in csv.DictReader(f):
            if int(row["requests"]) == 1 and int(row["qdepth"]) == 1:
                e2e.append(float(row["t_endtoend_ns"]))
    return sorted(e2e)

def pct(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    idx = int(p / 100.0 * (len(sorted_vals) - 1) + 0.5)
    return sorted_vals[max(0, min(idx, len(sorted_vals) - 1))]

def main():
    s1a = load_spdk_s1a()
    spdk_med_us = pct(s1a, 50) / 1000.0
    spdk_min_us = s1a[0] / 1000.0
    spdk_max_us = s1a[-1] / 1000.0
    spdk_p99_us = pct(s1a, 99) / 1000.0
    floor_us = DEVICE_FLOOR_NS / 1000.0

    # ---------- Figure 1: e2e comparison over device floor ----------
    fig, ax = plt.subplots(figsize=(7.2, 5.0))
    stacks = ["io_uring\n(O_DIRECT)", "SPDK\n(uio, polled)"]
    e2es   = [IOURING_E2E_US, spdk_med_us]
    colors = ["#b0b0b0", "#2a7de1"]
    bars = ax.bar(stacks, e2es, color=colors, width=0.55, zorder=3, edgecolor="black", linewidth=0.6)

    # device floor line
    ax.axhline(floor_us, color="#d62728", ls="--", lw=1.6, zorder=4,
               label=f"device floor (modeled): {floor_us:.1f} µs\n= tR 30 µs + emergent t_cmd ~4 µs")

    # annotate residuals (host overhead = e2e - device floor)
    for b, e2e in zip(bars, e2es):
        resid = e2e - floor_us
        ax.text(b.get_x() + b.get_width()/2, e2e + 1.2, f"{e2e:.1f} µs",
                ha="center", va="bottom", fontweight="bold", fontsize=11)
        # residual bracket
        ax.annotate("", xy=(b.get_x()+b.get_width()/2+0.32, e2e),
                    xytext=(b.get_x()+b.get_width()/2+0.32, floor_us),
                    arrowprops=dict(arrowstyle="<->", color="#444", lw=1.2))
        ax.text(b.get_x()+b.get_width()/2+0.37, (e2e+floor_us)/2,
                f"host residual\n{resid:.1f} µs", va="center", ha="left",
                fontsize=9, color="#444")

    ax.set_ylabel("host end-to-end latency (µs)")
    ax.set_title("1-page in-flash-compute command: host stack vs device floor\n"
                 "(device senses all 512 planes in both — dmesg-verified)", fontsize=11)
    ax.set_ylim(0, max(e2es) * 1.25)
    ax.legend(loc="upper right", fontsize=8.5, framealpha=0.95)
    ax.grid(axis="y", alpha=0.3, zorder=0)
    fig.tight_layout()
    out1 = os.path.join(REPO, "fig_nvmevirt_spdk_e2e.png")
    fig.savefig(out1, dpi=140); print("wrote", out1)

    # ---------- Figure 2: variance / jitter collapse ----------
    fig2, ax2 = plt.subplots(figsize=(7.2, 5.0))
    labels = ["io_uring (O_DIRECT)", "SPDK (uio, polled)"]
    meds   = [IOURING_MED_US, spdk_med_us]
    lowers = [IOURING_MED_US - IOURING_MIN_US, spdk_med_us - spdk_min_us]
    uppers = [IOURING_MAX_US - IOURING_MED_US, spdk_max_us - spdk_med_us]
    xs = [0, 1]
    ax2.errorbar(xs, meds, yerr=[lowers, uppers], fmt="o", ms=10,
                 capsize=10, capthick=2, lw=2,
                 color=["#777"][0], ecolor="#555", zorder=3)
    # color points distinctly
    ax2.plot(0, IOURING_MED_US, "o", ms=11, color="#b0b0b0", zorder=4)
    ax2.plot(1, spdk_med_us, "o", ms=11, color="#2a7de1", zorder=4)
    ax2.axhline(floor_us, color="#d62728", ls="--", lw=1.4,
                label=f"device floor {floor_us:.1f} µs")

    ax2.text(0, IOURING_MAX_US + 6, f"min {IOURING_MIN_US:.0f} / med {IOURING_MED_US:.0f} / max {IOURING_MAX_US:.0f} µs",
             ha="center", fontsize=9, color="#444")
    ax2.text(1, spdk_max_us + 6, f"min {spdk_min_us:.1f} / med {spdk_med_us:.1f} / max {spdk_max_us:.1f} µs",
             ha="center", fontsize=9, color="#2a7de1")

    ax2.set_xticks(xs); ax2.set_xticklabels(labels)
    ax2.set_xlim(-0.5, 1.5)
    ax2.set_ylim(0, IOURING_MAX_US * 1.18)
    ax2.set_ylabel("host end-to-end latency (µs)")
    ax2.set_title("Jitter of the 1-page compute command (S1a, 15 trials)\n"
                  "SPDK polling collapses the io_uring cold-start spread", fontsize=11)
    ax2.legend(loc="center right", fontsize=9)
    ax2.grid(axis="y", alpha=0.3)
    fig2.tight_layout()
    out2 = os.path.join(REPO, "fig_nvmevirt_spdk_variance.png")
    fig2.savefig(out2, dpi=140); print("wrote", out2)

    # print a small summary for the report
    print(f"\nSPDK S1a: median={spdk_med_us:.2f}us min={spdk_min_us:.2f} max={spdk_max_us:.2f} "
          f"p99={spdk_p99_us:.2f} residual={spdk_med_us-floor_us:.2f}us (n={len(s1a)})")

if __name__ == "__main__":
    main()
