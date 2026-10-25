#!/bin/zsh
# Builds the sandboxed Mac App Store edition of Kumquat.
#
#   scripts/build-appstore.sh --local
#       Signs ad hoc with the sandbox entitlements, for testing on this Mac:
#       build/appstore/Kumquat.app/Contents/MacOS/Kumquat --selftest
#
#   TEAM_ID=XXXXXXXXXX PROFILE=~/Downloads/Kumquat_Mac_App_Store.provisionprofile scripts/build-appstore.sh
#       Signs for distribution and writes build/appstore/Kumquat-<version>.pkg for App Store Connect.
#       Needs the "Apple Distribution" and "3rd Party Mac Developer Installer" certificates in the keychain
#       (Xcode → Settings → Accounts → Manage Certificates), and a Mac App Store provisioning profile.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-1.2}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
BUNDLE_ID=${BUNDLE_ID:-com.pavelbardin.kumquat}
APP_IDENTITY=${APP_IDENTITY:-Apple Distribution}
INSTALLER_IDENTITY=${INSTALLER_IDENTITY:-3rd Party Mac Developer Installer}
MODE=dist
[[ "${1:-}" == "--local" ]] && MODE=local
if [[ $MODE == dist ]]; then
  : "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
  : "${PROFILE:?Set PROFILE to the Mac App Store provisioning profile}"
fi

[[ -x vendor/ffmpeg/bin/ffmpeg ]] || ./scripts/build-ffmpeg.sh
swift build -c release -Xswiftc -DAPPSTORE --build-path .build/appstore

OUTDIR=build/appstore
APP=$OUTDIR/Kumquat.app
rm -rf "$OUTDIR" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/appstore/release/Kumquat "$APP/Contents/MacOS/Kumquat"
cp vendor/ffmpeg/bin/ffmpeg "$APP/Contents/MacOS/ffmpeg"
cp vendor/ffmpeg/Acknowledgements.txt "$APP/Contents/Resources/Acknowledgements.txt"

# App icon as an asset catalog (the App Store validates it) plus the .icns fallback.
TMP=$(mktemp -d)
ICONSET=$TMP/Assets.xcassets/AppIcon.appiconset
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
python3 - "$ICONSET" <<'PY'
import json, os, sys
d = sys.argv[1]
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        if os.path.exists(os.path.join(d, name)):
            images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": name})
json.dump({"images": images, "info": {"version": 1, "author": "xcode"}}, open(os.path.join(d, "Contents.json"), "w"))
json.dump({"info": {"version": 1, "author": "xcode"}}, open(os.path.join(os.path.dirname(d), "Contents.json"), "w"))
PY
xcrun actool "$TMP/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist "$TMP/partial.plist" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Kumquat</string>
  <key>CFBundleDisplayName</key><string>Kumquat</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Kumquat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppSleepDisabled</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Pavel Bardin</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Any file</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.item</string></array>
  </dict></array>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

ENTITLEMENTS=$TMP/app.entitlements
cp Resources/AppStore.entitlements "$ENTITLEMENTS"
if [[ $MODE == dist ]]; then
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS"
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  SIGN=$APP_IDENTITY
else
  SIGN=-
fi

# Inside out: the helper first, then the app.
codesign --force --sign "$SIGN" --entitlements Resources/Helper.entitlements --options runtime "$APP/Contents/MacOS/ffmpeg"
codesign --force --sign "$SIGN" --entitlements "$ENTITLEMENTS" --options runtime "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($MODE, $VERSION build $BUILD)"

if [[ $MODE == dist ]]; then
  PKG=$OUTDIR/Kumquat-$VERSION.pkg
  productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
  pkgutil --check-signature "$PKG" | head -3
  echo "Upload $PKG with Transporter (Mac App Store) or: xcrun altool --upload-app -f $PKG -t macos ..."
fi
rm -rf "$TMP"
