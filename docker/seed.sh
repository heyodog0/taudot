#!/usr/bin/env bash
# Create test projects on the local Overleaf CE, owned by user1 and shared with user2 as editor.
#
#   docker/seed.sh [--reset]
#       The two shared projects, IDs appended to the env file:
#         "texsync classic"     sharejs-text-ot (otMigrationStage unset)
#         "texsync history-ot"  history-ot      (otMigrationStage = 1)
#
#   docker/seed.sh --name NAME [--history-ot] [--from DIR] [--reset]
#       One project of your own, for an agent's tests. Prints only its ID and leaves the env file alone.
#       Found by name and reused; --reset deletes it and makes a fresh one. --from zips DIR instead of docker/seed/.
#       Name it after yourself ("engine fuzz", "preview demo") so nobody edits someone else's project.
#
# The env file is $TAUDOT_ENV_FILE (or the old $TEXSYNC_ENV_FILE), or docker/.env.test next to this script.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
env_file="${TAUDOT_ENV_FILE:-${TEXSYNC_ENV_FILE:-$here/.env.test}}"
[ -f "$env_file" ] || { echo "no $env_file: run docker/up.sh first, or set TAUDOT_ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

reset=0 name="" historyot=0 from="$here/seed"
while [ $# -gt 0 ]; do
  case "$1" in
    --reset) reset=1 ;;
    --name) name="$2"; shift ;;
    --history-ot) historyot=1 ;;
    --from) from="$(cd "$2" && pwd)"; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

mongo() { docker exec texsync-mongo mongosh sharelatex --quiet --eval "$1"; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
jar="$tmp/cookies"

# Log in as user1. The CSRF token is in a meta tag on every page.
csrf() { curl -s -b "$jar" -c "$jar" "$OVERLEAF_URL/$1" | sed -n 's/.*name="ol-csrfToken" content="\([^"]*\)".*/\1/p' | head -1; }
token=$(csrf login)
curl -sf -b "$jar" -c "$jar" -H 'Content-Type: application/json' -H "X-CSRF-Token: $token" \
  -d "{\"email\":\"$OVERLEAF_USER1_EMAIL\",\"password\":\"$OVERLEAF_USER1_PASSWORD\"}" \
  "$OVERLEAF_URL/login" >/dev/null
token=$(csrf project)
[ -n "$token" ] || { echo "login failed" >&2; exit 1; }

(cd "$from" && zip -qr "$tmp/seed.zip" .)

# Echo the ID of user1's project with this name, or nothing.
find_project() {
  mongo "const p = db.projects.findOne({name: $(jq -Rn --arg n "$1" '$n'), owner_ref: ObjectId('$OVERLEAF_USER1_ID'), deletedAt: {\$exists: false}}); if (p) print(p._id.toString())"
}

# make_project NAME HISTORYOT(0|1): echo the project's ID, creating it if needed.
make_project() {
  local name="$1" hot="$2" id
  id=$(find_project "$name")
  if [ -n "$id" ] && [ $reset = 1 ]; then
    curl -sf -b "$jar" -X DELETE -H "X-CSRF-Token: $token" "$OVERLEAF_URL/project/$id" >/dev/null
    id=""
  fi
  if [ -z "$id" ]; then
    id=$(curl -sf -b "$jar" -H "X-CSRF-Token: $token" -F "name=seed.zip" -F "qqfile=@$tmp/seed.zip" \
      "$OVERLEAF_URL/project/new/upload" | jq -r .project_id)
  fi
  [ -n "$id" ] && [ "$id" != null ] || { echo "creating $name failed" >&2; exit 1; }
  # Overleaf names a zip-uploaded project after its \title, so set the name we look it up by.
  mongo "db.projects.updateOne({_id: ObjectId('$id')}, {\$set: {name: $(jq -Rn --arg n "$name" '$n')}})" >/dev/null
  # Share with user2 as editor. Overleaf's field name is spelled this way.
  mongo "db.projects.updateOne({_id: ObjectId('$id')}, {\$addToSet: {collaberator_refs: ObjectId('$OVERLEAF_USER2_ID')}})" >/dev/null
  if [ "$hot" = 1 ]; then
    # The document updater reads overleaf.history.otMigrationStage from web each time it loads a doc from mongo,
    # and serves history-ot when it is > 0. Web only ever raises it.
    mongo "db.projects.updateOne({_id: ObjectId('$id')}, {\$max: {'overleaf.history.otMigrationStage': 1}})" >/dev/null
  fi
  # Flush and unload the project so no doc stays cached in the document updater in the old format.
  docker exec texsync-sharelatex curl -sf -X DELETE "http://127.0.0.1:3003/project/$id" >/dev/null || true
  echo "$id"
}

if [ -n "$name" ]; then
  case "$name" in "texsync classic"|"texsync history-ot") echo "pick another name, $name is the shared one" >&2; exit 2 ;; esac
  make_project "$name" "$historyot"
  exit 0
fi

classic=$(make_project "texsync classic" 0)
historyot=$(make_project "texsync history-ot" 1)

sed -i.bak '/^OVERLEAF_PROJECT_/d' "$env_file" && rm -f "$env_file.bak"
cat >> "$env_file" <<ENV
OVERLEAF_PROJECT_CLASSIC_ID=$classic
OVERLEAF_PROJECT_HISTORYOT_ID=$historyot
ENV
echo "classic (sharejs-text-ot): $OVERLEAF_URL/project/$classic"
echo "history-ot:                $OVERLEAF_URL/project/$historyot"
