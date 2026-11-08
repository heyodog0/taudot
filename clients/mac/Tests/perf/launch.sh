#!/bin/sh
# Launch timings: N launches of the release app on FOLDER, each recorded by probe, then analysed.
#   clients/mac/Tests/perf/launch.sh OUT FOLDER SOCKET N [SECONDS] [VAR=VALUE...]
# FOLDER "-": launched without a folder; the Projects window (sign-in and the projects list) is measured.
#
# Off the user's screen (docs/agents/README.md, "Tests must not disturb the user's screen"): the app runs with
# TAUDOT_OFFSCREEN=1 (no Dock icon, never activated, windows off every display) and probe stops it if a window
# comes on screen anyway. An app without TAUDOT_OFFSCREEN is refused. PERF_ONSCREEN=1 opts into an on-screen run
# (behind other windows, TAUDOT_ONSCREEN): rare, batched, noted in the log.
#   PERF_APP=<path to taudot-app>   another build (default: clients/mac/build.noindex/Taudot.app)
#   XDG_CACHE_HOME=<empty dir>       among the VARs: TeXpresso without its format cache
#   TAUDOT_PAGE_CACHE=<dir>         among the VARs: the PDF pane's page cache (empty dir: no last PDF)
# The app gets this shell's environment, as an `open` from a terminal does. TAUDOT_TIMELINE=1: its own milestones
# go to OUT/runN.log. Each run's app and children are stopped by PID, also on Ctrl-C.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mac=$(cd "$here/../.." && pwd)
out=$1 folder=$2 sock=$3 n=$4 secs=${5:-12}
shift 4; [ $# -gt 0 ] && shift
app=${PERF_APP:-"$mac/build.noindex/Taudot.app/Contents/MacOS/taudot-app"}
if [ -n "${PERF_ONSCREEN:-}" ]; then
  mode="TAUDOT_ONSCREEN=1"; allow=--allow-onscreen
  echo "launch.sh: ON-SCREEN run (PERF_ONSCREEN=1)" >&2
else
  grep -qE "TAUDOT_OFFSCREEN|TEXSYNC_OFFSCREEN" "$app" ||  # (TEXSYNC_: a pre-rename build, for A/B)
    { echo "launch.sh: $app has no TAUDOT_OFFSCREEN; refusing to put windows on the user's screen (PERF_ONSCREEN=1 to opt in)" >&2; exit 2; }
  mode="TAUDOT_OFFSCREEN=1"; allow=
fi
probe="$out/probe"
mkdir -p "$out"
[ -x "$probe" ] && [ "$probe" -nt "$here/probe.swift" ] || swiftc -O -swift-version 5 -o "$probe" "$here/probe.swift" 2>/dev/null
title=$(basename "$folder"); target="$folder"
if [ "$folder" = "-" ]; then
  title=Projects; target=
  # The Projects window talks to the server in the app's settings (the user's overleaf.com account): force the
  # local CE, never the user's account.
  export TAUDOT_SERVER=${PERF_SERVER:-http://localhost:8800}
  case "$TAUDOT_SERVER" in http://localhost:*|http://127.0.0.1:*) ;; *) echo "launch.sh: Projects window runs only against a local CE" >&2; exit 2;; esac
fi

tree() { for c in $(pgrep -P "$1"); do tree "$c"; done; echo "$1"; }
stop() {  # $1: a pid; stops it and everything under it (TeXpresso's xetex forks, Neovim, Claude)
  [ -n "$1" ] || return 0
  pids=$(tree "$1" | tr '\n' ' ')
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  sleep 1
  for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
}
probe_pid=
cleanup() { stop "$probe_pid"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

i=1
while [ $i -le "$n" ]; do
  d="$out/run$i"; rm -rf "$d"
  env TAUDOT_SOCKET="$sock" $mode TAUDOT_TIMELINE=1 "$@" \
    "$probe" --out "$d" --seconds "$secs" --match "$title" $allow -- "$app" ${target:+"$target"} >"$d.log" 2>&1 &
  probe_pid=$!
  wait $probe_pid || true
  # probe exits with the app still running: stop the app's tree (recorded by probe) and anything left under it.
  for p in $(cut -f1 "$d/procs.tsv" 2>/dev/null); do stop "$p"; done
  stop "$probe_pid"; probe_pid=
  i=$((i + 1))
done
uv run -q "$here/analyse.py" "$out"/run[0-9]*/ > "$out/milestones.jsonl"
cat "$out/milestones.jsonl"
