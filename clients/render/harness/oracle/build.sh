#!/bin/sh
# Builds txp-oracle: TeXpresso's MuPDF render, frozen for the fidelity harness. txp-render no longer links MuPDF
# (nomupdf, 2026-11-06), so the oracle is txp-render as it was at ORACLE_REV, the last clients/render that drew with
# MuPDF: the same driver (typesetting, font stand-ins) as today's, only the drawing differs. It is built from that
# revision's tree (git archive) against TEXPRESSO_DIR and MuPDF. Taudot's own code; nothing of MuPDF's is copied.
# (Until 2026-11-06 the oracle was a pinned txp-headless.c at c58b62f, whose typesetting fell behind the driver's.)
#   TEXPRESSO_DIR=... sh build.sh OUT
set -e
cd "$(dirname "$0")"
ORACLE_REV=a4198f3
OUT="$1"
: "${TEXPRESSO_DIR:?TEXPRESSO_DIR}"
TMP="$(mktemp -d)"
git -C "$(git rev-parse --show-toplevel)" archive "$ORACLE_REV" clients/render | tar -x -C "$TMP"
sh "$TMP/clients/render/build.sh" >/dev/null
cp "$TMP/clients/render/txp-render" "$OUT"
rm -rf "$TMP"
