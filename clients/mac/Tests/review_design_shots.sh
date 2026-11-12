#!/bin/sh
# Screenshots of the review margin's designs: each direction (TAUDOT_MARGIN_DESIGN = classic, quiet,
# rail, overleaf) in the real app on a synthetic doc (the mock's --synthetic-review: three reviewers' suggestions in
# clusters, a few comments), Neovim's default colours dark and light: at the top of the file, and mid-file with a
# comment selected (its card and its tint), the sidebar on Comments.
#   swift build --product taudot-app && clients/mac/Tests/review_design_shots.sh OUTDIR [DESIGNS] [C,K]
# Runs in the background (TAUDOT_OFFSCREEN=1: never activates; the window is captured where it is, behind).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/review_lib.sh"
txs_on_exit 'rm -f "${ES:-}" "${NS:-}"; [ -n "${W:-}" ] && rm -rf "$W"; [ -n "${KEY:-}" ] && defaults delete taudot-app "$KEY" 2>/dev/null; true'
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
OUT=$1
DESIGNS=${2:-classic quiet rail overleaf}
SYN=${3:-30,6}
mkdir -p "$OUT"
LAYOUT_TAG="/${LAYOUT:+$LAYOUT-}"
for D in $DESIGNS; do
  W=$(mktemp -d); mkdir -p "$W/proj"
  deno run -A "$REPO/clients/mock-engine/synthetic.ts" "$W/proj/main.tex" 40
  ES=/tmp/txs-ds$$.sock; NS=/tmp/txs-dsn$$.sock
  deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" --synthetic-review "$SYN" >"$W/mock.log" 2>&1 &
  MOCK=$!
  txs_track $MOCK
  i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
  KEY="taudot.panes.$W/proj"
  defaults write taudot-app "$KEY" -dict marginHidden -bool false marginManual -bool true pdfHidden -bool true
  # LAYOUT=stacked: the Comments tab's stacked list (Layout ▸ Stacked, remembered per project).
  [ -n "${LAYOUT:-}" ] && defaults write taudot-app "taudot.sidebar.layout.$W/proj" "$LAYOUT"
  TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_DEBUG=1 TAUDOT_COMMENTS=shown TAUDOT_MARGIN_DESIGN="$D" TAUDOT_OFFSCREEN=1 \
    TAUDOT_EXEC="vim.fn.serverstart('$NS')" "$MAC/.build/debug/taudot-app" "$W/proj" >"$W/app.log" 2>&1 &
  APP=$!
  txs_track $APP
  i=0; while [ ! -S "$NS" ] && [ $i -lt 300 ]; do i=$((i+1)); sleep 0.1; done
  lua() { nvim --server "$NS" --headless --remote-expr "luaeval('$1')" 2>&1; }
  WIN=""; i=0; while [ -z "$WIN" ] && [ $i -lt 80 ]; do WIN=$(sed -n 's/^taudot: window //p' "$W/app.log" | head -1); i=$((i+1)); sleep 0.1; done
  sleep 4
  for bg in dark light; do
    lua "(function() vim.o.background = [[$bg]]; vim.cmd.colorscheme([[default]]); vim.o.cursorline = false; return 1 end)()" >/dev/null
    # The top of the file, the cursor on line 1: the case where cards used to sit above the header.
    lua "(function() vim.api.nvim_win_set_cursor(0, {1, 0}); vim.cmd([[normal! gg]]); return 1 end)()" >/dev/null
    sleep 1.2; screencapture -x -o -l"$WIN" "$OUT$LAYOUT_TAG$D-top-$bg.png"
    # Mid-file on the second comment, a few lines down from the top of the view.
    lua "(function() local b = require([[taudot.buffer]]).by_buf[vim.api.nvim_get_current_buf()]; local n = 0
      for _, it in ipairs(b:review_items(false)) do if it.r.kind == [[comment]] then n = n + 1
        if n == 2 then vim.api.nvim_win_set_cursor(0, {math.max(1, it.row - 4), 0}); vim.cmd([[normal! zt]]); vim.api.nvim_win_set_cursor(0, {it.row + 1, it.col + 1}); break end end end
      return 1 end)()" >/dev/null
    sleep 1.2; screencapture -x -o -l"$WIN" "$OUT$LAYOUT_TAG$D-selected-$bg.png"
    # A new comment on the file's first two lines (the draft must sit fully inside the panel).
    lua "(function() vim.api.nvim_win_set_cursor(0, {1, 0}); vim.cmd([[normal! gg]]); vim.cmd([[normal! Vj]]); require([[taudot.review]]).comment({}); return 1 end)()" >/dev/null
    sleep 1.2; screencapture -x -o -l"$WIN" "$OUT$LAYOUT_TAG$D-draft-top-$bg.png"
    lua "(function() vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes([[<Esc>]], true, false, true), [[nx]], false); return 1 end)()" >/dev/null
  done
  txs_stop  # (this design's app, its Neovim and the mock, before the next)
  rm -f "$ES" "$NS"; rm -rf "$W"; defaults delete taudot-app "$KEY" 2>/dev/null; defaults delete taudot-app "taudot.sidebar.layout.$W/proj" 2>/dev/null
  echo "$D done"
done
