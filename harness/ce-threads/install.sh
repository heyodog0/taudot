#!/usr/bin/env bash
# Give the local Overleaf CE (docker/compose.yml) comment-thread routes: copy this module into the container, add it
# to the web's module list and restart web. Safe to run again. Undone by recreating the container.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
c=${CONTAINER:-texsync-sharelatex}
docker exec "$c" rm -rf /overleaf/services/web/modules/taudot-threads
docker cp "$here" "$c:/overleaf/services/web/modules/taudot-threads"
docker exec "$c" rm -f /overleaf/services/web/modules/taudot-threads/install.sh
docker exec "$c" sh -c '
  f=/etc/overleaf/settings.js
  grep -q taudot-threads "$f" || sed -i "s|^module.exports = settings\$|settings.moduleImportSequence = [\"history-v1\", \"launchpad\", \"server-ce-scripts\", \"user-activate\", \"taudot-threads\"]\n&|" "$f"
  grep -q taudot-threads "$f"
  sv restart web-overleaf'
url="http://localhost:${OVERLEAF_PORT:-8800}"
sleep 2
for _ in $(seq 120); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$url/login" || true)" = 200 ] && break
  sleep 1
done
echo "web is back at $url with the taudot-threads module"
