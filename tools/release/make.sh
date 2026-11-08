#!/bin/sh
# Cut a release: tools/release/make.sh VERSION
# Builds and bundles Taudot.app (clients/mac/bundle.sh) with VERSION as its version and the update feed in Info.plist,
# signs it (ad-hoc unless SIGN_IDENTITY names a Developer ID), audits it, makes the DMG (the app and an Applications
# link), notarizes when it can (tools/release/notarize.sh), adds the DMG to the update archive folder and rewrites the
# appcast with an EdDSA signature for each update, and writes the GPL source tarball. Nothing is uploaded.
#
# Output in clients/mac/build.noindex/release/:
#   VERSION/Taudot.app, Taudot-VERSION.dmg, taudot-gpl-source-VERSION.tar.gz
#   updates/  every release's DMG and appcast.xml: upload this folder's new files to the feed's host
#
# Environment:
#   TAUDOT_FEED_URL         the appcast (default https://taudot.app/updates/appcast.xml)
#   TAUDOT_DOWNLOAD_PREFIX  where the DMGs will be (default: the feed's folder)
#   SPARKLE_ACCOUNT         the Keychain account of the EdDSA key (default app.taudot.Taudot; make it once with
#                           `generate_keys --account app.taudot.Taudot`, see docs/release.md)
#   SPARKLE_KEY_FILE        a private key file instead of the Keychain (tests only)
#   SIGN_IDENTITY           "Developer ID Application: …" (default "-": ad-hoc)
#   NOTARY_PROFILE          a notarytool Keychain profile (with SIGN_IDENTITY: notarize and staple)
#   ALLOW_AGPL=1            build even though txp-render still links MuPDF (internal test builds only)
#   RELEASE_DIR             instead of clients/mac/build.noindex/release
set -eu
[ $# = 1 ] || { echo "usage: $0 VERSION   (e.g. 0.2 or 0.2.1)" >&2; exit 2; }
version=$1
echo "$version" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}$' || { echo "make.sh: VERSION must look like 0.2 or 0.2.1" >&2; exit 2; }
rel=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$rel/../.." && pwd)
out=${RELEASE_DIR:-$repo/clients/mac/build.noindex/release}
feed=${TAUDOT_FEED_URL:-https://taudot.app/updates/appcast.xml}
prefix=${TAUDOT_DOWNLOAD_PREFIX:-${feed%/*}/}
account=${SPARKLE_ACCOUNT:-app.taudot.Taudot}
. "$rel/pins.sh"
sp="$(sparkle)/bin"

if [ -n "$(git -C "$repo" status --porcelain)" ]; then echo "make.sh: note: the working tree has changes; the build includes them" >&2; fi

# The EdDSA public key for Info.plist, from the Keychain (or the test key file).
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  pub=$(uv run --no-project --quiet --with cryptography==44.0.2 python "$rel/edkey.py" public "$SPARKLE_KEY_FILE")
  keyopt="--ed-key-file $SPARKLE_KEY_FILE"
else
  pub=$("$sp/generate_keys" --account "$account" -p 2>/dev/null) || {
    echo "make.sh: no Sparkle key in the Keychain for $account. Make it once (and back it up):" >&2
    echo "  $sp/generate_keys --account $account" >&2
    exit 1
  }
  keyopt="--account $account"
fi

mkdir -p "$out/$version" "$out/updates"
TAUDOT_VERSION=$version TAUDOT_FEED_URL=$feed TAUDOT_ED_PUBLIC_KEY=$pub \
  sh "$repo/clients/mac/bundle.sh" "$out/$version" >/dev/null
app="$out/$version/Taudot.app"
if [ -n "${ALLOW_AGPL:-}" ]; then sh "$rel/audit.sh" "$app" --allow-agpl; else sh "$rel/audit.sh" "$app"; fi

# The DMG: the app beside a link to /Applications.
dmg="$out/$version/Taudot-$version.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Taudot.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "Taudot $version" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg"
if [ "${SIGN_IDENTITY:--}" != - ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$dmg"
  [ -n "${NOTARY_PROFILE:-}" ] && sh "$rel/notarize.sh" "$dmg" "$NOTARY_PROFILE"
fi
echo "dmg: $dmg ($(du -h "$dmg" | cut -f1))"

# Updates: the DMG in the archive folder, and the appcast over all of them (each item signed with the EdDSA key).
cp "$dmg" "$out/updates/"
# shellcheck disable=SC2086
"$sp/generate_appcast" $keyopt --download-url-prefix "$prefix" --maximum-deltas 0 -o "$out/updates/appcast.xml" "$out/updates"
echo "appcast: $out/updates/appcast.xml (feed $feed; not uploaded)"

sh "$rel/gpl-source.sh" "$version" "$out/$version"
echo "release $version ready in $out (nothing uploaded)"
