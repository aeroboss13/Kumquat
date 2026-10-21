#!/bin/zsh
# Builds Kumquat.app into ./build and optionally installs it to ~/Applications (--install).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Kumquat.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Kumquat "$APP/Contents/MacOS/Kumquat"

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Kumquat</string>
  <key>CFBundleDisplayName</key><string>Kumquat</string>
  <key>CFBundleIdentifier</key><string>local.kumquat.converter</string>
  <key>CFBundleExecutable</key><string>Kumquat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSAppleEventsUsageDescription</key><string>Kumquat uses Pages and Keynote to convert iWork documents.</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Any file</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.item</string></array>
  </dict></array>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x Kumquat 2>/dev/null || true
  rm -rf ~/Applications/Kumquat.app
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/Kumquat.app"
  open ~/Applications/Kumquat.app
fi
