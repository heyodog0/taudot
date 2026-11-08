#!/bin/sh
# Steady state: CPU %, wakeups/s (context switches), RSS and energy impact of the app and every process under it
# (Neovim, txp-headless, TeXpresso's xetex forks, Claude, followed as they come and go), and the engine (ENGINE_PID).
#   clients/mac/Tests/perf/steady.sh OUT FOLDER SOCKET SECONDS [ENGINE_PID] [VAR=VALUE...]
# Launches the release app off the user's screen (TAUDOT_OFFSCREEN=1, see launch.sh), waits 15 s for it to settle,
# samples every process with `top` once a second for SECONDS, then stops the app's tree by PID (also on Ctrl-C).
#   PROBE_SCRIPT=F    probe.swift drives it meanwhile (keys and menus go to the app's PID, never the HID stream);
#                     its clock starts with the sampling; OUT/drive/ has its record
#   PHASES="idle:2:20 typing:25:45"   summarise these sample ranges separately
#   PERF_APP=...      another build;  PERF_ONSCREEN=1: opt-in on-screen run (behind other windows; rare, logged)
#   FOREGROUND=1      with PERF_ONSCREEN=1 only: a normal launch, in front of the user's windows
# OUT/top.txt is top's raw output; OUT/summary.tsv the summary (topsum.py).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mac=$(cd "$here/../.." && pwd)
out=$1 folder=$2 sock=$3 secs=$4 engine=${5:-}
shift 4; [ $# -gt 0 ] && shift
app=${PERF_APP:-"$mac/build.noindex/Taudot.app/Contents/MacOS/taudot-app"}
mkdir -p "$out"
probe="$out/probe"
[ -x "$probe" ] && [ "$probe" -nt "$here/probe.swift" ] || swiftc -O -swift-version 5 -o "$probe" "$here/probe.swift" 2>/dev/null
if [ -n "${PERF_ONSCREEN:-}" ]; then
  if [ -n "${FOREGROUND:-}" ]; then mode=; else mode=TAUDOT_ONSCREEN=1; fi
  allow=--allow-onscreen
  echo "steady.sh: ON-SCREEN run (PERF_ONSCREEN=1${FOREGROUND:+, in front})" >&2
else
  [ -z "${FOREGROUND:-}" ] || { echo "steady.sh: FOREGROUND needs PERF_ONSCREEN=1" >&2; exit 2; }
  grep -q TAUDOT_OFFSCREEN "$app" || { echo "steady.sh: $app has no TAUDOT_OFFSCREEN; refusing to put windows on the user's screen (PERF_ONSCREEN=1 to opt in)" >&2; exit 2; }
  mode=TAUDOT_OFFSCREEN=1; allow=
fi

tree() { for c in $(pgrep -P "$1"); do tree "$c"; done; echo "$1"; }
stop() {
  [ -n "$1" ] || return 0
  pids=$(tree "$1" | tr '\n' ' ')
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  sleep 1
  for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
}
pid= drive= topp=
cleanup() { [ -n "$topp" ] && kill "$topp" 2>/dev/null; stop "$drive"; stop "$pid"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

env TAUDOT_SOCKET="$sock" $mode TAUDOT_TIMELINE=1 "$@" "$app" "$folder" >"$out/app.log" 2>&1 &
pid=$!
sleep 15
if [ -n "${PROBE_SCRIPT:-}" ]; then
  "$probe" --out "$out/drive" --seconds "$secs" --pid $pid --match "$(basename "$folder")" --script "$PROBE_SCRIPT" $allow >"$out/drive.log" 2>&1 &
  drive=$!
fi
top -l $((secs + 1)) -s 1 -stats pid,ppid,command,cpu,csw,power,mem > "$out/top.txt" &
topp=$!
wait $topp || true
topp=
[ -n "$drive" ] && { wait "$drive" || true; drive=; }
root=$pid
stop "$pid"; pid=
uv run -q "$here/topsum.py" "$out/top.txt" $root "$engine" ${PHASES:-} | tee "$out/summary.tsv"
