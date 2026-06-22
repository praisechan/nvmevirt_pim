#!/usr/bin/env bash
# scripts/nvmevirt_microtest.sh — Exp 4.A.4 multi-page microtests for NVMeVirt
#
# Three microtests for the 256 KB (K=64 pages) request size:
#   (i)   One 256KB request → 64 LUNs active (partial round, 4 LUNs/channel).
#         Expected: tR + (4 LUNs/ch × per-LUN-cmd) — BELOW saturated-round value.
#         Report against the partial-round emergent value, not a flat 38µs.
#
#   (ii)  8 × 256KB covering all 512 LUNs → saturated round with only 8 commands.
#         Expected: tR + emergent t_cmd ≈ 32.6µs at default knobs
#         (COMPUTE_RESULT_SIZE=64B, NAND_CHANNEL_BANDWIDTH=800MB/s →
#          t_cmd = 32 LUNs/ch × 64B/800MB/s ≈ 2.6µs; saturated ≈ 32.6µs).
#
#   (iii) Two 256KB requests to the SAME 64-LUN range → same-LUN serialization.
#         Uses --samelun: LPN 0 (LUNs 0-63) and LPN 512 (LUNs 0-63 again under
#         round-robin: 512 mod 512 = 0). Both requests are 256KB = 64 pages.
#         Expected: ≈ 2 × tR ≈ 60-67µs (same-LUN serialization via multi-page path).
#
# Bench output format (host/inflash_bench.c):
#   CSV to stdout: requests,qdepth,trial,t_endtoend_ns,t_p50_ns,t_p99_ns
#   Stderr lines:  trial   0:  e2e=   32 us   p50=...   p99=...
#
# USAGE:
#   Dry run (no device):   bash scripts/nvmevirt_microtest.sh
#   Live run:              RUN=1 DEV=/dev/nvme1n1 bash scripts/nvmevirt_microtest.sh
#
# Environment:
#   RUN     — set to 1 to execute (default: dry-run)
#   DEV     — NVMeVirt block device [default: /dev/nvme1n1]
#   BENCH   — path to inflash_bench binary [default: ./host/inflash_bench]
#   TRIALS  — measurement trials per test  [default: 5]
#
# Requires: host/inflash_bench built, sudo, NVMeVirt loaded. Run from repo root.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="${BENCH:-${REPO_DIR}/host/inflash_bench}"
TRIALS="${TRIALS:-5}"
REQSIZE_256K=262144   # 64 pages × 4096 bytes = 256 KB

# ===========================================================================
# Dry-run: print planned microtests and exit (default — RUN unset)
# ===========================================================================
if [[ -z "${RUN:-}" ]]; then
  echo "[dry-run] nvmevirt_microtest.sh — Exp 4.A.4 planned microtests" >&2
  echo "" >&2
  echo "  reqsize = 262144 bytes (K=64 pages per request = 64 LUNs per command)" >&2
  echo "  NVMeVirt geometry: 512 LUNs (16ch × 32lun/ch), MDTS=6 (max 64 pages/req)" >&2
  echo "" >&2
  echo "  (i)   1 × 256KB request    --reqsize 262144 --requests 1 --qdepth 1" >&2
  echo "        64 of 512 LUNs active; 4 LUNs in each of 16 channels." >&2
  echo "        Expected: tR + (4 × per_LUN_cmd) — partial-round value BELOW saturated." >&2
  echo "        At default knobs: 30µs + 4×80ns ≈ 30.3µs (NOT a flat 38µs)." >&2
  echo "" >&2
  echo "  (ii)  8 × 256KB requests   --reqsize 262144 --requests 8 --qdepth 8" >&2
  echo "        8 × 64 = 512 LUNs covered. Saturated round via only 8 commands." >&2
  echo "        Expected: tR + emergent t_cmd ≈ 32.6µs (32 LUNs/ch saturated)." >&2
  echo "        Compare to 512×4KB baseline ≈ 557µs (512 commands, single-dispatcher)." >&2
  echo "" >&2
  echo "  (iii) 2 × 256KB same LUN   --reqsize 262144 --samelun" >&2
  echo "        LPN 0 → LUNs 0-63; LPN 512 → LUNs 0-63 (512 mod 512 = 0)." >&2
  echo "        Same-LUN serialization preserved through the multi-page path." >&2
  echo "        Expected: ≈ 2 × tR ≈ 60-67µs." >&2
  echo "" >&2
  echo "  TRIALS  : $TRIALS" >&2
  echo "  BENCH   : $BENCH" >&2
  echo "  DEV     : ${DEV:-/dev/nvme1n1} (override with DEV=...)" >&2
  echo "" >&2
  echo "[dry-run] Set RUN=1 (and optionally DEV=/dev/nvme1n1) to execute." >&2
  exit 0
fi

# ===========================================================================
# Live run
# ===========================================================================
DEV="${DEV:-/dev/nvme1n1}"

# Safety: reject boot disk
if [[ "$DEV" == /dev/nvme0* ]]; then
  echo "[microtest] ERROR: refusing to use $DEV — that is the boot disk (nvme0*)." >&2
  exit 1
fi

if [[ ! -b "${DEV}" ]]; then
  echo "[microtest] ERROR: ${DEV} is not a block device." >&2
  echo "            Load NVMeVirt first: bash scripts/load.sh" >&2
  echo "            Then check: lsblk | grep nvme" >&2
  exit 1
fi

if [[ ! -x "${BENCH}" ]]; then
  echo "[microtest] ERROR: benchmark not found / not executable: ${BENCH}" >&2
  echo "            Build with: make -C ${REPO_DIR}/host" >&2
  exit 1
fi

echo "============================================================"
echo " NVMeVirt Exp 4.A.4 — Multi-page Microtests (256KB / K=64)"
echo " Device  : ${DEV}"
echo " Bench   : ${BENCH}"
echo " Trials  : ${TRIALS}"
echo " reqsize : ${REQSIZE_256K} bytes (64 pages, 64 LUNs per request)"
echo "============================================================"
echo ""

# ---- Prepopulate maptbl (REQUIRED on NVMeVirt) ----
# conv_read (conv_ftl.c:889) skips unmapped LPNs, charging ZERO latency. Reads must
# hit written (mapped, valid) pages to incur tR. Test (iii) touches up to LPN ~575
# (LPN 512 + 64 pages); 1024 covers all three tests.
PREPOP_PAGES="${PREPOP_PAGES:-1024}"
echo "[microtest] Prepopulating $PREPOP_PAGES pages so reads charge tR (conv_read skips unmapped LPNs)..."
sudo taskset -c 16-31 "${BENCH}" --dev "${DEV}" --requests 1 --trials 0 \
     --prepopulate --maxpages "$PREPOP_PAGES" 2>&1 | grep -E '^\[prepopulate\]|ERROR' || true
echo ""

# ---------- Test (i): one 256KB request — partial round (64 of 512 LUNs) ----------
echo "--- Test (i): 1 × 256KB request, qdepth=1 ---"
echo "    Partial round: 64 of 512 LUNs active (4 LUNs in each of 16 channels)"
echo "    Expected: tR + 4×per_LUN_cmd ≈ 30.3µs at default knobs"
echo "    (below saturated-round value; NOT flat 38µs)"
echo ""
sudo taskset -c 16-31 "${BENCH}" \
     --dev     "${DEV}" \
     --reqsize "${REQSIZE_256K}" \
     --requests 1 \
     --qdepth   1 \
     --trials  "${TRIALS}"
echo ""

# ---------- Test (ii): 8×256KB — saturated round, all 512 LUNs, 8 commands ----------
echo "--- Test (ii): 8 × 256KB requests (all 512 LUNs), qdepth=8 ---"
echo "    Saturated round: 8×64 = 512 LUNs; only 8 dispatcher fetches."
echo "    Expected: tR + emergent t_cmd ≈ 32.6µs (at default knobs:"
echo "      COMPUTE_RESULT_SIZE=64B, NAND_CHANNEL_BANDWIDTH=800MB/s,"
echo "      32 LUNs/ch saturated → t_cmd ≈ 32×80ns ≈ 2.6µs)"
echo "    Compare to 512×4KB baseline ≈ 557µs (512 commands, ~1µs/dispatch)"
echo ""
sudo taskset -c 16-31 "${BENCH}" \
     --dev     "${DEV}" \
     --reqsize "${REQSIZE_256K}" \
     --requests 8 \
     --qdepth   8 \
     --trials  "${TRIALS}"
echo ""

# ---------- Test (iii): two 256KB to same 64-LUN range (--samelun) ----------
echo "--- Test (iii): 2 × 256KB to SAME 64-LUN range (--samelun), qdepth=2 ---"
echo "    --samelun sets: LPN 0 (LUNs 0-63) and LPN 512 (LUNs 0-63 again;"
echo "    round-robin: LPN 512 mod 512 = LUN 0, spans LUNs 0-63 with K=64)."
echo "    Same-LUN serialization preserved through multi-page path."
echo "    Expected: ≈ 2 × tR ≈ 60-67µs"
echo ""
sudo taskset -c 16-31 "${BENCH}" \
     --dev     "${DEV}" \
     --reqsize "${REQSIZE_256K}" \
     --samelun \
     --trials  "${TRIALS}"
echo ""

echo "============================================================"
echo " Exp 4.A.4 summary:"
echo "   (i)  1×256KB partial round  → expect < saturated-round e2e"
echo "                                  (emergent partial t_cmd, ~30.3µs)"
echo "   (ii) 8×256KB saturated      → tR + emergent t_cmd (~32.6µs default)"
echo "                                  vs. 512×4KB baseline ~557µs"
echo "  (iii) 2×256KB same-LUN       → ~2×tR ~60-67µs"
echo "============================================================"
