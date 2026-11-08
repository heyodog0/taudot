#!/bin/sh
# The floating card while scrolling fast, frame by frame: the real app (release taudot-app) on a COPY of a .tex file,
# mock engine, one comment on a long wrapped line in the middle of the window with the cursor in it, so its card
# floats (MODE hidden: sidebar hidden; files: the sidebar on its Files tab, ⇧⌘E). Fast trackpad flicks with momentum,
# up and down, that keep the line on screen. The card carries a green marker (TAUDOT_MARGIN_MARKERS), the comment's
# line a magenta first cell, every 6th line a cyan one; review_floatscroll_pixels.py turns the frames into numbers.
#   swift build -c release --product taudot-app && clients/mac/Tests/review_floatscroll.sh FILE.tex hidden|files [OUTDIR]
# FS_END / FS_CUR: the comment's end column (default 40) and the cursor's (20); FLICK: points per finger event (12).
# A comment over most of a long line with the cursor deep in it: scrolling drags the cursor through its rows.
# Opt-in (TAUDOT_ONSCREEN=1): brings the app to the front for ~20 s (the pointer must be over it for the scroll events).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/review_lib.sh"
txs_onscreen_only "trackpad flicks through the window server and a ScreenCaptureKit recording"
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
MODE=${2:-hidden}
W=$(mktemp -d)
txs_on_exit 'rm -f "$ES" "$NS"; rm -rf "$W/proj"'
OUT=${3:-$W/out}
mkdir -p "$OUT" "$W/proj"
cp "$1" "$W/proj/main.tex"
swiftc -O -o "$W/review_capture" "$HERE/review_capture.swift" || exit 1
ES=/tmp/txs-margin-fs$$.sock
NS=/tmp/txs-margin-fsn$$.sock
PY="uvx --quiet --with pyobjc-framework-Quartz --with pyobjc-framework-ApplicationServices python -I"
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
MOCK=$!
txs_track $MOCK
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
cat >"$W/setup.lua" <<'LUA'
local ns_path = ...
vim.fn.serverstart(ns_path)
vim.defer_fn(function()
  local g, api = require('taudot.gui'), vim.api
  local ls = api.nvim_buf_get_lines(0, 0, -1, false)
  local l
  for i = 120, #ls - 40 do
    if #ls[i] > 300 and not ls[i]:match('^\\') then l = i - 1 break end
  end
  l = l or 120
  local e = math.min(#ls[l + 1], tonumber(vim.env.FS_END or '40'))
  g.act('comment', nil, { text = 'A floating comment, measured while scrolling.', line = l, col = 10, end_line = l, end_col = e })
  api.nvim_set_hl(0, 'E2EMarkM', { fg = '#ff00ff', bg = '#ff00ff' })
  api.nvim_set_hl(0, 'E2EMarkC', { fg = '#00ffff', bg = '#00ffff' })
  local mns = api.nvim_create_namespace('e2e.marks')
  for k = 0, #ls - 1 do
    if #ls[k + 1] > 0 and k ~= l and k % 6 == 0 then
      api.nvim_buf_set_extmark(0, mns, k, 0, { end_col = 1, hl_group = 'E2EMarkC', priority = 10000 })
    end
  end
  -- The comment's line: its range's last character (the row the card sits under).
  api.nvim_buf_set_extmark(0, mns, l, e - 1, { end_col = e, hl_group = 'E2EMarkM', priority = 10000 })
  vim.g.e2e_line = l
  vim.o.cursorline = false
  vim.o.scrolloff = 0
  api.nvim_win_set_cursor(0, { l + 1, tonumber(vim.env.FS_CUR or '20') })
  vim.cmd('normal! zz')
end, 800)
LUA
TAUDOT_SOCKET="$ES" TAUDOT_DEBUG=1 TAUDOT_NO_PDF=1 TAUDOT_COMMENTS=hidden TAUDOT_MARGIN_MARKERS=1 \
  TAUDOT_MARGIN_TRACE_FLOAT="$OUT/float.txt" TAUDOT_EXEC="loadfile('$W/setup.lua')('$NS')" \
  "$MAC/.build/release/taudot-app" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!
txs_track $APP
i=0; while [ ! -S "$NS" ] && [ $i -lt 300 ]; do i=$((i+1)); sleep 0.1; done
[ -S "$NS" ] || { echo "no nvim server"; cat "$W/app.log"; exit 1; }
lua() { nvim --server "$NS" --headless --remote-expr "luaeval('$1')" 2>&1; }
WIN=""; i=0; while [ -z "$WIN" ] && [ $i -lt 50 ]; do WIN=$(sed -n 's/^taudot: window //p' "$W/app.log" | head -1); i=$((i+1)); sleep 0.1; done
sleep 4
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$APP"') to true' >/dev/null 2>&1
sleep 0.5
if [ "$MODE" = files ]; then
  $PY "$HERE/review_events.py" $APP key 14 cmd,shift   # ⇧⌘E: the sidebar on Files
  sleep 0.8
fi
# The cursor back in the comment (focus moves don't move it, but make sure), the card shown.
lua "(function() vim.api.nvim_win_set_cursor(0, {vim.g.e2e_line + 1, ${FS_CUR:-20}}) return 1 end)()" >/dev/null
sleep 0.8
echo "comment line $(lua 'vim.g.e2e_line'), mode $MODE"
F=$($PY "$HERE/review_ax_frames.py" $APP)
GEOM=$(uv run --no-project python -I -c "
import json,sys; f=json.loads(sys.argv[1]); sp=sorted(f['splitters']); w=f['window']
left = sp[0][0] if sp else w[0]
right = sp[1][0] if len(sp)>1 else w[0]+w[2]
print(f\"{left-w[0]+1:.0f} {(left+right)/2:.0f},{f['split'][1]+f['split'][3]/2:.0f}\")" "$F")
SPLIT=${GEOM% *}; AT=${GEOM#* }
echo "editor from $SPLIT pt; scrolling at $AT"
screencapture -x -o -l"$WIN" "$OUT/before.png"
"$W/review_capture" "$WIN" 14 "-$SPLIT" >"$OUT/frames.txt" 2>"$OUT/capture.log" &
CAP=$!
txs_track $CAP
sleep 1
for k in 1 2 3; do
  $PY "$HERE/review_events.py" $APP flick "$AT" -${FLICK:-12} 6 momentum; sleep 0.25
  $PY "$HERE/review_events.py" $APP flick "$AT" ${FLICK:-12} 6 momentum; sleep 0.25
done
for k in 1 2; do $PY "$HERE/review_events.py" $APP flick "$AT" -3 40; $PY "$HERE/review_events.py" $APP flick "$AT" 3 40; done
wait $CAP
cat "$OUT/capture.log"
echo "cursor after: $(lua 'table.concat(vim.api.nvim_win_get_cursor(0), [[:]])')"
uv run --no-project python -I "$HERE/review_floatscroll_pixels.py" "$OUT/frames.txt"
echo "frames: $OUT/frames.txt"
