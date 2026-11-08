#!/bin/sh
# The floating card of the comment under the cursor (TAUDOT_FLOATCHECK, FloatCheck.swift), comments pane hidden, in
# one editor mode. taudot-app on a COPY of FILE.tex with the mock engine, off screen, no keys.
#   swift build --product taudot-app && clients/mac/Tests/uifix_float.sh FILE.tex native|neovim [SHOT.png [SHOT-HIDDEN.png [SHOT-MARGIN.png]]]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
W=$(mktemp -d); mkdir -p "$W/proj"; cp "$1" "$W/proj/main.tex"
ES=/tmp/txs-float$$.sock
on_exit 'rm -f "$ES"; rm -rf "$W"'
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
started $!
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
env TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_COMMENTS=hidden TAUDOT_EDITOR_MODE=$2 TAUDOT_FLOATCHECK="$W/out.txt" \
  ${3:+TAUDOT_FLOATCHECK_SHOT=$3} ${4:+TAUDOT_FLOATCHECK_SHOT_HIDDEN=$4} ${5:+TAUDOT_FLOATCHECK_SHOT_MARGIN=$5} TAUDOT_OFFSCREEN=1 "$APP_BIN" "$W/proj" ${APP_ARGS:-} >"$W/app.log" 2>&1 &
APP=$!; started $APP
i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 400 ]; do i=$((i+1)); sleep 0.1; done
cat "$W/out.txt" 2>/dev/null || { echo "FAIL no output"; tail -30 "$W/app.log"; exit 1; }
! grep -q FAIL "$W/out.txt"
