#!/bin/sh
# The engine restarts while Neovim types (docs/agents/editor-reconnect.md): the mock engine is killed with an edit in
# flight and one pending, a collaborator's edit lands while it's down (the file changes, as Overleaf would), more is
# typed, and a new engine starts on the same socket. Nothing may be lost or doubled. Also the rebase unit cases.
#   clients/nvim/tests/reconnect.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
. "$here/../../mac/Tests/stop_all.sh"
stop_all_setup "$tmp"  # (the mock engines are Neovim's children)
cp "$here/../../mock-engine/example/main.tex" "$tmp/main.tex"
MOCK_MAIN="$here/../../mock-engine/main.ts" TAUDOT_FOLDER="$tmp" TAUDOT_SOCKET="$tmp/e.sock" \
  nvim --headless --clean -l "$here/reconnect.lua"
