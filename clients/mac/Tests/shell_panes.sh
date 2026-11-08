#!/bin/sh
# Pane keys in the real app (TAUDOT_PANECHECK): focus cycling with hidden panes, ⌘1–3, ⌘0 / ⇧⌘\, zoom and restore.
# taudot-app (CONFIG=debug|release) on a COPY of FILE.tex with the mock engine, in the background. Exit 1 on a FAIL.
#   swift build --product taudot-app && clients/mac/Tests/shell_panes.sh FILE.tex
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
W=$(mktemp -d); mkdir -p "$W/proj"; cp "$1" "$W/proj/main.tex"
ES=/tmp/txs-panes$$.sock
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
MOCK=$!; started $MOCK
on_exit 'rm -f "$ES"; rm -rf "$W"'
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_COMMENTS=shown TAUDOT_PANECHECK="$W/out.txt" \
  "$APP_BIN" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!; started $APP
i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 600 ]; do i=$((i+1)); sleep 0.1; done
kill $APP 2>/dev/null
cat "$W/out.txt" 2>/dev/null || { echo "FAIL no output"; tail -20 "$W/app.log"; exit 1; }
! grep -q FAIL "$W/out.txt"
