#!/bin/sh
# Builds TaudotPinch.app next to this script (build.noindex/), ad-hoc signed.
#   clients/rex/pinch/build.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
app="$here/build.noindex/TaudotPinch.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.taudot.pinch</string>
  <key>CFBundleName</key><string>TaudotPinch</string>
  <key>CFBundleExecutable</key><string>taudot-pinch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
swiftc -O -o "$app/Contents/MacOS/taudot-pinch" "$here/main.swift" -framework Cocoa -framework ApplicationServices
codesign --force --sign - --identifier app.taudot.pinch "$app"
echo "$app"
