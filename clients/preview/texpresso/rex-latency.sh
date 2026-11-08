#!/bin/sh
# Keystroke → pixels in a Rex pane, for one preview configuration:
#   rex-latency.sh CLIENT CONFIG DOC_DIR AT LINE N RESULTS
# CONFIG: tectonic (file saves → tectonic), txp-file (file saves → TeXpresso), txp-live (engine edits → TeXpresso).
# Copies DOC_DIR, serves it with the mock engine, runs the preview in a "txp-bench" session, scrolls it to LINE of
# main.tex (forward search), brings the session to the front of the Rex app CLIENT for the run (bench/latency.ts types
# N keystrokes through the engine), then goes back to the session the user was on and cleans up.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
pv="$here/.."
client=$1 config=$2 doc=$3 at=$4 line=$5 n=$6 results=$7
work="${TMPDIR:-/tmp}/txp-rex-bench"
rm -rf "$work"; mkdir -p "$work"
cp -R "$doc" "$work/doc"
F="$work/doc"
esock="$work/engine.sock" psock="$work/pv.sock"

deno run -A "$pv/../mock-engine/main.ts" --folder "$F" --socket "$esock" >"$work/engine.log" 2>&1 &
mock=$!
trap 'kill $mock 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$esock" ] && break; sleep 0.3; done

extra=""
case $config in
  tectonic) ;;
  txp-file) extra="--engine texpresso" ;;
  txp-live) extra="--engine texpresso --taudot-socket $esock" ;;
  *) echo "unknown config $config" >&2; exit 2 ;;
esac

current() { # the session whose panes this app client resized last (the one the user is looking at)
  best="" bt=""
  for s in $(rex ls --json </dev/null | jq -r '.sessions[].session_id'); do
    for b in $(rex block ls -s "$s" --json </dev/null | jq -r '.blocks[]|select(.window_id!=null)|.block_id'); do
      t=$(rex block call -s "$s" -b "$b" size </dev/null 2>/dev/null |
        jq -r --arg c "$client" 'select(.owner==$c) | (.desired[]? | select(.client_id==$c) | .updated_at) // empty')
      if [ -n "$t" ] && { [ -z "$bt" ] || [ "$t" \> "$bt" ]; }; then best=$s bt=$t; fi
    done
  done
  echo "$best"
}
back=$(current)

for s in $(rex ls --json </dev/null | jq -r '.sessions[] | select(.label=="txp-bench") | .session_id'); do
  rex kill "$s" </dev/null >/dev/null 2>&1 || true
done
# shellcheck disable=SC2086
sid=$(rex new txp-bench -c "$F" --json -- deno run -A "$pv/preview.ts" --folder "$F" --listen "$psock" \
  --trace "$work/trace.jsonl" --out "$work/out" $extra </dev/null | jq -r .session_id)
rex -C "$client" do session.select session_id="$sid" </dev/null >/dev/null
sleep 5 # pane size, first compile, pages
printf '{"cursor":{"path":"main.tex","line":%s}}\n' "$line" | nc -U -w 1 "$psock" || true
sleep 5 # scroll there, the line mark fades (4 s)
status=0
deno run -A --unstable-ffi "$pv/bench/latency.ts" --socket "$esock" --path main.tex --at "$at" --n "$n" --gap 3000 \
  --label "rex-$config-$(basename "$doc")-l$line" --results "$results" || status=$?
[ -n "$back" ] && rex -C "$client" do session.select session_id="$back" </dev/null >/dev/null
rex kill "$sid" </dev/null >/dev/null 2>&1 || true
exit $status
