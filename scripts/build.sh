#!/usr/bin/env bash
# scripts/build.sh — Build nvmev.ko with the INFLASH_PIM profile
#
# Idempotent: safe to re-run. Selects BASE_SSD=INFLASH_PIM in Kbuild
# and invokes the repo Makefile against the running kernel headers.
#
# Usage:
#   bash scripts/build.sh            # build from repo root
#   bash scripts/build.sh clean      # clean first, then build

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KVER="${KVER:-$(uname -r)}"
KDIR="/lib/modules/${KVER}/build"

echo "[build] Repo : ${REPO_DIR}"
echo "[build] Kernel: ${KVER}"
echo "[build] Kdir  : ${KDIR}"

if [[ ! -d "${KDIR}" ]]; then
    echo "[build] ERROR: kernel headers not found at ${KDIR}"
    echo "        Install with: sudo apt install linux-headers-${KVER}"
    exit 1
fi

cd "${REPO_DIR}"

if [[ "${1:-}" == "clean" ]]; then
    echo "[build] Cleaning..."
    make -C "${KDIR}" M="${REPO_DIR}" clean
fi

echo "[build] Building with BASE_SSD=INFLASH_PIM ..."
# The INFLASH_PIM Kbuild target passes -DBASE_SSD=INFLASH_PIM.
# Mirrors the CONFIG_NVMEVIRT_SSD pattern; see Kbuild for the target name.
make -C "${KDIR}" M="${REPO_DIR}" CONFIG_NVMEVIRT_INFLASH_PIM=y

echo "[build] Done. Module: ${REPO_DIR}/nvmev.ko"
ls -lh "${REPO_DIR}/nvmev.ko"
