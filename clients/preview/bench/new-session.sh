#!/bin/sh
# (Re)creates the pv-bench Rex session running the preview on FOLDER with extra preview args; prints its session id.
#   new-session.sh FOLDER SOCKET TRACE [preview args...]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
folder=$1 sock=$2 trace=$3; shift 3
old=$(rex ls --json </dev/null | jq -r '.sessions[] | select(.label=="pv-bench") | .session_id')
for s in $old; do rex kill "$s" </dev/null >/dev/null 2>&1 || true; done
rm -f "$sock"
rex new pv-bench -c "$folder" --json -- deno run -A "$here/../preview.ts" --folder "$folder" --listen "$sock" \
  --trace "$trace" --out "${TMPDIR:-/tmp}/taudot-bench-out" "$@" </dev/null | jq -r .session_id
