#!/bin/sh
# Screenshots of the home window (home-*.png), light and dark: signed out (an engine with no
# session) and the list (an engine signed in to the local CE).
# By default nothing shows on screen: HomeHost runs in the background with its window off every screen, so controls
# draw inactive. TAUDOT_ONSCREEN=1 (opt-in, rare, note it in your log) puts the window on screen and brings it to
# the front for about a second per shot, for the active look.
#   Tests/home_shots.sh SIGNED_OUT_SOCKET SIGNED_IN_SOCKET OUTDIR
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
out_sock=$1 in_sock=$2 dir=$3
(cd "$here" && swift build --product HomeHost 2>&1 | grep error: || true)
bin="$here/.build/debug/HomeHost"
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; true' EXIT INT TERM
shoot() {  # env... -- runs HomeHost until it quits (on screen: keeping it frontmost)
  env "$@" "$bin" &
  pid=$!
  while kill -0 $pid 2>/dev/null; do
    if [ "${TAUDOT_ONSCREEN:-}" = 1 ]; then
      osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
    fi
    sleep 0.3
  done
  pid=
}
for a in light dark; do
  shoot TAUDOT_APPEARANCE=$a TAUDOT_SOCKET="$out_sock" TAUDOT_SERVER="${TAUDOT_SERVER:-https://www.overleaf.com}" TAUDOT_HOME_SHOT="$dir/shot-$a"
  shoot TAUDOT_APPEARANCE=$a TAUDOT_SOCKET="$in_sock" TAUDOT_SERVER=http://localhost:8800 TAUDOT_HOME_SHOT="$dir/shot-$a" TAUDOT_HOME_STAGE=cloning
done
# HomeHost writes <prefix>-<state>.png; the docs name them glass-<state>-<appearance>.png.
for a in light dark; do
  for s in signed-out list cloning; do
    [ -f "$dir/shot-$a-$s.png" ] && mv "$dir/shot-$a-$s.png" "$dir/home-$(echo $s | tr -d -)-$a.png"
  done
done
