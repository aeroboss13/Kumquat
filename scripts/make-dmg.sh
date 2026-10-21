#!/bin/zsh
# Builds Kumquat.app and packs it into build/Kumquat-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0}"

./scripts/build-app.sh
APP=build/Kumquat.app
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

STAGING=$(mktemp -d)/Kumquat
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG="build/Kumquat-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Kumquat $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$(dirname "$STAGING")"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
