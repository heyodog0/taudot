#!/bin/sh
# The engine restarts while Neovim types, on the local Overleaf CE (docs/agents/editor-reconnect.md): killed (-9, then
# a clean SIGINT) with edits in flight and pending, Bob types in Overleaf meanwhile, Neovim types more; the engine
# comes back on the same home. Overleaf must end with everything, once, and equal to Neovim's buffer.
#   clients/nvim/tests/ce_reconnect.sh [--history-ot]   (CE up: docker/up.sh; harness: npm install in harness/)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
env_file=${TAUDOT_ENV_FILE:-$HOME/code/lab/taudot/docker/.env.test}
export TAUDOT_ENV_FILE="$env_file"
(cd "$repo" && cargo build -q -p taudot-engine)
# --history-ot: the same on a history-ot project.
hot=
[ "${1:-}" = "--history-ot" ] && hot=--history-ot
pid_project=$("$repo/docker/seed.sh" --name "reconnect nvim ce${hot:+ hot}" --reset $hot)
tmp=$(mktemp -d)
. "$repo/clients/mac/Tests/stop_all.sh"
stop_all_setup "$tmp" "$tmp/engine.pid"
mkdir -p "$tmp/home" "$tmp/proj"
printf '{"project": "%s"}\n' "$pid_project" > "$tmp/proj/.taudot.json"
status=0
TAUDOT_ENGINE="$repo/target/debug/taudot" TAUDOT_URL=$(sed -n 's/^OVERLEAF_URL=//p' "$env_file") \
  TAUDOT_HOME="$tmp/home" TAUDOT_SOCKET="$tmp/home/engine.sock" TAUDOT_FOLDER="$tmp/proj" TAUDOT_PROJECT="$pid_project" \
  TAUDOT_BOB="node $here/ce_bob.ts" nvim --headless --clean -l "$here/ce_reconnect.lua" || status=$?
if [ $status -ne 0 ]; then echo "--- engine logs (tail)"; tail -15 "$tmp"/home/engine*.log 2>/dev/null || true; fi
exit $status
