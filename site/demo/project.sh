#!/usr/bin/env bash
# A fresh project on the local Overleaf CE holding the made-up sample paper (site/demo/paper), owned by Alice (user1),
# shared with Bob (user2) as editor. Prints its id. Local CE only: refuses anything else.
#   site/demo/project.sh [name]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
env_file="${TAUDOT_ENV_FILE:-$HOME/code/lab/taudot/docker/.env.test}"
# shellcheck disable=SC1090
source "$env_file"
name="${1:-Tea demo $(date +%H%M%S)}"
case "$OVERLEAF_URL" in http://localhost:*|http://127.0.0.1:*) ;; *) echo "refusing: $OVERLEAF_URL is not a local CE" >&2; exit 1 ;; esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
jar="$tmp/cookies"
csrf() { curl -s -b "$jar" -c "$jar" "$OVERLEAF_URL/$1" | sed -n 's/.*name="ol-csrfToken" content="\([^"]*\)".*/\1/p' | head -1; }
token=$(csrf login)
curl -sf -b "$jar" -c "$jar" -H 'Content-Type: application/json' -H "X-CSRF-Token: $token" \
  -d "{\"email\":\"$OVERLEAF_USER1_EMAIL\",\"password\":\"$OVERLEAF_USER1_PASSWORD\"}" "$OVERLEAF_URL/login" >/dev/null
token=$(csrf project)
[ -n "$token" ] || { echo "login failed" >&2; exit 1; }
(cd "$here/paper" && zip -q "$tmp/p.zip" main.tex)
id=$(curl -sf -b "$jar" -H "X-CSRF-Token: $token" -F "name=tea.zip" -F "qqfile=@$tmp/p.zip" "$OVERLEAF_URL/project/new/upload" | jq -r .project_id)
[ -n "$id" ] && [ "$id" != null ] || { echo "creating the project failed" >&2; exit 1; }
mongo() { docker exec texsync-mongo mongosh sharelatex --quiet --eval "$1"; }
mongo "db.projects.updateOne({_id: ObjectId('$id')}, {\$set: {name: '$name'}})" >/dev/null
mongo "db.projects.updateOne({_id: ObjectId('$id')}, {\$addToSet: {collaberator_refs: ObjectId('$OVERLEAF_USER2_ID')}})" >/dev/null
echo "$id"
