#!/bin/sh
# Comments in the margin beside their lines while the editor font zooms (TAUDOT_ZOOMCHECK, ZoomCheck.swift; editfix
# item 10), in one editor mode. taudot-app on a COPY of FILE.tex with the mock engine, off screen, no keys.
#   swift build --product taudot-app && clients/mac/Tests/zoom_check.sh FILE.tex native|neovim   (FRAMES=1: every frame)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
W=$(mktemp -d); mkdir -p "$W/proj"; cp "$1" "$W/proj/main.tex"
ES=/tmp/txs-zoom$$.sock
on_exit 'rm -f "$ES"; rm -rf "$W"'
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
started $!
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
env TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_EDITOR_MODE=$2 TAUDOT_ZOOMCHECK="$W/out.txt" ${FRAMES:+TAUDOT_ZOOMCHECK_FRAMES=1} \
  TAUDOT_OFFSCREEN=1 "$APP_BIN" "$W/proj" ${APP_ARGS:-} >"$W/app.log" 2>&1 &
APP=$!; started $APP
i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 400 ]; do i=$((i+1)); sleep 0.1; done
cat "$W/out.txt" 2>/dev/null || { echo "FAIL no output"; tail -30 "$W/app.log"; exit 1; }
! grep -q FAIL "$W/out.txt"
