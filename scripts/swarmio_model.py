#!/usr/bin/env python3
"""
scripts/swarmio_model.py — Compute analytic T_model and error columns for SwarmIO CSV

Reads a raw-measurement CSV (produced by inflash_bench, fio wrappers, or sweep scripts)
and writes an enriched CSV with T_model_ns, abs_err, rel_err columns filled in.

DEPENDENCY-FREE: uses Python 3 stdlib only (csv, math, argparse, sys).
No numpy, pandas, or matplotlib required.

Usage:
    python3 scripts/swarmio_model.py [OPTIONS] [INPUT_CSV [OUTPUT_CSV]]

    INPUT_CSV    Raw measurement CSV.  Default: stdin ("-").
    OUTPUT_CSV   Enriched output CSV.  Default: stdout ("-").

Options:
    --pipelined          Use pipelined T_model: 30000 + 8000*ceil(N/512) ns
                         (read_min_delay=30000 ns, read_sched_delay=8000 ns).
                         Default: faithful model 38000*ceil(N/512) ns.

    --sched-insts N      Number of scheduling instances (default: 512).
    --sched-delay D      Per-instance occupancy time in ns
                         (faithful default: 38000; pipelined default: 8000).
    --min-delay M        Fixed latency floor in ns
                         (faithful default: 0; pipelined default: 30000).

Model formula:
    T_model(N) = min_delay + sched_delay * ceil(N / num_sched_insts)

    Faithful  (read_sched_delay=38000, read_min_delay=0):
        T_model(N) = 38000 * ceil(N/512) ns
        T_max      = 512 / 38000 ns ≈ 13.47 MIOPS
        Single req = 38 µs  (one round, one scheduling instance)
        2 reqs same instance = 76 µs  (two rounds serialized)

    Pipelined (read_sched_delay=8000, read_min_delay=30000):
        T_model(N) = 30000 + 8000 * ceil(N/512) ns
        T_max      = 512 / 8000 ns = 64 MIOPS
        Single req = 38 µs  (30000 + 8000 * 1)
        2 reqs same instance = 46 µs  (30000 + 8000 * 2)

Expected input CSV columns (from swarmio_csv_schema.md):
    harness, num_service_units, N_or_iodepth, qdepth, threads,
    T_model_ns, measured_e2e_ns, measured_MIOPS, abs_err, rel_err

The script also accepts simpler raw CSVs with just:
    harness, num_service_units, N [or N_or_iodepth], qdepth, threads,
    measured_ns [or measured_e2e_ns or clat_ns], measured_miops [or measured_MIOPS]
"""

import sys
import csv
import math
import argparse

# ---------------------------------------------------------------------------
# Model parameters
# ---------------------------------------------------------------------------

FAITHFUL_SCHED_DELAY  = 38000   # ns  full round per scheduling instance
FAITHFUL_MIN_DELAY    = 0       # ns
PIPELINE_SCHED_DELAY  = 8000    # ns  t_cmd per instance (t_R hidden in pipeline)
PIPELINE_MIN_DELAY    = 30000   # ns  t_R as pipelined latency floor
DEFAULT_SCHED_INSTS   = 512     # planes / scheduling instances


# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

def t_model_ns(n, num_sched_insts, sched_delay, min_delay):
    """Return analytic end-to-end latency for N balanced requests [ns]."""
    if n <= 0:
        return 0
    rounds = math.ceil(n / num_sched_insts)
    return min_delay + sched_delay * rounds


def safe_int(s, default=0):
    try:
        return int(float(s)) if s not in (None, "", "0.0") else default
    except (ValueError, TypeError):
        return default


def safe_float(s, default=0.0):
    try:
        return float(s) if s not in (None, "") else default
    except (ValueError, TypeError):
        return default


def find_col(fieldnames, candidates):
    """Return first matching column name from candidates list (case-insensitive)."""
    lower = {f.lower(): f for f in fieldnames}
    for c in candidates:
        if c.lower() in lower:
            return lower[c.lower()]
    return None


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Compute T_model_ns and error columns for SwarmIO measurement CSV.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Usage:")[0].strip())
    p.add_argument("input",  nargs="?", default="-",
                   help="Input CSV file (default: stdin)")
    p.add_argument("output", nargs="?", default="-",
                   help="Output CSV file (default: stdout)")
    p.add_argument("--pipelined", action="store_true",
                   help="Use pipelined model: T=min_delay+sched_delay*ceil(N/512)")
    p.add_argument("--sched-insts", type=int, default=DEFAULT_SCHED_INSTS,
                   metavar="N",
                   help=f"Number of scheduling instances (default: {DEFAULT_SCHED_INSTS})")
    p.add_argument("--sched-delay", type=int, default=None, metavar="D",
                   help="Per-instance occupancy in ns (overrides model default)")
    p.add_argument("--min-delay",   type=int, default=None, metavar="M",
                   help="Fixed latency floor in ns (overrides model default)")
    return p.parse_args(argv)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv=None):
    args = parse_args(argv)

    # Resolve model parameters
    if args.pipelined:
        sched_delay = PIPELINE_SCHED_DELAY if args.sched_delay is None else args.sched_delay
        min_delay   = PIPELINE_MIN_DELAY   if args.min_delay   is None else args.min_delay
        model_tag   = "pipelined"
    else:
        sched_delay = FAITHFUL_SCHED_DELAY if args.sched_delay is None else args.sched_delay
        min_delay   = FAITHFUL_MIN_DELAY   if args.min_delay   is None else args.min_delay
        model_tag   = "faithful"

    num_sched_insts = args.sched_insts

    tmax_miops = (num_sched_insts / sched_delay * 1e3) if sched_delay > 0 else float("inf")

    print(f"[swarmio_model] model         : {model_tag}", file=sys.stderr)
    print(f"[swarmio_model] sched_insts   : {num_sched_insts}", file=sys.stderr)
    print(f"[swarmio_model] sched_delay   : {sched_delay} ns", file=sys.stderr)
    print(f"[swarmio_model] min_delay     : {min_delay} ns", file=sys.stderr)
    print(f"[swarmio_model] T_model(1)    : {t_model_ns(1, num_sched_insts, sched_delay, min_delay)} ns "
          f"= {t_model_ns(1, num_sched_insts, sched_delay, min_delay)/1000:.1f} µs", file=sys.stderr)
    print(f"[swarmio_model] T_model(512)  : {t_model_ns(512, num_sched_insts, sched_delay, min_delay)} ns "
          f"= {t_model_ns(512, num_sched_insts, sched_delay, min_delay)/1000:.1f} µs", file=sys.stderr)
    print(f"[swarmio_model] T_model(4096) : {t_model_ns(4096, num_sched_insts, sched_delay, min_delay)} ns "
          f"= {t_model_ns(4096, num_sched_insts, sched_delay, min_delay)/1000:.1f} µs", file=sys.stderr)
    print(f"[swarmio_model] T_max         : {tmax_miops:.2f} MIOPS", file=sys.stderr)

    # Open I/O
    in_fh  = (open(args.input,  newline="", encoding="utf-8")
              if args.input  != "-" else sys.stdin)
    out_fh = (open(args.output, "w", newline="", encoding="utf-8")
              if args.output != "-" else sys.stdout)

    try:
        reader = csv.DictReader(in_fh)
        if reader.fieldnames is None:
            print("[swarmio_model] ERROR: empty or missing CSV header", file=sys.stderr)
            sys.exit(1)

        fn = reader.fieldnames

        # Locate flexible column names in input
        col_n       = find_col(fn, ["N_or_iodepth", "N", "requests", "iodepth"])
        col_e2e     = find_col(fn, ["measured_e2e_ns", "measured_ns", "clat_ns",
                                    "t_endtoend_ns"])
        col_miops   = find_col(fn, ["measured_MIOPS", "measured_miops"])

        if col_n is None:
            print("[swarmio_model] ERROR: cannot find N column "
                  "(tried: N_or_iodepth, N, requests, iodepth)", file=sys.stderr)
            sys.exit(1)
        if col_e2e is None:
            print("[swarmio_model] WARNING: cannot find measured latency column — "
                  "abs_err/rel_err will be 0", file=sys.stderr)

        # Build output fieldnames: keep all input cols, add enrichment cols if absent
        out_fields = list(fn)
        for col in ("T_model_ns", "abs_err", "rel_err"):
            if col not in out_fields:
                out_fields.append(col)
        # Ensure measured_MIOPS is present
        if "measured_MIOPS" not in out_fields and col_miops is None:
            out_fields.append("measured_MIOPS")

        writer = csv.DictWriter(out_fh, fieldnames=out_fields,
                                extrasaction="ignore", lineterminator="\n")
        writer.writeheader()

        rows_ok = 0
        rows_skip = 0

        for row in reader:
            n = safe_int(row.get(col_n, 0))

            tm = t_model_ns(n, num_sched_insts, sched_delay, min_delay)

            measured = safe_int(row.get(col_e2e, 0)) if col_e2e else 0

            if tm > 0 and measured > 0:
                abs_err = measured - tm
                rel_err = abs_err / tm
            else:
                abs_err = 0
                rel_err = 0.0

            # Compute measured_MIOPS if missing or zero
            miops_val = safe_float(row.get(col_miops, 0.0)) if col_miops else 0.0
            if miops_val == 0.0 and n > 0 and measured > 0:
                # MIOPS = n / (measured_ns / 1e9) / 1e6 = n * 1e3 / measured_ns
                miops_val = n * 1e3 / measured

            row["T_model_ns"]     = str(tm)
            row["abs_err"]        = str(abs_err)
            row["rel_err"]        = f"{rel_err:.6f}"
            row["measured_MIOPS"] = f"{miops_val:.4f}"

            writer.writerow(row)
            if n > 0:
                rows_ok += 1
            else:
                rows_skip += 1

        print(f"[swarmio_model] rows enriched : {rows_ok}", file=sys.stderr)
        if rows_skip:
            print(f"[swarmio_model] rows skipped  : {rows_skip} (N=0 or missing)", file=sys.stderr)

    finally:
        if args.input  != "-":
            in_fh.close()
        if args.output != "-":
            out_fh.close()


if __name__ == "__main__":
    main()
