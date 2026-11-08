#!/bin/sh
# Runs one bench in Rex: brings SESSION to the front of the app, runs bench.ts with the remaining arguments, then
# returns to the session the user was on (the one whose panes the app resized most recently).
#   rex-run.sh CLIENT SESSION bench.ts-args...
set -eu
here=$(cd "$(dirname "$0")" && pwd)
client=$1 bench=$2; shift 2
current() {
  best="" bt=""
  for s in $(rex ls --json </dev/null | jq -r '.sessions[].session_id'); do
    [ "$s" = "$bench" ] && continue
    for b in $(rex block ls -s "$s" --json </dev/null | jq -r '.blocks[]|select(.window_id!=null)|.block_id'); do
      t=$(rex block call -s "$s" -b "$b" size </dev/null 2>/dev/null |
        jq -r --arg c "$client" 'select(.owner==$c) | (.desired[]? | select(.client_id==$c) | .updated_at) // empty')
      if [ -n "$t" ] && { [ -z "$bt" ] || [ "$t" \> "$bt" ]; }; then best=$s bt=$t; fi
    done
  done
  echo "$best"
}
back=$(current)
rex -C "$client" do session.select session_id="$bench" </dev/null >/dev/null
sleep 2.5 # resize, re-render, tiles
status=0
deno run -A "$here/bench.ts" "$@" || status=$?
[ -n "$back" ] && rex -C "$client" do session.select session_id="$back" </dev/null >/dev/null
echo "returned to $back" >&2
exit $status
