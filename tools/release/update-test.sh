#!/bin/sh
# An update from version N to N+1 with Sparkle, all local: two releases made by make.sh with a throwaway EdDSA key
# (a file, not the Keychain), the appcast served on localhost, version N run off screen with TAUDOT_UPDATE_TEST=1
# (it checks, downloads, installs at once, doesn't relaunch), then the installed bundle's version is read.
#   tools/release/update-test.sh [WORK]       (WORK outside your home; default mktemp)
# Runs with HOME and CFFIXED_USER_HOME in WORK (Sparkle's settings stay there) and TAUDOT_NO_SERVICE=1 (no agent).
set -eu
rel=$(cd "$(dirname "$0")" && pwd)
work=${1:-$(mktemp -d /private/tmp/taudot-update.XXXXXX)}
mkdir -p "$work" && work=$(cd "$work" && pwd -P)
port=${PORT:-8765}
n=${N:-0.1.0} n1=${N1:-0.1.1}
u() { uv run --no-project --quiet --with cryptography==44.0.2 python "$@"; }
[ -f "$work/test.key" ] || u "$rel/edkey.py" new "$work/test.key"
export SPARKLE_KEY_FILE="$work/test.key" TAUDOT_FEED_URL="http://127.0.0.1:$port/appcast.xml" RELEASE_DIR="$work/release"
rm -rf "$work/release/updates"
sh "$rel/make.sh" "$n" | tail -1
sh "$rel/make.sh" "$n1" | tail -1
grep -c "<item>" "$work/release/updates/appcast.xml" | sed 's/^/appcast items: /'

# version N where a user would have it
rm -rf "$work/Applications" "$work/home" && mkdir -p "$work/Applications" "$work/home"
ditto "$work/release/$n/Taudot.app" "$work/Applications/Taudot.app"

uv run --no-project python -m http.server "$port" --bind 127.0.0.1 --directory "$work/release/updates" > "$work/http.log" 2>&1 &
http=$!
trap 'kill $http 2>/dev/null' EXIT
sleep 1
env -i HOME="$work/home" CFFIXED_USER_HOME="$work/home" PATH=/usr/bin:/bin USER="$USER" TMPDIR="$work/" \
  TAUDOT_OFFSCREEN=1 TAUDOT_NO_SERVICE=1 TAUDOT_UPDATE_TEST=1 TAUDOT_NO_PREWARM=1 \
  "$work/Applications/Taudot.app/Contents/MacOS/taudot-app" > "$work/app.log" 2>&1 &
app=$!
t=0
while [ $t -lt 120 ]; do
  v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$work/Applications/Taudot.app/Contents/Info.plist" 2>/dev/null || true)
  [ "$v" = "$n1" ] && break
  sleep 1; t=$((t + 1))
done
kill $app 2>/dev/null || true
grep '^update:' "$work/app.log" || true
grep -E 'GET /' "$work/http.log" | sed 's/.*"GET /GET /; s/ HTTP.*//' | sort | uniq -c
if [ "$v" = "$n1" ]; then
  codesign --verify --deep --strict "$work/Applications/Taudot.app" && echo "update test: $n → $n1 installed in ${t} s, signature valid"
else
  echo "update test: FAIL (still $v after ${t} s; $work/app.log)"; exit 1
fi
