#!/usr/bin/env python3
"""Experiment B (report §16): one plane per dispatcher.

Left panel (B1/B2):  e2e to activate P=N planes vs N, parallel (1 cmd/dispatcher,
                     channel-affine) vs serial (N cmds on 1 dispatcher/1 queue),
                     against the ~30 us flash floor and 34.8 us all-plane line.
                     Flat parallel curve => NVMeVirt parallelizes faithfully when
                     balanced 1 cmd : 1 dispatcher; the serial curve shows the
                     per-dispatcher serial-intake penalty.

Right panel (B3):    fixed N=8 channel-affine, e2e vs per-dispatcher batch depth
                     P/N in {1,4,16,64} (P in {8,32,128,512}). The slope is the
                     per-command serial-intake cost; the P=512 point should match
                     Experiment A's N=8 affine value. Optional spread overlay shows
                     contention adding on top of the serial-intake climb.

Usage: python3 scripts/plot_planes_eq_disp.py [planes_csv] [batch_csv] [out_png]
"""
import csv, sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

PLANES = sys.argv[1] if len(sys.argv) > 1 else "results_nvmevirt_spdk_planes_eq_disp.csv"
BATCH  = sys.argv[2] if len(sys.argv) > 2 else "results_nvmevirt_spdk_batchdepth_N8.csv"
OUT    = sys.argv[3] if len(sys.argv) > 3 else "fig_nvmevirt_planes_eq_disp.png"
CA_SUM = "results_nvmevirt_spdk_chanaffine_sweep.csv"

def f(x):
    try: return float(x)
    except (TypeError, ValueError): return None

rows = list(csv.DictReader(open(PLANES)))
par = sorted([r for r in rows if r["phase"] == "B1"], key=lambda r: int(r["planes"]))
ser = sorted([r for r in rows if r["phase"] == "B2"], key=lambda r: int(r["planes"]))

fig, (axL, axR) = plt.subplots(1, 2, figsize=(13.5, 5.6))

xp = [int(r["planes"]) for r in par]; yp = [f(r["e2e_med_us"]) for r in par]
xs = [int(r["planes"]) for r in ser]; ys = [f(r["e2e_med_us"]) for r in ser]
axL.plot(xp, yp, "o-", color="#1f77b4", lw=2, label="parallel: N queues, 1 cmd/dispatcher (channel-affine)")
axL.plot(xs, ys, "s-", color="#d62728", lw=2, label="serial: 1 queue / 1 dispatcher, N cmds")
for x, y in zip(xp, yp):
    axL.annotate(f"{y:.0f}", (x, y), textcoords="offset points", xytext=(5, -13), fontsize=8, color="#1f77b4")
for x, y in zip(xs, ys):
    axL.annotate(f"{y:.0f}", (x, y), textcoords="offset points", xytext=(5, 6), fontsize=8, color="#d62728")
axL.axhline(34.8, color="#2ca02c", ls="-.", lw=1.5, label="all-plane primitive = 34.8 µs")
axL.axhline(30.0, color="#888", ls=":", lw=1.5, label="flash-media floor ≈ 30 µs (tR)")
axL.set_xscale("log", base=2)
axL.set_yscale("log")
axL.set_xticks(xp); axL.set_xticklabels([str(x) for x in xp])
axL.set_xlabel("N = planes = dispatchers = host queues")
axL.set_ylabel("e2e to activate N planes (µs, log)")
axL.set_title("Planes = dispatchers: serial 1-queue beats parallel N-queue\n(1 dispatcher / N cmds stays at the floor)")
axL.grid(True, which="both", ls=":", alpha=0.4)
axL.legend(fontsize=8, loc="upper left", framealpha=0.95)
if len(xp) >= 5:
    axL.annotate("N=16 parallel: oversubscription\nconfound (§3.4)",
                 (xp[-1], yp[-1]), textcoords="offset points", xytext=(-12, -38),
                 fontsize=7.5, color="#555", ha="center")

# right: batch depth — per-plane ns (monotonic amortization). e2e itself is
# non-monotonic at small P (host fan-out skew dominates), so we show the clean
# per-plane amortization and overlay the tiny serial-intake t_cmd from B2.
brows = list(csv.DictReader(open(BATCH)))
baff = sorted([r for r in brows if r["phase"] == "B3" and r["routing"] == "affine"],
              key=lambda r: int(r["batch_depth"]))
bspr = [r for r in brows if r["phase"] == "B3" and r["routing"] == "spread"]
xb = [int(r["batch_depth"]) for r in baff]
ypp = [f(r["per_plane_ns"]) for r in baff]
ye2e = [f(r["e2e_med_us"]) for r in baff]
axR.plot(xb, ypp, "o-", color="#1f77b4", lw=2, label="per-plane ns (N=8 channel-affine)")
for x, y, e in zip(xb, ypp, ye2e):
    axR.annotate(f"{y:.0f} ns/plane\n(P={x*8}, e2e {e:.0f}µs)", (x, y),
                 textcoords="offset points", xytext=(6, 8), fontsize=7.5, color="#1f77b4")
# serial per-command intake cost from B2: t_cmd = (e2e(16)-e2e(1))/15
try:
    prows = list(csv.DictReader(open(PLANES)))
    s1 = next(r for r in prows if r["phase"]=="B2" and r["planes"]=="1")
    s16 = next(r for r in prows if r["phase"]=="B2" and r["planes"]=="16")
    tcmd = (f(s16["e2e_med_us"]) - f(s1["e2e_med_us"]))/15.0
    axR.annotate(f"serial intake t_cmd ≈ {tcmd*1000:.0f} ns/cmd (B2)\n"
                 f"=> negligible below ~100 cmds:\ne2e is host-throughput-bound, not intake-bound",
                 (xb[1], ypp[1]), textcoords="offset points", xytext=(20, 40),
                 fontsize=8, color="#555",
                 arrowprops=dict(arrowstyle="->", color="#999"))
except (StopIteration, FileNotFoundError):
    pass
if bspr:
    sp = f(bspr[0]["per_plane_ns"])
    axR.scatter([64], [sp], marker="*", s=200, color="#d62728", zorder=5,
                label=f"P=512 spread = {sp:.0f} ns/plane (affine {ypp[-1]:.0f}: contention adds ~2%)")
axR.set_xscale("log", base=2); axR.set_yscale("log")
axR.set_xticks(xb); axR.set_xticklabels([str(x) for x in xb])
axR.set_xlabel("per-dispatcher batch depth  P/N  (N=8)")
axR.set_ylabel("per-plane latency (ns/plane, log)")
axR.set_title("More planes amortize fixed cost; affine≈spread\n(per-channel lock is not the cost)")
axR.grid(True, which="both", ls=":", alpha=0.4)
axR.legend(fontsize=8, loc="upper right", framealpha=0.95)

fig.suptitle("Experiment B — one plane per dispatcher removes the per-dispatcher serial command intake", fontsize=12)
fig.tight_layout(rect=[0, 0, 1, 0.96])
fig.savefig(OUT, dpi=130)
print(f"wrote {OUT}")
