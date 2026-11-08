#!/usr/bin/env bash
# Start the local Overleaf CE, wait until it answers, and create the test users.
# Credentials go to docker/.env.test (gitignored). Safe to run again.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
env_file="$here/.env.test"
port="${OVERLEAF_PORT:-8800}"
url="http://localhost:$port"
container=texsync-sharelatex

# Persistent secrets, kept across restarts. Compose reads docker/.env for variable substitution.
if ! grep -q "^OVERLEAF_INVITE_TOKEN_SECRET=" "$here/.env" 2>/dev/null; then
  (umask 077; echo "OVERLEAF_INVITE_TOKEN_SECRET=$(openssl rand -hex 32)" >> "$here/.env")
fi

docker compose -f "$here/compose.yml" up -d

echo "waiting for $url to answer (first start under amd64 emulation takes a few minutes)..."
deadline=$((SECONDS + 600))
until [ "$(curl -s -o /dev/null -w '%{http_code}' "$url/login" || true)" = 200 ]; do
  if [ $SECONDS -gt $deadline ]; then
    echo "Overleaf did not answer within 10 minutes. Logs: docker logs $container" >&2
    exit 1
  fi
  restarts=$(docker inspect -f "{{.RestartCount}}" "$container" 2>/dev/null || echo 0)
  if [ "$restarts" -ge 2 ]; then
    echo "$container is restarting in a loop. Last log lines:" >&2
    docker logs --tail 30 "$container" >&2
    exit 1
  fi
  sleep 3
done
echo "Overleaf is up at $url"

# Reuse passwords from an earlier run so other agents' copies stay valid.
if [ -f "$env_file" ]; then
  # shellcheck disable=SC1090
  source "$env_file"
fi
pw() { openssl rand -hex 12; }
OVERLEAF_ADMIN_EMAIL="${OVERLEAF_ADMIN_EMAIL:-admin@texsync.test}"
OVERLEAF_ADMIN_PASSWORD="${OVERLEAF_ADMIN_PASSWORD:-$(pw)}"
OVERLEAF_USER1_EMAIL="${OVERLEAF_USER1_EMAIL:-alice@texsync.test}"
OVERLEAF_USER1_PASSWORD="${OVERLEAF_USER1_PASSWORD:-$(pw)}"
OVERLEAF_USER2_EMAIL="${OVERLEAF_USER2_EMAIL:-bob@texsync.test}"
OVERLEAF_USER2_PASSWORD="${OVERLEAF_USER2_PASSWORD:-$(pw)}"

users_json=$(cat <<JSON
[
  {"email": "$OVERLEAF_ADMIN_EMAIL", "password": "$OVERLEAF_ADMIN_PASSWORD", "firstName": "Admin", "admin": true},
  {"email": "$OVERLEAF_USER1_EMAIL", "password": "$OVERLEAF_USER1_PASSWORD", "firstName": "Alice", "admin": false},
  {"email": "$OVERLEAF_USER2_EMAIL", "password": "$OVERLEAF_USER2_PASSWORD", "firstName": "Bob", "admin": false}
]
JSON
)

script_dir=/overleaf/services/web/modules/server-ce-scripts/scripts
docker cp "$here/create-users.mjs" "$container:$script_dir/texsync-create-users.mjs" >/dev/null
output=$(echo "$users_json" | docker exec -i -w /overleaf/services/web "$container" \
  /sbin/setuser www-data node "$script_dir/texsync-create-users.mjs" 2>&1) || true
result=$(echo "$output" | sed -n "s/^TAUDOT_RESULT //p")
if [ -z "$result" ]; then
  echo "creating users failed:" >&2
  echo "$output" | grep -v "^{" | tail -20 >&2
  exit 1
fi
id_of() { echo "$result" | jq -r --arg e "$1" '.[] | select(.email == $e) | .id'; }

projects=$(grep "^OVERLEAF_PROJECT_" "$env_file" 2>/dev/null || true)
umask 077
cat > "$env_file" <<ENV
# Written by docker/up.sh. Local test Overleaf only. Do not commit.
OVERLEAF_URL=$url
OVERLEAF_ADMIN_EMAIL=$OVERLEAF_ADMIN_EMAIL
OVERLEAF_ADMIN_PASSWORD=$OVERLEAF_ADMIN_PASSWORD
OVERLEAF_ADMIN_ID=$(id_of "$OVERLEAF_ADMIN_EMAIL")
OVERLEAF_USER1_EMAIL=$OVERLEAF_USER1_EMAIL
OVERLEAF_USER1_PASSWORD=$OVERLEAF_USER1_PASSWORD
OVERLEAF_USER1_ID=$(id_of "$OVERLEAF_USER1_EMAIL")
OVERLEAF_USER2_EMAIL=$OVERLEAF_USER2_EMAIL
OVERLEAF_USER2_PASSWORD=$OVERLEAF_USER2_PASSWORD
OVERLEAF_USER2_ID=$(id_of "$OVERLEAF_USER2_EMAIL")
ENV
[ -n "$projects" ] && echo "$projects" >> "$env_file"
echo "users ready, credentials in $env_file"
# Comment threads on CE (harness/ce-threads: CE leaves the thread routes out). Re-run after the container is recreated.
sh "$(dirname "$0")/../harness/ce-threads/install.sh" || echo "note: ce-threads install failed; comment threads on CE will not work"
