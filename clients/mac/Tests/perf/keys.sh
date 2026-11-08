#!/bin/sh
# One scripted run with the app's latency probes and an outside capture: the app off every screen (TAUDOT_OFFSCREEN,
# TAUDOT_MEASURE: its window ordered in off-screen and key, so keys posted to its PID land and frames are drawn as for
# the user), probe.swift driving it with SCRIPT and recording the window, then the app's probe ring dumped (SIGUSR1).
#   clients/mac/Tests/perf/keys.sh OUT FOLDER SOCKET SCRIPT SECONDS [VAR=VALUE...]
# OUT/latency.tsv   the app's probes (Sources/TaudotShared/Latency.swift)
# OUT/drive/        probe's record (frames.bin, actions.tsv, clock.txt, ...)
# OUT/app.log       the app's stderr (TAUDOT_TIMELINE milestones)
# Then: uv run clients/mac/Tests/perf/latency.py OUT
#   PERF_APP=<taudot-app>  another build;  PERF_ONSCREEN=1  opt-in on-screen run (behind other windows; logged)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mac=$(cd "$here/../.." && pwd)
out=$1 folder=$2 sock=$3 script=$4 secs=$5
shift 5
app=${PERF_APP:-"$mac/build.noindex/Taudot.app/Contents/MacOS/taudot-app"}
mkdir -p "$out"
out=$(cd "$out" && pwd)
probe="$here/.probe"
[ -x "$probe" ] && [ "$probe" -nt "$here/probe.swift" ] || swiftc -O -swift-version 5 -o "$probe" "$here/probe.swift" 2>/dev/null
if [ -n "${PERF_ONSCREEN:-}" ]; then
  mode="TAUDOT_ONSCREEN=1"; allow=--allow-onscreen
  echo "keys.sh: ON-SCREEN run (PERF_ONSCREEN=1)" >&2
else
  grep -q TAUDOT_MEASURE "$app" || { echo "keys.sh: $app has no TAUDOT_MEASURE (build with Latency probes)" >&2; exit 2; }
  mode="TAUDOT_OFFSCREEN=1"; allow=
fi

tree() { for c in $(pgrep -P "$1"); do tree "$c"; done; echo "$1"; }
stop() {
  [ -n "$1" ] || return 0
  pids=$(tree "$1" | tr '\n' ' ')
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  sleep 1
  for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
}
probe_pid=
cleanup() { for p in $(cut -f1 "$out/drive/procs.tsv" 2>/dev/null); do stop "$p"; done; stop "$probe_pid"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

rm -rf "$out/drive" "$out/latency.tsv"
env TAUDOT_SOCKET="$sock" $mode TAUDOT_MEASURE=1 TAUDOT_TIMELINE=1 TAUDOT_LATENCY_OUT="$out/latency.tsv" "$@" \
  "$probe" --out "$out/drive" --seconds "$secs" --match "$(basename "$folder")" --script "$script" $allow -- "$app" "$folder" \
  >"$out/app.log" 2>&1 &
probe_pid=$!
wait $probe_pid || true
probe_pid=
app_pid=$(sed -n 's/^probe: pid \([0-9]*\).*/\1/p' "$out/app.log" | head -1)
[ -n "$app_pid" ] && kill -USR1 "$app_pid" 2>/dev/null && sleep 0.5
[ -s "$out/latency.tsv" ] || echo "keys.sh: no latency.tsv (app gone?)" >&2
