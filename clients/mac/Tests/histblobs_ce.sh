#!/usr/bin/env bash
# Figures at a version, end to end on the local Overleaf CE: a new project whose figure is red, then replaced by a blue
# one; the engine (as alice) mirrors it (today: blue); the History PDF controller makes version 1's folder and the live
# pdfTeX typesets it; the test reads the version's PDF and checks the figure on the page is red (and its folder's
# fig.png is the red file, byte for byte). Off screen.
#
#   clients/mac/Tests/histblobs_ce.sh
#
# Needs CE up (docker/up.sh), `cargo build -p taudot-engine`, and the live pdfTeX (LiveTexPaths) built.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
export TAUDOT_ENV_FILE="${TAUDOT_ENV_FILE:-$HOME/code/lab/taudot/docker/.env.test}"
# shellcheck disable=SC1090
source "$TAUDOT_ENV_FILE"
case "$OVERLEAF_URL" in *overleaf.com*) echo "refusing to run against overleaf.com" >&2; exit 1 ;; esac

tmp=$(mktemp -d /tmp/tdhb.XXXX)
taudot="$root/target/debug/taudot"
engine=
trap '[ -n "$engine" ] && kill $engine 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$tmp"' EXIT
jar="$tmp/jar"
csrf() { curl -s -b "$jar" -c "$jar" "$OVERLEAF_URL/$1" | sed -n 's/.*name="ol-csrfToken" content="\([^"]*\)".*/\1/p' | head -1; }
token=$(csrf login)
curl -sf -b "$jar" -c "$jar" -H 'Content-Type: application/json' -H "X-CSRF-Token: $token" \
  -d "{\"email\":\"$OVERLEAF_USER1_EMAIL\",\"password\":\"$OVERLEAF_USER1_PASSWORD\"}" "$OVERLEAF_URL/login" >/dev/null
token=$(csrf project)

# 2x2 pixel PNGs, red and blue
mkdir -p "$tmp/p"
printf 'P6\n2 2\n255\n\xff\0\0\xff\0\0\xff\0\0\xff\0\0' > "$tmp/red.ppm"; sips -s format png "$tmp/red.ppm" --out "$tmp/p/fig.png" >/dev/null
printf 'P6\n2 2\n255\n\0\0\xff\0\0\xff\0\0\xff\0\0\xff' > "$tmp/blue.ppm"; sips -s format png "$tmp/blue.ppm" --out "$tmp/blue.png" >/dev/null
cp "$tmp/p/fig.png" "$tmp/red.png"
printf '%s\n' '\documentclass{article}' '\usepackage{graphicx}' '\begin{document}' \
  '\noindent\includegraphics[width=\linewidth,height=8cm]{fig.png}' '\end{document}' > "$tmp/p/main.tex"
(cd "$tmp/p" && zip -q "$tmp/p.zip" main.tex fig.png)
pid=$(curl -sf -b "$jar" -H "X-CSRF-Token: $token" -F "name=histblobs.zip" -F "qqfile=@$tmp/p.zip" \
  "$OVERLEAF_URL/project/new/upload" | jq -r .project_id)
docker exec texsync-mongo mongosh sharelatex --quiet \
  --eval "db.projects.updateOne({_id: ObjectId('$pid')}, {\$set: {name: 'taudot histblobs test $(date +%s)'}})" >/dev/null
folder_id=$(docker exec texsync-mongo mongosh sharelatex --quiet --eval "db.projects.findOne({_id: ObjectId('$pid')}).rootFolder[0]._id.toString()")
sleep 2
curl -sf -b "$jar" -H "X-CSRF-Token: $token" -F "name=fig.png" -F "qqfile=@$tmp/blue.png;filename=fig.png" \
  "$OVERLEAF_URL/Project/$pid/upload?folder_id=$folder_id" >/dev/null
echo "project $pid"

home="$tmp/home"; mkdir -p "$home"
export TAUDOT_BLOB_CACHE="$tmp/blobs"
"$taudot" serve --env-file "$TAUDOT_ENV_FILE" --user user1 --home "$home" >"$home/serve.log" 2>&1 &
engine=$!
for _ in $(seq 50); do [ -S "$home/engine.sock" ] && break; sleep 0.1; done
"$taudot" clone "$OVERLEAF_URL/project/$pid" "$tmp/folder" --home "$home" >/dev/null
for _ in $(seq 50); do cmp -s "$tmp/folder/fig.png" "$tmp/blue.png" && break; sleep 0.2; done
cmp "$tmp/folder/fig.png" "$tmp/blue.png" || { echo "FAIL the folder's figure isn't today's (blue)"; exit 1; }
# Overleaf flushes history in the background: wait for the replacement to be in it.
for _ in $(seq 30); do
  n=$("$taudot" rpc --home "$home" history.updates "{\"project_id\":\"$pid\",\"min_count\":10}" | jq '.updates | length')
  [ "$n" -ge 2 ] && break; sleep 1
done

cd "$root/clients/mac"
TAUDOT_CE_HISTBLOBS="$home/engine.sock|$tmp/folder|$tmp/red.png" TAUDOT_HISTORY_CACHE="$tmp/versions" \
  swift test --filter ceVersionPDFHasTheOldFigure 2>&1 | grep -E "✔|✘|error:|Expectation|page red" | grep -v "Test run started"
