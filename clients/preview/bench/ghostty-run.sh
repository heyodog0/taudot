#!/bin/sh
# Runs one bench against a preview in Ghostty: brings Ghostty to the front, runs bench.ts, then brings Rex back.
#   ghostty-run.sh bench.ts-args...
here=$(cd "$(dirname "$0")" && pwd)
osascript -e 'tell application "Ghostty" to activate' >/dev/null 2>&1
sleep 1.5
deno run -A "$here/bench.ts" --owner Ghostty "$@"
status=$?
osascript -e 'tell application "Rex Beta" to activate' >/dev/null 2>&1
exit $status
