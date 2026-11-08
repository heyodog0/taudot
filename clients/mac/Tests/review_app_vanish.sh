#!/bin/sh
# Comments must not vanish when something else takes Neovim's focus for a moment: a float, Telescope, the cmdline
# window (q:), the : cmdline. The real app (debug taudot-app, the user's Neovim config) against the mock engine with
# three comments. Checks the margin's trace (no empty list applied, every payload for main.tex) and that the margin
# pane stays open (its splitter, through Accessibility). Background run; screenshots in OUTDIR.
#   swift build --product taudot-app && clients/mac/Tests/review_app_vanish.sh [OUTDIR]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/review_lib.sh"
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
W=$(mktemp -d)
txs_on_exit 'rm -f "$ES" "$NS"; rm -rf "$W/proj"'
OUT=${1:-$W/out}
mkdir -p "$OUT" "$W/proj"
cp "$REPO/clients/mock-engine/example/main.tex" "$W/proj/main.tex"
ES=/tmp/txs-margin-va$$.sock
NS=/tmp/txs-margin-van$$.sock
PY="uvx --quiet --with pyobjc-framework-ApplicationServices python -I"
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
MOCK=$!
txs_track $MOCK
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
EXEC="vim.fn.serverstart('$NS'); vim.defer_fn(function() local g = require('taudot.gui'); for _, l in ipairs({1, 9, 14}) do g.act('comment', nil, {text='seed '..l, line=l, col=0, end_line=l, end_col=5}) end end, 500)"
TAUDOT_SOCKET="$ES" TAUDOT_OFFSCREEN=1 TAUDOT_NO_PDF=1 TAUDOT_DEBUG=1 TAUDOT_MARGIN_TRACE="$OUT/trace.txt" TAUDOT_EXEC="$EXEC" \
  "$MAC/.build/debug/taudot-app" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!
txs_track $APP
i=0; while [ ! -S "$NS" ] && [ $i -lt 300 ]; do i=$((i+1)); sleep 0.1; done
[ -S "$NS" ] || { echo "FAIL no nvim server"; exit 1; }
lua() { nvim --server "$NS" --headless --remote-expr "luaeval('$1')" 2>&1; }
WIN=""; i=0; while [ -z "$WIN" ] && [ $i -lt 50 ]; do WIN=$(sed -n 's/^taudot: window //p' "$W/app.log" | head -1); i=$((i+1)); sleep 0.1; done
sleep 3
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }
margin_open() {  # the first splitter well right of the window's left edge: the margin pane is shown
  $PY "$HERE/review_ax_frames.py" $APP | uv run --no-project python -I -c "
import json,sys; f=json.load(sys.stdin); sp=sorted(f['splitters']); print('open' if sp and sp[0][0] - f['window'][0] > 100 else 'hidden')"
}
N=$(lua "#require([[taudot.gui]]).payload().items")
[ "$N" = "3" ] && ok "three comments" || bad "comments: $N"
[ "$(margin_open)" = open ] && ok "margin open" || bad "margin not open at the start"
step() {  # name, lua to open it, lua to close it
  MARK=$(wc -l <"$OUT/trace.txt")
  lua "$2" >/dev/null
  sleep 1.2
  screencapture -x -o -l"$WIN" "$OUT/vanish-$1.png"
  M=$(margin_open)
  lua "$3" >/dev/null
  sleep 0.8
  EMPTY=$(tail -n +$((MARK + 1)) "$OUT/trace.txt" | grep "^[0-9.]* payload" | grep -c "items 0.*applied")
  OTHER=$(tail -n +$((MARK + 1)) "$OUT/trace.txt" | grep "^[0-9.]* payload" | grep -vc "buf 1 ")
  [ "$EMPTY" = 0 ] && [ "$OTHER" = 0 ] && ok "$1: no empty list applied, every payload for main.tex" || bad "$1: $EMPTY empty applied, $OTHER for another buffer"
  [ "$M" = open ] && ok "$1: margin stayed open" || bad "$1: margin $M"
}
step float "(function() local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, false, {[[a float over the text]]}) vim.g.e2e_float = vim.api.nvim_open_win(b, true, {relative=[[editor]], row=3, col=10, width=40, height=4, border=[[rounded]]}) end)()" \
  "vim.api.nvim_win_close(vim.g.e2e_float, true)"
HAS_TS=$(lua "(pcall(require, [[telescope]]) or vim.fn.exists([[:Telescope]]) == 2) and 1 or 0")
echo "     telescope: $HAS_TS"
if [ "$HAS_TS" = "1" ]; then
  step telescope "vim.cmd([[Telescope buffers]])" "vim.api.nvim_input([[<Esc><Esc>]])"
else
  echo "skip telescope: not in this Neovim config"
fi
step cmdwin "vim.api.nvim_input([[q:]])" "vim.api.nvim_input([[:q<CR>]])"
step cmdline "vim.api.nvim_input([[:echo]])" "vim.api.nvim_input([[<Esc>]])"
N=$(lua "#require([[taudot.gui]]).payload().items")
[ "$N" = "3" ] && ok "still three comments after it all" || bad "comments after: $N"
grep "payload" "$OUT/trace.txt" | tail -5 | sed 's/^/     /'
echo "screenshots and trace: $OUT"
[ $fails -eq 0 ] && echo "all ok" || echo "$fails failed"
