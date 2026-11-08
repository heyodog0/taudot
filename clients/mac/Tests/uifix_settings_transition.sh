#!/bin/sh
# Settings page transitions (brief uifix, item 1): opens Settings off screen on FROM, goes to the sections in GO
# (TAUDOT_SETTINGS_GO, one every 1.5 s) and captures the window in a burst through each change, light and dark.
# Frames into OUT (default /tmp/txs-settings-transition); a look at them shows whether the titles ever overlap.
#   swift build --product taudot-app && clients/mac/Tests/uifix_settings_transition.sh [OUT] [FROM] [GO]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
. "$HERE/shell_lib.sh"
OUT=${1:-/tmp/txs-settings-transition}; FROM=${2:-Appearance}; GO=${3:-Editor,PDF}
mkdir -p "$OUT"; rm -f "$OUT"/*.png
W=$(mktemp -d)
on_exit 'rm -rf "$W"'
n_go=$(echo "$GO" | tr ',' '\n' | wc -l | tr -d ' ')
for look in light dark; do
  rm -f "$W/win"
  TAUDOT_SETTINGSSHOT=$FROM TAUDOT_SETTINGS_GO=$GO TAUDOT_SETTINGS_APPEARANCE=$look TAUDOT_SETTINGS_WINFILE="$W/win" \
    TAUDOT_NO_PREWARM=1 "$APP_BIN" -taudot.fontFamily Menlo -taudot.fontSize 13 -taudot.editorMode neovim \
    >"$W/app.log" 2>&1 &
  started $!
  i=0; while [ ! -s "$W/win" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
  N=$(cat "$W/win" 2>/dev/null)
  [ -n "$N" ] || { echo "FAIL: no window"; tail -5 "$W/app.log"; exit 1; }
  # the first go is 1.5 s after show, the window file 1.2 s: frames from just before it through the last change
  end=$(echo "1.2 + 1.5 * $n_go + 0.4" | bc)
  now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
  t0=$(now); k=0
  while :; do
    [ "$(echo "$(now) - $t0 > $end - 1.2" | bc)" = 1 ] && break
    screencapture -x -o -l"$N" "$OUT/$look-$(printf %03d $k).png"; k=$((k+1))
  done
  echo "$look: $k frames"
  stop_all
done
