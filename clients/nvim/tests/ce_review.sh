#!/bin/sh
# Review features end to end on the local Overleaf CE: the real engine as Alice, Neovim headless on its mirror
# folder, and Bob in Overleaf's own editor (tests/ce_bob.ts). Uses a project of its own, made fresh each run.
#   clients/nvim/tests/ce_review.sh            (CE up: docker/up.sh; harness: npm install in harness/)
# TAUDOT_ENV_FILE overrides the CE credentials file (default ~/code/lab/taudot/docker/.env.test).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
env_file=${TAUDOT_ENV_FILE:-$HOME/code/lab/taudot/docker/.env.test}
export TAUDOT_ENV_FILE="$env_file"

(cd "$repo" && cargo build -q -p taudot-engine)
# --history-ot: the same on a history-ot project.
hot=
[ "${1:-}" = "--history-ot" ] && hot=--history-ot
pid_project=$("$repo/docker/seed.sh" --name "review nvim ce${hot:+ hot}" --reset $hot)
tmp=$(mktemp -d)
eng_pid=
trap '[ -n "$eng_pid" ] && kill -INT $eng_pid 2>/dev/null; sleep 0.3; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/proj"
printf '{"project": "%s"}\n' "$pid_project" > "$tmp/proj/.taudot.json"
url=$(sed -n 's/^OVERLEAF_URL=//p' "$env_file")
"$repo/target/debug/taudot" serve --url "$url" --env-file "$env_file" --user user1 --home "$tmp/home" \
  > "$tmp/engine.log" 2>&1 &
eng_pid=$!
i=0
while [ ! -S "$tmp/home/engine.sock" ]; do
  i=$((i + 1)); [ $i -gt 200 ] && { cat "$tmp/engine.log"; exit 1; }
  sleep 0.05
done

status=0
TAUDOT_HISTORY_OT=${hot:+1} TAUDOT_SOCKET="$tmp/home/engine.sock" TAUDOT_FOLDER="$tmp/proj" TAUDOT_PROJECT="$pid_project" \
  TAUDOT_BOB="node $here/ce_bob.ts" nvim --headless --clean -l "$here/ce_review.lua" || status=$?
if [ $status -ne 0 ]; then echo "--- engine log (tail)"; tail -20 "$tmp/engine.log"; fi
exit $status
