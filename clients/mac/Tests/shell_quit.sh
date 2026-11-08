#!/bin/sh
# ⌘Q and ⌘W in the real app, with a modified taudot buffer and Neovim left in insert mode: the app must exit within
# a few seconds without asking anything (TAUDOT_QUIT_ANSWER=cancel would keep it open if it asked), and take its
# Neovim with it. taudot-app (CONFIG=debug|release) on a COPY of FILE.tex, mock engine, in the background.
#   swift build --product taudot-app && clients/mac/Tests/shell_quit.sh FILE.tex
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
fail=0
for how in quit close; do
  W=$(mktemp -d); mkdir -p "$W/proj"; cp "$1" "$W/proj/main.tex"
  ES=/tmp/txs-quit$$.sock
  on_exit 'rm -f "$ES"; rm -rf "$W"'
  deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
  MOCK=$!; started $MOCK
  i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
  EDIT="vim.defer_fn(function()
    local b = vim.api.nvim_get_current_buf()
    local ok, B = pcall(require, 'taudot.buffer')
    vim.fn.writefile({ (ok and B.by_buf[b]) and 'taudot' or 'other', vim.api.nvim_buf_get_name(b) }, '$W/buf.txt')
    vim.api.nvim_buf_set_lines(b, 0, 0, false, { '% typed before quitting' })
    vim.bo[b].modified = true
    vim.api.nvim_feedkeys('ihalf-typed', 'n', false)
  end, 1500)"
  TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_EXEC="$EDIT" TAUDOT_QUIT_TEST="$how:7" TAUDOT_QUIT_ANSWER=cancel \
    "$APP_BIN" "$W/proj" >"$W/app.log" 2>&1 &
  APP=$!; started $APP
  sleep 5
  NV=$(pgrep -P $APP nvim | head -1)
  i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 50 ]; do i=$((i+1)); sleep 0.1; done
  if kill -0 $APP 2>/dev/null; then
    echo "FAIL $how: the app is still running 3 s after the request"; fail=1; kill $APP
  else
    echo "ok   $how: the app exited ($(cat "$W/buf.txt" 2>/dev/null | head -1) buffer modified, insert mode)"
  fi
  if [ -n "$NV" ] && kill -0 "$NV" 2>/dev/null; then echo "FAIL $how: its Neovim ($NV) is still running"; fail=1; kill -9 "$NV"; fi
  grep -q taudot "$W/buf.txt" 2>/dev/null || { echo "FAIL $how: the buffer wasn't a taudot buffer"; fail=1; }
  stop_all; rm -f "$ES"; rm -rf "$W"
done
exit $fail
