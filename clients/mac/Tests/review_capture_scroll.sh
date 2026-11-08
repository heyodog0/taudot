#!/bin/sh
# What the screen shows while scrolling, frame by frame: the real app (release taudot-app) on a COPY of a .tex file,
# mock engine, a cluster of comments on and between long wrapped lines (one range across several), trackpad flicks
# (real events with phases and momentum, through the window server), the window recorded with ScreenCaptureKit.
# Cards carry a green marker (TAUDOT_MARGIN_MARKERS), comment lines a magenta first cell, every 6th line a cyan
# one; review_capture_analyse.py turns the frames into card-vs-text numbers.
#   swift build -c release --product taudot-app && clients/mac/Tests/review_capture_scroll.sh FILE.tex [OUTDIR]
# Opt-in (TAUDOT_ONSCREEN=1): brings the app to the front for ~25 s (the pointer must be over it for the scroll events).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/review_lib.sh"
txs_onscreen_only "trackpad flicks through the window server and a ScreenCaptureKit recording"
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
W=$(mktemp -d)
txs_on_exit 'rm -f "$ES" "$NS"; rm -rf "$W/proj"'
OUT=${2:-$W/out}
mkdir -p "$OUT" "$W/proj"
cp "$1" "$W/proj/main.tex"
swiftc -O -o "$W/review_capture" "$HERE/review_capture.swift" || exit 1
ES=/tmp/txs-margin-cs$$.sock
NS=/tmp/txs-margin-csn$$.sock
PY="uvx --quiet --with pyobjc-framework-Quartz --with pyobjc-framework-ApplicationServices python -I"
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" ${SYNTH:+--synthetic-review "$SYNTH"} >"$W/mock.log" 2>&1 &
MOCK=$!
txs_track $MOCK
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
cat >"$W/setup.lua" <<'LUA'
local ns_path = ...
vim.fn.serverstart(ns_path)
vim.defer_fn(function()
  local g, api = require('taudot.gui'), vim.api
  local ls = api.nvim_buf_get_lines(0, 0, -1, false)
  -- The first run of long (wrapping) lines after line 100: the cluster.
  local start
  for i = 100, #ls - 20 do
    if #ls[i] > 150 and #ls[i + 1] > 150 then start = i - 1 break end
  end
  start = start or 100
  local lines = { start, start + 1, start + 3, start + 4, start + 8, start + 30, start + 31 }
  local made = {}
  for k, l in ipairs(lines) do
    local t = ls[l + 1] or ''
    if #t > 6 then
      local e = (k == 1) and { l + 2, math.min(10, #(ls[l + 3] or '')) } or { l, math.min(#t, 20) }
      g.act('comment', nil, { text = 'capture ' .. k, line = l, col = 0, end_line = e[1], end_col = e[2] })
      made[#made + 1] = l
    end
  end
  api.nvim_set_hl(0, 'E2EMarkM', { fg = '#ff00ff', bg = '#ff00ff' })
  api.nvim_set_hl(0, 'E2EMarkC', { fg = '#00ffff', bg = '#00ffff' })
  local mns = api.nvim_create_namespace('e2e.marks')
  local is_c = {}
  for _, l in ipairs(made) do is_c[l] = true end
  for l = 0, #ls - 1 do
    if #ls[l + 1] > 0 and (is_c[l] or l % 6 == 0) then
      api.nvim_buf_set_extmark(0, mns, l, 0, { end_col = 1, hl_group = is_c[l] and 'E2EMarkM' or 'E2EMarkC', priority = 10000 })
    end
  end
  vim.g.e2e_lines = made
  vim.o.cursorline = false
  api.nvim_win_set_cursor(0, { math.max(1, start - 10), 0 })
  vim.cmd('normal! zt')
end, 800)
LUA
TAUDOT_SOCKET="$ES" TAUDOT_DEBUG=1 TAUDOT_MARGIN_MARKERS=1 TAUDOT_MARGIN_TRACE="$OUT/margin.txt" TAUDOT_EXEC="loadfile('$W/setup.lua')('$NS')" \
  "$MAC/.build/release/taudot-app" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!
txs_track $APP
i=0; while [ ! -S "$NS" ] && [ $i -lt 300 ]; do i=$((i+1)); sleep 0.1; done
[ -S "$NS" ] || { echo "no nvim server"; cat "$W/app.log"; exit 1; }
lua() { nvim --server "$NS" --headless --remote-expr "luaeval('$1')" 2>&1; }
WIN=""; i=0; while [ -z "$WIN" ] && [ $i -lt 50 ]; do WIN=$(sed -n 's/^taudot: window //p' "$W/app.log" | head -1); i=$((i+1)); sleep 0.1; done
sleep 4
echo "comment lines: $(lua 'table.concat(vim.g.e2e_lines, [[ ]])')"
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$APP"') to true' >/dev/null 2>&1
sleep 0.5
F=$($PY "$HERE/review_ax_frames.py" $APP)
GEOM=$(uv run --no-project python -I -c "
import json,sys; f=json.loads(sys.argv[1]); sp=sorted(f['splitters']); w=f['window']
right = sp[1][0] if len(sp)>1 else w[0]+w[2]
print(f\"{sp[0][0]-w[0]:.0f} {(sp[0][0]+right)/2:.0f},{f['split'][1]+f['split'][3]/2:.0f}\")" "$F")
SPLIT=${GEOM% *}; AT=${GEOM#* }
echo "margin|editor split at $SPLIT pt; scrolling at $AT"
"$W/review_capture" "$WIN" 16 "$SPLIT" >"$OUT/frames.txt" 2>"$OUT/capture.log" &
CAP=$!
txs_track $CAP
sleep 1
for k in 1 2 3; do $PY "$HERE/review_events.py" $APP flick "$AT" -14 8 momentum; sleep 0.3; done
for k in 1 2 3; do $PY "$HERE/review_events.py" $APP flick "$AT" 14 8 momentum; sleep 0.3; done
for k in 1 2; do $PY "$HERE/review_events.py" $APP flick "$AT" -4 40; sleep 0.2; done
wait $CAP
cat "$OUT/capture.log"
echo "frames: $OUT/frames.txt"
