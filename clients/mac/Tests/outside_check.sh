#!/bin/sh
# Edits written to the project file on disk while the window is open (TAUDOT_OUTSIDECHECK, OutsideCheck.swift;
# editfix item 9), in one editor mode: highlights in the editor and on the PDF, fading; Changes and Undo; the pill;
# Follow Edits, waiting while keys come. taudot-app on a COPY of FILE.tex (90+ lines "Line N words ...") with the
# mock engine, off screen.  swift build --product taudot-app && clients/mac/Tests/outside_check.sh FILE.tex native|neovim
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
W=$(mktemp -d); mkdir -p "$W/proj"; cp "$1" "$W/proj/main.tex"
ES=/tmp/txs-outside$$.sock
on_exit 'rm -f "$ES"; rm -rf "$W"'
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
started $!
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
env TAUDOT_SOCKET="$ES" TAUDOT_EDITOR_MODE=$2 TAUDOT_OUTSIDECHECK="$W/out.txt" ${3:+TAUDOT_OUTSIDECHECK_SHOT=$3} \
  TAUDOT_OFFSCREEN=1 "$APP_BIN" "$W/proj" ${APP_ARGS:-} >"$W/app.log" 2>&1 &
APP=$!; started $APP
i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 1200 ]; do i=$((i+1)); sleep 0.1; done
cat "$W/out.txt" 2>/dev/null || { echo "FAIL no output"; tail -30 "$W/app.log"; exit 1; }
! grep -q FAIL "$W/out.txt"
