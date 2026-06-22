#!/bin/bash
# SwarmIO/scripts/unload_inflash.sh — Unload the swarmio module
#
# Usage:
#   [RUN=1] bash unload_inflash.sh
#
# Environment:
#   RUN=1  — actually execute (guards sudo modprobe -r behind this flag)

set -e

SCRIPT_DIR=$(dirname "$(realpath "$0")")

echo "===== SwarmIO unload_inflash.sh ====="
echo ""
echo "[pre-flight] Current module state:"
lsmod | grep -E 'nvmev|swarmio' || echo "  (neither nvmev nor swarmio is loaded)"
echo ""

UNLOAD_CMD="${SCRIPT_DIR}/load.sh --unload"

echo "[unload] Command that will be executed:"
echo "  ${UNLOAD_CMD}"
echo ""

if [[ "${RUN:-0}" == "1" ]]; then
    echo "[unload] RUN=1 — executing..."
    eval "${UNLOAD_CMD}"
    echo ""
    echo "[post-unload] Module state:"
    lsmod | grep -E 'nvmev|swarmio' || echo "  (swarmio unloaded successfully)"
else
    echo "[dry-run] Set RUN=1 to actually unload the module, e.g.:"
    echo "  RUN=1 bash $0"
fi
