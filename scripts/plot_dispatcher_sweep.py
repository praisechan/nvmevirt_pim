#!/usr/bin/env python3
"""Plot single-plane amortized us/512-set vs nr_dispatchers from the
dispatcher-sweep summary CSV (semicolon-separated cpus). Annotates the
all-plane 34.8 us line (1 cmd / 1 core / 1 queue) and the ~30 us flash-media
floor. The headline finding: scaling controller cores does NOT bring
single-plane toward the floor — it rises, because the flash floor is fixed and
the added dispatchers contend (shared doorbell + faithful per-channel media lock)
faster than they parallelize command intake.

Usage: python3 scripts/plot_dispatcher_sweep.py [summary_csv] [out_png]
"""
import csv, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SUMMARY = sys.argv[1] if len(sys.argv) > 1 else "results_nvmevirt_spdk_dispatcher_sweep.csv"
OUT     = sys.argv[2] if len(sys.argv) > 2 else "fig_nvmevirt_dispatcher_sweep.png"

rows = list(csv.DictReader(open(SUMMARY)))

def f(x):
    try: return float(x)
    except (TypeError, ValueError): return None

sp = [r for r in rows if r["mode"] == "single-plane" and r["requests"] == "4096"
      and f(r["amort_us_per_512set"]) is not None]

t1     = sorted([r for r in sp if r["phase"] in ("D1","D2") and r["host_threads"] == "1"],
                key=lambda r: int(r["nr_dispatchers"]))
tmatch = sorted([r for r in sp if r["phase"] in ("D1","D2") and r["host_threads"] == r["nr_dispatchers"]],
                key=lambda r: int(r["nr_dispatchers"]))

ap = [r for r in rows if r["mode"] == "all-plane"]
ap_e2e = f(ap[0]["e2e_med_us"]) if ap else 34.8
ctl = [r for r in rows if r["phase"] == "CTL"]

fig, ax = plt.subplots(figsize=(9, 5.6))

xs = [int(r["nr_dispatchers"]) for r in t1]
ys = [f(r["amort_us_per_512set"]) for r in t1]
ax.plot(xs, ys, "o-", color="#888", lw=2,
        label="single host queue (T=1): only dispatcher 0 works; N-1 idle dispatchers")
for r, x, y in zip(t1, xs, ys):
    ax.annotate(f"{y:.0f}", (x, y), textcoords="offset points", xytext=(6, -12), fontsize=8, color="#555")

xs2 = [int(r["nr_dispatchers"]) for r in tmatch]
ys2 = [f(r["amort_us_per_512set"]) for r in tmatch]
ax.plot(xs2, ys2, "s-", color="#1f77b4", lw=2,
        label="host queues matched (T=N): all N dispatchers active")
for r, x, y in zip(tmatch, xs2, ys2):
    ax.annotate(f"{y:.0f} µs\n{x}c+{x}q,{r['io_workers']}iow",
                (x, y), textcoords="offset points", xytext=(6, 8), fontsize=8, color="#1f77b4")

# control: N=1 with N=8's working cores (disp cpu1 + iow cpu9) — isolates idle-dispatcher cost
for r in ctl:
    if "cpu9" in r["dev_lat"]:
        y = f(r["amort_us_per_512set"])
        ax.scatter([8], [y], marker="*", s=180, color="#9467bd", zorder=5,
                   label=f"control: N=1 on N=8's working cores = {y:.0f} µs\n(idle dispatchers alone add 152→259 µs)")
        ax.annotate("", xy=(8, 259.16), xytext=(8, y),
                    arrowprops=dict(arrowstyle="<->", color="#9467bd", ls=":"))

ax.axhline(ap_e2e, color="#2ca02c", ls="-.", lw=1.6,
           label=f"all-plane: 1 cmd / 1 core / 1 queue = {ap_e2e:.1f} µs (independent of N)")
ax.axhline(30.0, color="#d62728", ls=":", lw=1.6, label="flash-media floor ≈ 30 µs (tR)")

ax.set_xscale("log", base=2)
ax.set_xticks([1, 2, 4, 8]); ax.set_xticklabels(["1", "2", "4", "8"])
ax.set_xlabel("nr_dispatchers (controller cores)")
ax.set_ylabel("single-plane amortized latency (µs per 512-plane set)")
ax.set_title("Scaling controller cores does NOT rescue single-plane 512-plane activation\n"
             "(fixed flash array; all-plane reaches the floor with one command)")
ax.grid(True, which="both", ls=":", alpha=0.4)
ax.legend(fontsize=8, loc="center left", framealpha=0.95)
ax.set_ylim(0, max(330, (max(ys2) if ys2 else 330) * 1.12))

fig.tight_layout()
fig.savefig(OUT, dpi=130)
print(f"wrote {OUT}")
