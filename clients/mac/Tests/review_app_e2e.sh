#!/bin/sh
# The real app (taudot-app, debug build) against the mock engine: a selection over a wrapped line and the next, a
# real mouse click on the margin's + button, typing, ⌘↩; prints where the comment landed and saves screenshots.
#   swift build --product taudot-app && clients/mac/Tests/review_app_e2e.sh [OUTDIR]
# Opt-in (TAUDOT_ONSCREEN=1): comes to the front for ~10 s (Accessibility + Screen Recording). Types only while the app is frontmost and a
# new-comment field exists. Sockets live in /tmp (a longer path overflows sun_path).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/review_lib.sh"
txs_onscreen_only "typed keys with the app in front"
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
W=$(mktemp -d)
OUT=${1:-$W/out}
mkdir -p "$OUT"
mkdir -p "$W/proj"
cp "$REPO/clients/mock-engine/example/main.tex" "$W/proj/main.tex"
ES=/tmp/txs-margin-e$$.sock
NS=/tmp/txs-margin-n$$.sock
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" --bot --bot-interval 4000 --bot-char 60 >"$W/mock.log" 2>&1 &
echo $! >"$W/mock.pid"; txs_track $!
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_DEBUG=1 TAUDOT_EXEC="vim.fn.serverstart('$NS')" \
  "$MAC/.build/debug/taudot-app" "$W/proj" >"$W/app.log" 2>&1 &
echo $! >"$W/app.pid"; txs_track $!
cleanup() {
  rm -f "$ES" "$NS"
  rm -rf "$W/proj"
}
txs_on_exit cleanup
i=0; while [ ! -S "$NS" ] && [ $i -lt 200 ]; do i=$((i+1)); sleep 0.1; done
[ -S "$NS" ] || { echo "no nvim server"; cat "$W/app.log"; exit 1; }
ev() { nvim --server "$NS" --headless --remote-expr "$1" 2>&1; }
sleep 2
# A long line that wraps, then a visual selection from inside it to the next line.
ev "luaeval('(function() local ls = vim.api.nvim_buf_get_lines(0,0,-1,false) for i=#ls-1,1,-1 do if #ls[i]>45 and #ls[i+1]>10 and not ls[i]:match([[^\\\\]]) then vim.api.nvim_buf_set_lines(0,i-1,i,false,{ls[i]..[[ This sentence is long on purpose, so that the line wraps in the editor at any window width a laptop gives it, twice or more.]]}) vim.g.e2e_row=i-1 return i-1 end end end)()')" >"$W/row"
ROW=$(cat "$W/row")
sleep 1
ev "luaeval('(function() vim.api.nvim_win_set_cursor(0,{$ROW+1,4}) vim.api.nvim_feedkeys([[vj]],[[nx]],false) vim.api.nvim_win_set_cursor(0,{$ROW+2,5}) return vim.api.nvim_get_mode().mode end)()')"
WANT=$(ev "luaeval('(function() local a=vim.api.nvim_buf_get_lines(0,$ROW,$ROW+2,false) return a[1]:sub(5)..[[\\n]]..a[2]:sub(1,6) end)()')")
sleep 0.8
PID=$(cat "$W/app.pid")
# Show the margin (it hides itself while the file has no comments): View > Show/Hide Comments.
osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$PID"')
  set frontmost to true
  click menu item "Show/Hide Comments" of menu 1 of (first menu bar item of menu bar 1 whose name is "View")
end tell' >/dev/null 2>&1
sleep 0.8
WIN=$(sed -n 's/^taudot: window //p' "$W/app.log" | head -1)
# The + button, through Accessibility; then a real mouse click there.
POS=$(uvx --quiet --with pyobjc-framework-ApplicationServices python -I "$HERE/review_ax.py" "$PID" "Comment on the selection" 2>&1)
echo "row $ROW, + at $POS, window $WIN"
screencapture -x -o -l"$WIN" "$OUT/app-selection.png"
echo "$POS" | grep -Eq '^[0-9]+,[0-9]+$' || { echo "no + button"; exit 1; }
uvx --quiet --with pyobjc-framework-Quartz python -I -c "
import Quartz, time, sys
x, y = map(float, sys.argv[1].split(','))
for t in (Quartz.kCGEventMouseMoved, Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
    e = Quartz.CGEventCreateMouseEvent(None, t, (x, y), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e); time.sleep(0.08)
" "$POS"
sleep 1
screencapture -x -o -l"$WIN" "$OUT/app-draft.png"
ev "luaeval('vim.api.nvim_get_mode().mode')" | sed 's/^/mode after click: /'
FRONT=$(osascript -e 'tell application "System Events" to return unix id of first process whose frontmost is true')
DRAFT=$(uvx --quiet --with pyobjc-framework-ApplicationServices python -I "$HERE/review_ax.py" "$PID" "Add a comment" 2>/dev/null)
echo "front $FRONT (app $PID), draft fields: $DRAFT"
if [ "$FRONT" = "$PID" ] && echo "$DRAFT" | grep -Eq '^[0-9]+,[0-9]+$'; then
  osascript -e 'tell application "System Events" to keystroke "Real app comment"' -e 'delay 0.2' -e 'tell application "System Events" to key code 36 using command down'
else
  echo "not typing: the app isn't frontmost or no draft card"
fi
sleep 2
screencapture -x -o -l"$WIN" "$OUT/app-sent.png"
echo "want quote: $WANT"
echo "screenshots: $OUT"
GOT=$(ev "luaeval('(function() for _,it in ipairs(require([[taudot.gui]]).payload().items) do if it.messages[1] and it.messages[1].text==[[Real app comment]] then return table.concat({it.line,it.col,it.end_line,it.end_col},[[ ]])..[[ | ]]..it.quote end end return [[no comment]] end)()')")
echo "comment at: $GOT"
echo "selection was: $ROW 4 $((ROW + 1)) 6"
