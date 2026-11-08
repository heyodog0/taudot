#!/bin/sh
# FloatCheck (uifix_float.sh) on the local Overleaf CE with the real engine as Alice (user1), on a project of its own
# ("uifix float", fresh each run): once making the comments, once opening it again with them there. Off screen, no keys.   clients/mac/Tests/uifix_float_ce.sh native|neovim [SHOT.png]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
MAC="$repo/clients/mac"
export TAUDOT_ENV_FILE=${TAUDOT_ENV_FILE:-$HOME/code/lab/taudot/docker/.env.test}; env_file=$TAUDOT_ENV_FILE
(cd "$repo" && cargo build -q -p taudot-engine)
pid_project=$("$repo/docker/seed.sh" --name "uifix float" --reset)
. "$here/shell_lib.sh"
tmp=$(mktemp -d)
on_exit 'rm -rf "$tmp"'
mkdir -p "$tmp/home" "$tmp/proj"
printf '{"project": "%s"}\n' "$pid_project" > "$tmp/proj/.taudot.json"
url=$(sed -n 's/^OVERLEAF_URL=//p' "$env_file")
TAUDOT_FLUSH_MS=200 "$repo/target/debug/taudot" serve --url "$url" --env-file "$env_file" --user user1 --home "$tmp/home" >"$tmp/engine.log" 2>&1 &
started $!
i=0; while [ ! -S "$tmp/home/engine.sock" ] && [ $i -lt 200 ]; do i=$((i+1)); sleep 0.05; done
run() {  # existing shot
  rm -f "$tmp/out.txt"
  env TAUDOT_SOCKET="$tmp/home/engine.sock" TAUDOT_NO_PDF=1 TAUDOT_COMMENTS=hidden TAUDOT_EDITOR_MODE=$MODE TAUDOT_FLOATCHECK="$tmp/out.txt" \
    ${1:+TAUDOT_FLOATCHECK_EXISTING=1} ${2:+TAUDOT_FLOATCHECK_SHOT=$2} TAUDOT_OFFSCREEN=1 "$APP_BIN" "$tmp/proj" >"$tmp/app.log" 2>&1 &
  APP=$!; started $APP
  i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 600 ]; do i=$((i+1)); sleep 0.1; done
  cat "$tmp/out.txt" 2>/dev/null || { echo "FAIL no output"; tail -30 "$tmp/app.log"; tail -10 "$tmp/engine.log"; exit 1; }
  ! grep -q FAIL "$tmp/out.txt" || status=1
}
MODE=$1; status=0
echo "-- comments made in this run"; run "" "${2:-}"
echo "-- comments there when the project opens"; run 1 ""
exit $status
