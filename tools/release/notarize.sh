#!/bin/sh
# Notarize and staple a Developer ID-signed DMG (make.sh runs it when SIGN_IDENTITY and NOTARY_PROFILE are set):
#   tools/release/notarize.sh Taudot-VERSION.dmg PROFILE
# PROFILE is a notarytool Keychain profile, made once with
#   xcrun notarytool store-credentials PROFILE --apple-id ... --team-id ... (an app-specific password)
# so no credential is ever in the repo or on a command line here. Unused until there is a Developer ID.
set -eu
dmg=$1
profile=$2
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
