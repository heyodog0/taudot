#!/bin/sh
# App menu ▸ About Taudot, light and dark: taudot-app (CONFIG=debug|release) off screen (TAUDOT_ABOUTSHOT), window
# captures into OUT (default /tmp/txs-about): about-light.png, about-dark.png. Checks the version line is shown
# (an unbundled build: "Development build"). Exit 1 on a FAIL.
#   swift build --product taudot-app && clients/mac/Tests/shell_about_shot.sh [OUT]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
. "$HERE/shell_lib.sh"
OUT=${1:-/tmp/txs-about}; mkdir -p "$OUT"
W=$(mktemp -d)
on_exit 'rm -rf "$W"'
for look in light dark; do
  rm -f "$W/win"
  TAUDOT_ABOUTSHOT="$W/win" TAUDOT_ABOUT_APPEARANCE=$look TAUDOT_NO_PREWARM=1 "$APP_BIN" >"$W/app.log" 2>&1 &
  APP=$!; started $APP
  i=0; while [ ! -s "$W/win" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
  [ -s "$W/win" ] || { echo "FAIL $look: no About window"; tail -20 "$W/app.log"; exit 1; }
  N=$(sed -n 1p "$W/win"); V=$(sed -n 2p "$W/win")
  screencapture -x -o -l"$N" "$OUT/about-$look.png"
  case "$V" in "Development build"|Version*) echo "ok   $look: About Taudot shows \"$V\" ($OUT/about-$look.png)";;
    *) echo "FAIL $look: version line \"$V\""; exit 1;; esac
  kill $APP 2>/dev/null; wait $APP 2>/dev/null
done
