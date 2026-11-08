#!/bin/sh
# Margin vs. editor while scrolling, in the real app: taudot-app (debug) on a COPY of a .tex file with the mock
# engine, comments every ~60 lines, the shell's TAUDOT_SCROLLTRACE flicks, and TAUDOT_MARGIN_TRACE per frame.
#   swift build [-c release] --product taudot-app && [CONFIG=release] clients/mac/Tests/review_scroll_trace.sh path/to/main.tex [OUTDIR]
# Runs in the background (accessory app, doesn't take focus). Sockets in /tmp (sun_path length).
# NO_COMMENTS=1: the same run without comments, as a baseline for the editor alone.
# SYNTH=C,K: instead, the mock's synthetic long review (C tracked changes in clusters, K comments; a long panel).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/review_lib.sh"
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
W=$(mktemp -d)
txs_on_exit 'rm -f "$ES"; rm -rf "$W/proj"'
OUT=${2:-$W/out}
mkdir -p "$OUT" "$W/proj"
cp "$1" "$W/proj/main.tex"
ES=/tmp/txs-margin-st$$.sock
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" ${SYNTH:+--synthetic-review "$SYNTH"} >"$W/mock.log" 2>&1 &
MOCK=$!
txs_track $MOCK
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
ADD="local gui = require('taudot.gui'); local n = vim.api.nvim_buf_line_count(0)
for l = 20, n - 1, 60 do local t = vim.api.nvim_buf_get_lines(0, l, l + 1, false)[1] or ''
  if #t > 8 then gui.act('comment', nil, { text = 'Trace comment at ' .. l, line = l, col = 0, end_line = l, end_col = 8 }) end end"
[ -n "${NO_COMMENTS:-}${SYNTH:-}" ] && ADD="return"  # baseline: the editor alone (the margin has nothing to do)
TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_COMMENTS=shown TAUDOT_EXEC="$ADD" TAUDOT_SCROLLTRACE="$OUT/scroll.txt" TAUDOT_MARGIN_TRACE="$OUT/margin.txt" \
  "$MAC/.build/${CONFIG:-debug}/taudot-app" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!
txs_track $APP
i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 1800 ]; do i=$((i+1)); sleep 0.1; done
txs_stop  # (the app with its Neovim and TeXpresso, and the engine)
echo "out: $OUT"
