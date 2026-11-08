#!/bin/sh
# Rebuild only taudot-app (release) into an existing bundle (bundle.sh made it), for quick measured iterations.
#   clients/mac/Tests/perf/quickbuild.sh [BUNDLE]   (default clients/mac/build.noindex/Taudot.app)
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
app=${1:-"$here/build.noindex/Taudot.app"}
[ -d "$app" ] || { echo "quickbuild.sh: no $app; run clients/mac/bundle.sh first" >&2; exit 2; }
cd "$here"
swift build -c release --product taudot-app 2>&1 | grep -E "error|warning: unre|Compiling|Build" | grep -v "^\[" || true
cp "$(swift build -c release --show-bin-path)/taudot-app" "$app/Contents/MacOS/taudot-app"
codesign -f -s - "$app/Contents/MacOS/taudot-app" 2>/dev/null
