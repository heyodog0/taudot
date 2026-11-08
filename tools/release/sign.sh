#!/bin/sh
# Signs Taudot.app from the inside out: every Mach-O file outside the frameworks, then the frameworks (Sparkle's
# helpers first), then the app.
#   tools/release/sign.sh Taudot.app [IDENTITY]
# IDENTITY "-" (default) is an ad-hoc signature: enough to run on Apple silicon, and testers open the app with
# right-click ▸ Open the first time. A "Developer ID Application: …" identity adds the hardened runtime, a secure
# timestamp and tools/release/entitlements.plist, which notarization needs (tools/release/notarize.sh).
set -eu
app=$1
id=${2:--}
here=$(cd "$(dirname "$0")" && pwd)
if [ "$id" = - ]; then
  opts="--force --sign -"
else
  opts="--force --sign $id --options runtime --timestamp --entitlements $here/entitlements.plist"
fi
n=0
# Executables and libraries outside the .framework folders (Resources/…, MacOS/taudot, Frameworks/*.dylib).
find "$app/Contents" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -not -path '*.framework/*' -print0 \
  | xargs -0 file | grep 'Mach-O' | sed 's/ (for architecture.*//; s/:.*//' | sort -u | grep -v "/Contents/MacOS/taudot-app$" > "${TMPDIR:-/tmp}/taudot-sign.$$" || true
while IFS= read -r f; do
  # shellcheck disable=SC2086
  codesign $opts "$f" 2>&1 | grep -v 'replacing existing signature' || true
  n=$((n + 1))
done < "${TMPDIR:-/tmp}/taudot-sign.$$"
rm -f "${TMPDIR:-/tmp}/taudot-sign.$$"
# Sparkle: its XPC services, Autoupdate and Updater.app, then the framework (Sparkle's documented order).
sp="$app/Contents/Frameworks/Sparkle.framework"
if [ -d "$sp" ]; then
  for x in "$sp"/Versions/B/XPCServices/*.xpc "$sp/Versions/B/Autoupdate" "$sp/Versions/B/Updater.app" "$sp"; do
    [ -e "$x" ] || continue
    # shellcheck disable=SC2086
    codesign $opts "$x" 2>&1 | grep -v 'replacing existing signature' || true
  done
fi
# shellcheck disable=SC2086
codesign $opts "$app" 2>&1 | grep -v 'replacing existing signature' || true
codesign --verify --deep --strict "$app"
echo "signed $n inner files and the app ($( [ "$id" = - ] && echo ad-hoc || echo "$id"))"
