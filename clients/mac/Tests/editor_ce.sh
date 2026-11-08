#!/bin/sh
# The native editor end to end on the local Overleaf CE: the real engine as Alice (user1), EditorHost on its mirror
# folder (native editor + review margin + PDF pane, wired as the app wires them), and Bob (user2) in Overleaf's own
# editor (clients/nvim/tests/ce_bob.ts). A project of its own, made fresh each run.
#   clients/mac/Tests/editor_ce.sh [shot.png]     (CE up: docker/up.sh; harness: npm ci in harness/)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
env_file=${TAUDOT_ENV_FILE:-$HOME/code/lab/taudot/docker/.env.test}
export TAUDOT_ENV_FILE="$env_file"
shot=${1:-}

(cd "$repo" && cargo build -q -p taudot-engine)
(cd "$repo/clients/mac" && swift build -q --product EditorHost)
# TAUDOT_CE_HISTORY_OT=1: the same on a history-ot project. EditorHost runs off screen, in the background.
hot=${TAUDOT_CE_HISTORY_OT:+--history-ot}
pid_project=$("$repo/docker/seed.sh" --name "editor native${hot:+ hot}" --reset $hot)
tmp=$(mktemp -d)
# The engine's pid lives in a file: the restart step (11) kills it and starts a new one, which writes its own.
. "$here/stop_all.sh"
stop_all_setup "$tmp" "$tmp/engine.pid"
mkdir -p "$tmp/home" "$tmp/proj"
printf '{"project": "%s"}\n' "$pid_project" > "$tmp/proj/.taudot.json"
url=$(sed -n 's/^OVERLEAF_URL=//p' "$env_file")
engine_cmd="TAUDOT_FLUSH_MS=200 '$repo/target/debug/taudot' serve --url '$url' --env-file '$env_file' --user user1 --home '$tmp/home' >> '$tmp/engine.log' 2>&1 & echo \$! > '$tmp/engine.pid'"
sh -c "$engine_cmd"
i=0
while [ ! -S "$tmp/home/engine.sock" ]; do
  i=$((i + 1)); [ $i -gt 200 ] && { cat "$tmp/engine.log"; exit 1; }
  sleep 0.05
done

# The PDF pane's driver: this checkout's txp-render (glyphs: the cursor dot), else the main clone's, else txp-headless.
main=$HOME/code/lab/taudot/clients
if [ -z "${TAUDOT_TXP:-}" ] && [ ! -x "$repo/clients/render/txp-render" ]; then
  if [ -x "$main/render/txp-render" ]; then export TAUDOT_TXP="$main/render/txp-render"
  elif [ ! -x "$repo/clients/preview/texpresso/txp-headless" ] && [ -x "$main/preview/texpresso/txp-headless" ]; then
    export TAUDOT_TXP="$main/preview/texpresso/txp-headless"
  fi
fi
status=0
"$repo/clients/mac/.build/debug/EditorHost" "$tmp/proj" --socket "$tmp/home/engine.sock" --main main.tex \
  --check "$tmp/check.json" --bob "node $repo/clients/nvim/tests/ce_bob.ts" --bob-cwd "$repo/harness" \
  --project "$pid_project" --engine-pidfile "$tmp/engine.pid" --engine-cmd "$engine_cmd" ${shot:+--shot "$shot"} || status=$?
cat "$tmp/check.json" 2>/dev/null | grep -E '"(name|ok|detail)"' | paste - - - | sed 's/  */ /g' || true
if [ $status -ne 0 ]; then echo "--- engine log (tail)"; tail -20 "$tmp/engine.log"; fi
exit $status
