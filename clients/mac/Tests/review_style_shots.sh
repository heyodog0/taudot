#!/bin/sh
# Screenshots for docs/agents/margin-float.md: every comment_style, cursor outside and inside a comment, on Neovim's
# default colourscheme dark and light, and the floating card (below, above, stacked, following a scroll, a reply
# being typed). The real app (debug taudot-app) on a COPY of a .tex file, mock engine, the margin hidden.
#   swift build --product taudot-app && clients/mac/Tests/review_style_shots.sh FILE.tex OUTDIR
# Runs in the background (TAUDOT_OFFSCREEN=1: never activates; the window is captured where it is, behind).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/review_lib.sh"
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
OUT=$2
mkdir -p "$OUT"
W=$(mktemp -d)
txs_on_exit 'rm -f "$ES" "$NS"; rm -rf "$W/proj"; defaults delete taudot-app "$KEY" 2>/dev/null'
mkdir -p "$W/proj"
cp "$1" "$W/proj/main.tex"
ES=/tmp/txs-margin-ss$$.sock
NS=/tmp/txs-margin-ssn$$.sock
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
  -- A run of long (wrapping) prose lines after line 60.
  local start
  for i = 60, #ls - 20 do
    if #ls[i] > 200 and #ls[i + 2] > 120 and not ls[i]:match('^\\') then start = i - 1 break end
  end
  start = start or 60
  local function at(l, word0, words)
    -- byte range of `words` words starting at word number word0 on line l
    local t = ls[l + 1]
    local s, e, k = nil, nil, 0
    for a, b in t:gmatch('()%S+()') do
      if k == word0 then s = a - 1 end
      if k == word0 + words - 1 then e = b - 1 break end
      k = k + 1
    end
    return s or 0, e or math.min(#t, 20)
  end
  local c1, e1 = at(start, 3, 4)
  local c2, e2 = at(start, 40, 18)  -- over a wrap
  local c3, e3 = at(start + 2, 2, 5)
  g.act('comment', nil, { text = 'Is this the right claim? The cited result is for a different setting.', line = start, col = c1, end_line = start, end_col = e1 })
  g.act('comment', nil, { text = 'This sentence runs on across the line; split it?', line = start, col = c2, end_line = start, end_col = e2 })
  g.act('comment', nil, { text = 'Define the acronym on first use.', line = start + 2, col = c3, end_line = start + 2, end_col = e3 })
  g.act('comment', nil, { text = 'Also: cite the original paper here.', line = start + 2, col = c3, end_line = start + 2, end_col = e3 })
  vim.g.shot = { start = start, c1 = c1, c2 = c2, c3 = c3 }
  vim.o.cursorline = false
  api.nvim_win_set_cursor(0, { math.max(1, start - 3), 0 })
  vim.cmd('normal! zt')
end, 800)
LUA
# The margin hidden (the floating card's case), as the user would have it: this folder's pane state, removed after.
KEY="taudot.panes.$W/proj"
defaults write taudot-app "$KEY" -dict marginHidden -bool true marginManual -bool true pdfHidden -bool true
TAUDOT_SOCKET="$ES" TAUDOT_OFFSCREEN=1 TAUDOT_NO_PDF=1 TAUDOT_DEBUG=1 TAUDOT_EXEC="loadfile('$W/setup.lua')('$NS')" \
  "$MAC/.build/debug/taudot-app" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!
txs_track $APP
i=0; while [ ! -S "$NS" ] && [ $i -lt 300 ]; do i=$((i+1)); sleep 0.1; done
[ -S "$NS" ] || { echo "no nvim server"; cat "$W/app.log"; exit 1; }
lua() { nvim --server "$NS" --headless --remote-expr "luaeval('$1')" 2>&1; }
WIN=""; i=0; while [ -z "$WIN" ] && [ $i -lt 50 ]; do WIN=$(sed -n 's/^taudot: window //p' "$W/app.log" | head -1); i=$((i+1)); sleep 0.1; done
sleep 4
echo "comments at line $(lua 'vim.g.shot.start')"
shot() { screencapture -x -o -l"$WIN" "$OUT/$1.png"; echo "$OUT/$1.png"; }
restyle() { lua "(function() require([[taudot.config]]).options.comment_style = [[$1]]; for _, b in pairs(require([[taudot.buffer]]).by_buf) do b:set_ranges(b.ranges, b.seq) end; return 1 end)()" >/dev/null; }
cursor() { lua "(function() vim.api.nvim_win_set_cursor(0, {$1, $2}) return 1 end)()" >/dev/null; }
S=$(lua 'vim.g.shot.start'); C3=$(lua 'vim.g.shot.c3'); C1=$(lua 'vim.g.shot.c1')
for bg in dark light; do
  lua "(function() vim.o.background = [[$bg]]; vim.cmd.colorscheme([[default]]); return 1 end)()" >/dev/null
  for style in tint tint+underline underline bar; do
    name=$(echo "$style" | tr '+' '-')
    restyle "$style"
    cursor $((S - 1)) 0; sleep 0.5; shot "style-$name-$bg-out" >/dev/null
    cursor $((S + 3)) $((C3 + 2)); sleep 0.7; shot "style-$name-$bg-in" >/dev/null
  done
done
# The floating card, on the default (tint) style, dark.
lua "(function() vim.o.background = [[dark]]; vim.cmd.colorscheme([[default]]); return 1 end)()" >/dev/null
restyle tint
cursor $((S + 1)) $((C1 + 1)); sleep 0.7; shot float-below
cursor $((S + 3)) $((C3 + 2)); sleep 0.7; shot float-stacked
lua '(function() vim.cmd([[exe "normal! 3\<C-e>"]]) return 1 end)()' >/dev/null; sleep 0.5; shot float-scrolled
# near the window's bottom: above the line
lua "(function() vim.fn.winrestview({ topline = math.max(1, $S + 3 - vim.api.nvim_win_get_height(0) + 3) }) vim.api.nvim_win_set_cursor(0, {$S + 3, $C3 + 2}) return 1 end)()" >/dev/null
sleep 0.7; shot float-above
# typing in the commented text: same card, keys in Neovim
lua "(function() vim.fn.winrestview({ topline = math.max(1, $S - 3) }) vim.api.nvim_win_set_cursor(0, {$S + 1, $C1 + 2}) return 1 end)()" >/dev/null
sleep 0.5
lua '(function() vim.api.nvim_feedkeys([[iquite ]], [[nx]], false) return vim.api.nvim_get_mode().mode end)()' >/dev/null
sleep 0.6; shot float-typing
lua '(function() vim.cmd.stopinsert() return 1 end)()' >/dev/null
echo "mode after typing: $(lua 'vim.api.nvim_get_mode().mode')"
# light appearance of the card
lua "(function() vim.o.background = [[light]]; vim.cmd.colorscheme([[default]]); return 1 end)()" >/dev/null
cursor $((S + 1)) $((C1 + 1)); sleep 0.7; shot float-light-scheme
grep -i "error\|fatal" "$W/app.log" | head -5
