#!/bin/sh
# Brings SESSION to the front of the Rex app, runs COMMAND, then returns to the session the user was on.
#   rex-show.sh CLIENT SESSION COMMAND...
set -u
client=$1 target=$2; shift 2
back=""
bt=""
for s in $(rex ls --json </dev/null | jq -r '.sessions[].session_id'); do
  [ "$s" = "$target" ] && continue
  for b in $(rex block ls -s "$s" --json </dev/null | jq -r '.blocks[]|select(.window_id!=null)|.block_id'); do
    t=$(rex block call -s "$s" -b "$b" size </dev/null 2>/dev/null |
      jq -r --arg c "$client" 'select(.owner==$c) | (.desired[]? | select(.client_id==$c) | .updated_at) // empty')
    if [ -n "$t" ] && { [ -z "$bt" ] || [ "$t" \> "$bt" ]; }; then back=$s bt=$t; fi
  done
done
rex -C "$client" do session.select session_id="$target" </dev/null >/dev/null
sleep 1.5
"$@"
status=$?
[ -n "$back" ] && rex -C "$client" do session.select session_id="$back" </dev/null >/dev/null
exit $status
