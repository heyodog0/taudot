#!/usr/bin/env bash
# Create a blank throwaway project on the local Overleaf CE for engine tests, owned by user1 and shared with user2 as
# editor, with main.tex holding a few lines. Prints the project ID. Never touches the seeded demo projects.
#
#   crates/engine/tests/ce/new-project.sh [--history-ot] [name]   # default name "taudot engine test <timestamp>"
#
# Reads TAUDOT_ENV_FILE, default ~/code/lab/taudot/docker/.env.test.
set -euo pipefail
env_file="${TAUDOT_ENV_FILE:-$HOME/code/lab/taudot/docker/.env.test}"
# shellcheck disable=SC1090
source "$env_file"
history_ot=0
[ "${1:-}" = "--history-ot" ] && { history_ot=1; shift; }
name="${1:-taudot engine test $(date +%s)}"
case "$OVERLEAF_URL" in *overleaf.com*) echo "refusing to run against overleaf.com" >&2; exit 1 ;; esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
jar="$tmp/cookies"
csrf() { curl -s -b "$jar" -c "$jar" "$OVERLEAF_URL/$1" | sed -n 's/.*name="ol-csrfToken" content="\([^"]*\)".*/\1/p' | head -1; }
token=$(csrf login)
curl -sf -b "$jar" -c "$jar" -H 'Content-Type: application/json' -H "X-CSRF-Token: $token" \
  -d "{\"email\":\"$OVERLEAF_USER1_EMAIL\",\"password\":\"$OVERLEAF_USER1_PASSWORD\"}" "$OVERLEAF_URL/login" >/dev/null
token=$(csrf project)
[ -n "$token" ] || { echo "login failed" >&2; exit 1; }

mkdir -p "$tmp/p"
printf '%s\n' '\documentclass{article}' '\begin{document}' 'Engine test. Grüße, 中文.' '\end{document}' > "$tmp/p/main.tex"
(cd "$tmp/p" && zip -q "$tmp/p.zip" main.tex)
id=$(curl -sf -b "$jar" -H "X-CSRF-Token: $token" -F "name=engine-test.zip" -F "qqfile=@$tmp/p.zip" \
  "$OVERLEAF_URL/project/new/upload" | jq -r .project_id)
[ -n "$id" ] && [ "$id" != null ] || { echo "creating the project failed" >&2; exit 1; }
mongo() { docker exec texsync-mongo mongosh sharelatex --quiet --eval "$1"; }
mongo "db.projects.updateOne({_id: ObjectId('$id')}, {\$set: {name: '$name'}})" >/dev/null
# Overleaf's field name is spelled this way.
mongo "db.projects.updateOne({_id: ObjectId('$id')}, {\$addToSet: {collaberator_refs: ObjectId('$OVERLEAF_USER2_ID')}})" >/dev/null
if [ $history_ot = 1 ]; then
  # As docker/seed.sh does: the document updater serves history-ot when otMigrationStage > 0; unload the project so no
  # doc stays cached in the old format.
  mongo "db.projects.updateOne({_id: ObjectId('$id')}, {\$max: {'overleaf.history.otMigrationStage': 1}})" >/dev/null
  docker exec texsync-sharelatex curl -sf -X DELETE "http://127.0.0.1:3003/project/$id" >/dev/null || true
fi
echo "$id"
