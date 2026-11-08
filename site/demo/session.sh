#!/bin/sh
# One demo session: the real engine as Alice (user1) with its own home (never ~/.taudot), and the app (debug build,
# TAUDOT_ONSCREEN=1: on screen but behind every window, never activated) on a mirror folder of PROJECT_ID. Neovim
# listens on $W/nvim.sock so a script can type into it. Everything it starts stops when it ends (review_lib.sh).
#   site/demo/session.sh PROJECT_ID WORKDIR
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
main=$HOME/code/lab/taudot
. "$repo/clients/mac/Tests/review_lib.sh"
id=$1 W=$2
env_file=${TAUDOT_ENV_FILE:-$main/docker/.env.test}
url=$(sed -n 's/^OVERLEAF_URL=//p' "$env_file")
case "$url" in http://localhost:*|http://127.0.0.1:*) ;; *) echo "refusing: not a local CE" >&2; exit 1 ;; esac
mkdir -p "$W/home" "$W/tea-paper"
printf '{"project": "%s"}\n' "$id" > "$W/tea-paper/.taudot.json"
NS=/tmp/taudot-demo-$$.sock
ln -sf "$NS" "$W/nvim.sock"
txs_on_exit "rm -f '$NS'"
TAUDOT_FLUSH_MS=150 "$repo/target/debug/taudot" serve --url "$url" --env-file "$env_file" --user user1 --home "$W/home" >"$W/engine.log" 2>&1 &
txs_track $!; echo $! > "$W/engine.pid"
i=0; while [ ! -S "$W/home/engine.sock" ] && [ $i -lt 200 ]; do i=$((i+1)); sleep 0.05; done
TAUDOT_EDITOR_MODE=${TAUDOT_EDITOR_MODE:-neovim} TAUDOT_ONSCREEN=1 TAUDOT_DEBUG=1 TAUDOT_SOCKET="$W/home/engine.sock" TAUDOT_TXP="${TAUDOT_TXP:-$main/clients/render/txp-render}" \
  TAUDOT_EXEC="vim.fn.serverstart('$NS')" "${TAUDOT_APP_BIN:-$repo/clients/mac/.build/debug/taudot-app}" "$W/tea-paper" >"$W/app.log" 2>&1 &
txs_track $!; echo $! > "$W/app.pid"
echo "session up: engine $(cat "$W/engine.pid"), app $(cat "$W/app.pid")"
wait
