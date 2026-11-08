#!/bin/sh
# Headless end-to-end test: the mock engine with a fast bot and some latency, Neovim driven by tests/e2e.lua.
#   clients/nvim/tests/run.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mock="$here/../../mock-engine"
tmp=$(mktemp -d)
trap 'kill $pid 2>/dev/null || true; rm -rf "$tmp"' EXIT
cp "$mock/example/main.tex" "$tmp/main.tex"
printf 'plain\n' > "$tmp/notes.txt"
deno run -A "$mock/main.ts" --folder "$tmp" --socket "$tmp/e.sock" --bot --bot-interval 400 --bot-char 15 \
  --latency "${LATENCY:-120}" > "$tmp/mock.log" 2>&1 &
pid=$!
i=0
while [ ! -S "$tmp/e.sock" ]; do
  i=$((i + 1)); [ $i -gt 100 ] && { cat "$tmp/mock.log"; exit 1; }
  sleep 0.05
done
nvim --headless --clean -l "$here/preview_spec.lua"
nvim --headless --clean -l "$here/comforts_spec.lua"
nvim --headless --clean -l "$here/rename_spec.lua"
nvim --headless --clean -l "$here/connect_spec.lua"
nvim --headless --clean -l "$here/ot_spec.lua"
nvim --headless --clean -l "$here/ot_fixtures_spec.lua"
nvim --headless --clean -l "$here/pdffeed_spec.lua"

status=0
TAUDOT_SOCKET="$tmp/e.sock" TAUDOT_FOLDER="$tmp" MOCK_LOG="$tmp/mock.log" \
  nvim --headless --clean -l "$here/e2e.lua" || status=$?
if [ $status -eq 0 ]; then
  echo "--- review UI"
  TAUDOT_SOCKET="$tmp/e.sock" TAUDOT_FOLDER="$tmp" \
    nvim --headless --clean -l "$here/review_ui.lua" || status=$?
fi
lazy="$HOME/.local/share/nvim/lazy"
if [ $status -eq 0 ] && [ -d "$lazy/telescope.nvim" ] && [ -d "$lazy/plenary.nvim" ]; then
  echo "--- Telescope"
  TAUDOT_SOCKET="$tmp/e.sock" TAUDOT_FOLDER="$tmp" TELESCOPE_DIR="$lazy/telescope.nvim" PLENARY_DIR="$lazy/plenary.nvim" \
    nvim --headless --clean -l "$here/telescope_spec.lua" || status=$?
fi
if [ $status -eq 0 ]; then
  echo "--- engine restart"
  "$here/reconnect.sh" || status=$?
fi
if [ $status -ne 0 ]; then echo "--- mock log (tail)"; tail -20 "$tmp/mock.log"; fi
exit $status
