#!/usr/bin/env python3
"""Experiment A (report §15): channel-affine vs spread routing.

Left panel:  single-plane amortized us/512-set vs N, channel-affine vs spread,
             against the all-plane 34.8 us primitive and the ~30 us flash floor.
Right panel: direct per-channel-lock contention (chstat trylock-fail count) —
             spread > 0 and grows; channel-affine ~ 0. This is the airtight
             evidence (latency deltas alone are turbo/LLC-noisy).

Conclusion the figure supports: channel affinity removes ALL cross-dispatcher
lock contention (right panel -> 0) yet barely moves the amortized latency (left
panel), so the per-channel media lock was NOT the single-plane bottleneck —
hardening §14's turbo/LLC/io_worker-funnel attribution.

Usage: python3 scripts/plot_chanaffine_sweep.py [summary_csv] [out_png]
"""
import csv, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SUMMARY = sys.argv[1] if len(sys.argv) > 1 else "results_nvmevirt_spdk_chanaffine_sweep.csv"
OUT     = sys.argv[2] if len(sys.argv) > 2 else "fig_nvmevirt_chanaffine.png"

rows = list(csv.DictReader(open(SUMMARY)))
def f(x):
    try: return float(x)
    except (TypeError, ValueError): return None

ca2 = [r for r in rows if r["phase"] == "CA2"]
spread = sorted([r for r in ca2 if r["routing"] == "spread"], key=lambda r: int(r["nr_dispatchers"]))
affine = sorted([r for r in ca2 if r["routing"] == "affine"], key=lambda r: int(r["nr_dispatchers"]))
ap = [r for r in rows if r["phase"] == "CA4"]
ap_e2e = f(ap[0]["e2e_med_us"]) if ap else 34.8

fig, (axL, axR) = plt.subplots(1, 2, figsize=(13.5, 5.6))

xs  = [int(r["nr_dispatchers"]) for r in spread]
ysS = [f(r["amort_us_per_512set"]) for r in spread]
xa  = [int(r["nr_dispatchers"]) for r in affine]
ysA = [f(r["amort_us_per_512set"]) for r in affine]

axL.plot(xs, ysS, "s-", color="#d62728", lw=2, label="spread (§14: all N dispatchers contend every channel)")
axL.plot(xa, ysA, "o-", color="#1f77b4", lw=2, label="channel-affine (each ch->lock single-owner)")
for x, y in zip(xs, ysS):
    axL.annotate(f"{y:.0f}", (x, y), textcoords="offset points", xytext=(6, 8), fontsize=8, color="#d62728")
for x, y in zip(xa, ysA):
    axL.annotate(f"{y:.0f}", (x, y), textcoords="offset points", xytext=(6, -14), fontsize=8, color="#1f77b4")
axL.axhline(ap_e2e, color="#2ca02c", ls="-.", lw=1.6,
            label=f"all-plane: 1 cmd / 1 core / 1 queue = {ap_e2e:.1f} µs")
axL.axhline(30.0, color="#888", ls=":", lw=1.6, label="flash-media floor ≈ 30 µs (tR)")
axL.set_xscale("log", base=2)
axL.set_yscale("log")
axL.set_xticks(xs); axL.set_xticklabels([str(x) for x in xs])
axL.set_xlabel("nr_dispatchers = host queues (T=N)")
axL.set_ylabel("single-plane amortized latency (µs / 512-plane set, log)")
axL.set_title("Removing cross-dispatcher lock contention\nbarely moves single-plane latency (affine≈spread)")
axL.grid(True, which="both", ls=":", alpha=0.4)
axL.legend(fontsize=8, loc="upper left", framealpha=0.95)
# N=16 is the oversubscription-confounded 'limiting illustration' (§3.4); note it
if len(xs) >= 3:
    axL.annotate("N=16: io_worker\noversubscription\nconfound (§3.4)",
                 (xs[-1], ysS[-1]), textcoords="offset points", xytext=(-30, -42),
                 fontsize=7.5, color="#555", ha="center")

# right: contention bars
import numpy as np
bx = np.arange(len(xs)); w = 0.38
conS = [f(r["contended"]) or 0 for r in spread]
conA = [f(r["contended"]) or 0 for r in affine]
axR.bar(bx - w/2, conS, w, color="#d62728", label="spread")
axR.bar(bx + w/2, conA, w, color="#1f77b4", label="channel-affine (= 0)")
for i, v in enumerate(conS):
    axR.annotate(f"{int(v)}", (bx[i]-w/2, v), textcoords="offset points", xytext=(0,3), ha="center", fontsize=8)
for i, v in enumerate(conA):
    axR.annotate(f"{int(v)}", (bx[i]+w/2, v), textcoords="offset points", xytext=(0,3), ha="center", fontsize=8)
axR.set_xticks(bx); axR.set_xticklabels([f"N={x}" for x in xs])
axR.set_xlabel("nr_dispatchers")
axR.set_ylabel("contended ch->lock acquisitions (trylock-fail, 40960 acq/run)")
axR.set_title("Direct contention (Task CB): affine eliminates it entirely")
axR.grid(True, axis="y", ls=":", alpha=0.4)
axR.legend(fontsize=9)

fig.suptitle("Experiment A — channel-affine dispatchers isolate per-channel media-lock contention", fontsize=12)
fig.tight_layout(rect=[0, 0, 1, 0.96])
fig.savefig(OUT, dpi=130)
print(f"wrote {OUT}")
