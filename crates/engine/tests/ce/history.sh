#!/usr/bin/env bash
# history.* against the local Overleaf CE: a new throwaway project, an edit by alice (user1) then one by bob (user2)
# through Overleaf's own browser editor (harness/type.ts), then the engine (as alice) must list both authors in one
# version group and give a diff with bob's insert before alice's, each under its author, plus a label and a rename.
#
#   crates/engine/tests/ce/history.sh [--history-ot]
#
# Needs CE up (docker/up.sh), `npm install` in harness/, and `cargo build -p taudot-engine`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
export TAUDOT_ENV_FILE="${TAUDOT_ENV_FILE:-$HOME/code/lab/taudot/docker/.env.test}"
# shellcheck disable=SC1090
source "$TAUDOT_ENV_FILE"
case "$OVERLEAF_URL" in *overleaf.com*) echo "refusing to run against overleaf.com" >&2; exit 1 ;; esac

pid=$("$here/new-project.sh" ${1:-} "taudot history test $(date +%s)")
echo "project $pid"
type() { node "$root/harness/type.ts" --project "$pid" --file main.tex "$@" --json >/dev/null; }
type --user 1 --pos 0 --text $'% alice\n'
type --user 2 --pos 0 --text $'% bob\n'

home=$(mktemp -d /tmp/tdh.XXXX)
taudot="$root/target/debug/taudot"
"$taudot" serve --env-file "$TAUDOT_ENV_FILE" --user user1 --home "$home" >"$home/serve.log" 2>&1 &
engine=$!
trap 'kill $engine 2>/dev/null; rm -rf "$home"' EXIT
rpc() { "$taudot" rpc --home "$home" "$@"; }
for _ in $(seq 50); do [ -S "$home/engine.sock" ] && break; sleep 0.1; done
rpc project.open "{\"project_id\":\"$pid\"}" >/dev/null

fail=0
check() { # check NAME JQ-EXPR JSON
  if echo "$3" | jq -e "$2" >/dev/null; then echo "ok   $1"; else echo "FAIL $1"; echo "$3" | jq -c . | head -c 600; echo; fail=1; fi
}

# Overleaf flushes history in the background; wait until both edits are in.
for _ in $(seq 30); do
  u=$(rpc history.updates "{\"project_id\":\"$pid\",\"min_count\":10}")
  echo "$u" | jq -e '[.updates[].users[].name] | index("Bob")' >/dev/null && break
  sleep 1
done
check "newest group has bob and alice" '.updates[0].users | map(.name) | (index("Bob") != null and index("Alice") != null)' "$u"
check "alice is mine, bob is not" '.updates[0].users | (map(select(.name=="Alice"))[0].mine and (map(select(.name=="Bob"))[0].mine | not))' "$u"
check "group lists main.tex" '.updates[0].paths == ["main.tex"]' "$u"
check "head is newest to_v" '.head == .updates[0].to_v' "$u"
check "first version adds main.tex" '.updates[-1].ops | map(select(.op=="add")) | map(.path) | index("main.tex") != null' "$u"
to=$(echo "$u" | jq .updates[0].to_v)
from=$(echo "$u" | jq .updates[0].from_v)

d=$(rpc history.diff "{\"project_id\":\"$pid\",\"path\":\"main.tex\",\"from\":$from,\"to\":$to}")
check "diff text starts with both lines" '.text | startswith("% bob\n% alice\n")' "$d"
check "bob's insert first, then alice's" '[.chunks[] | select(.kind=="insert") | [.start, .end, .user.name]] == [[0,6,"Bob"],[6,14,"Alice"]]' "$d"
check "inserted count" '.inserted == 14 and .deleted == 0' "$d"

t=$(rpc history.tree "{\"project_id\":\"$pid\",\"from\":$from,\"to\":$to}")
check "tree marks main.tex edited" '.files | map(select(.path=="main.tex"))[0].op == "edited"' "$t"

f=$(rpc history.file "{\"project_id\":\"$pid\",\"path\":\"main.tex\",\"version\":$from}")
check "file at from has neither line" '.text | startswith("\\documentclass")' "$f"

# A label (CE only: never write history on overleaf.com) shows on its version's group and in history.labels.
jar="$home/jar"
csrf() { curl -s -b "$jar" -c "$jar" "$OVERLEAF_URL/$1" | sed -n 's/.*name="ol-csrfToken" content="\([^"]*\)".*/\1/p' | head -1; }
token=$(csrf login)
curl -sf -b "$jar" -c "$jar" -H 'Content-Type: application/json' -H "X-CSRF-Token: $token" \
  -d "{\"email\":\"$OVERLEAF_USER2_EMAIL\",\"password\":\"$OVERLEAF_USER2_PASSWORD\"}" "$OVERLEAF_URL/login" >/dev/null
token=$(csrf project)
curl -sf -b "$jar" -H 'Content-Type: application/json' -H "X-CSRF-Token: $token" \
  -d "{\"comment\":\"checkpoint\",\"version\":$to}" "$OVERLEAF_URL/project/$pid/labels" >/dev/null
l=$(rpc history.labels "{\"project_id\":\"$pid\"}")
check "label listed" ".labels | map(select(.comment==\"checkpoint\" and .version==$to and .name==\"Bob\" and (.mine|not))) | length == 1" "$l"
u=$(rpc history.updates "{\"project_id\":\"$pid\",\"min_count\":10}")
check "label on its group" '.updates[0].labels | map(.comment) == ["checkpoint"]' "$u"

exit $fail
