#!/bin/sh
# The GUI bridge (lua/taudot/gui.lua) against the mock engine with its bot.
#   clients/nvim/tests/gui.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mock="$here/../../mock-engine"
tmp=$(mktemp -d)
pid=
# The mock (and anything it started) stops however the run ends: EXIT, ^C, a kill.
stop() { [ -n "$pid" ] && { for c in $(pgrep -P "$pid" 2>/dev/null); do kill "$c" 2>/dev/null; done; kill "$pid" 2>/dev/null; }; rm -rf "$tmp"; }
trap stop EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$mock/example/main.tex" "$tmp/main.tex"
# Two more docs for the jumps across files (sidebar order: appendix.tex, main.tex, sections/intro.tex).
mkdir -p "$tmp/sections"
printf 'Appendix text with nothing to say.\n' > "$tmp/appendix.tex"
printf 'An introduction with a point to discuss.\nA second line.\n' > "$tmp/sections/intro.tex"
deno run -A "$mock/main.ts" --folder "$tmp" --socket "$tmp/e.sock" --bot --bot-interval 300 --bot-char 10 --bot-rounds 3 \
  > "$tmp/mock.log" 2>&1 &
pid=$!
i=0
while [ ! -S "$tmp/e.sock" ]; do
  i=$((i + 1)); [ $i -gt 100 ] && { cat "$tmp/mock.log"; exit 1; }
  sleep 0.05
done
status=0
TAUDOT_SOCKET="$tmp/e.sock" TAUDOT_FOLDER="$tmp" nvim --headless --clean -l "$here/gui_spec.lua" || status=$?
if [ $status -ne 0 ]; then echo "--- mock log (tail)"; tail -20 "$tmp/mock.log"; fi
exit $status
