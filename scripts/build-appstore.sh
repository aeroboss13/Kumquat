#!/bin/zsh
# Builds the sandboxed Mac App Store edition of Kumquat.
#
#   scripts/build-appstore.sh --local
#       Signs ad hoc with the sandbox entitlements, for testing on this Mac:
#       build/appstore/Kumquat.app/Contents/MacOS/Kumquat --selftest
#
#   scripts/build-appstore.sh
#       Archives with Xcode and exports a signed build/xc/export/Kumquat.pkg for App Store Connect.
#       Signing is automatic (cloud-managed certificates of team 9R756Z2ZZG); the Apple ID in
#       Xcode → Settings → Accounts must belong to that team.
#
#   scripts/build-appstore.sh --upload
#       Same, then uploads the build to App Store Connect with the Xcode account.
#       The app record (bundle ID ru.pabit.kumquat) must already exist in App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-1.2}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
MODE=${1:-dist}

[[ -x vendor/ffmpeg/bin/ffmpeg ]] || ./scripts/build-ffmpeg.sh

if [[ $MODE != "--local" ]]; then
  xcodegen generate --quiet
  rm -rf build/xc
  xcodebuild archive -project Kumquat.xcodeproj -scheme Kumquat -configuration Release \
    -archivePath build/xc/Kumquat.xcarchive -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" -quiet
  OPTIONS=Resources/ExportOptions-AppStore.plist
  if [[ $MODE == "--upload" ]]; then
    OPTIONS=$(mktemp -d)/ExportOptions.plist
    cp Resources/ExportOptions-AppStore.plist "$OPTIONS"
    /usr/libexec/PlistBuddy -c "Set :destination upload" "$OPTIONS"
  fi
  xcodebuild -exportArchive -archivePath build/xc/Kumquat.xcarchive -exportPath build/xc/export \
    -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates -quiet
  [[ $MODE == "--upload" ]] && echo "Uploaded $VERSION ($BUILD) to App Store Connect." \
                            || echo "Built build/xc/export/Kumquat.pkg ($VERSION, build $BUILD)"
  exit 0
fi

# --local: sandboxed build signed ad hoc, assembled without Xcode, for testing on this Mac.
BUNDLE_ID=ru.pabit.kumquat
swift build -c release -Xswiftc -DAPPSTORE --build-path .build/appstore
OUTDIR=build/appstore
APP=$OUTDIR/Kumquat.app
rm -rf "$OUTDIR" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/appstore/release/Kumquat "$APP/Contents/MacOS/Kumquat"
cp vendor/ffmpeg/bin/ffmpeg "$APP/Contents/MacOS/ffmpeg"
cp vendor/ffmpeg/Acknowledgements.txt "$APP/Contents/Resources/Acknowledgements.txt"
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist /dev/null >/dev/null
sed -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" -e "s/\$(EXECUTABLE_NAME)/Kumquat/" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/" -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/15.0/" Resources/AppStore-Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - --entitlements Resources/Helper.entitlements --options runtime "$APP/Contents/MacOS/ffmpeg"
codesign --force --sign - --entitlements Resources/AppStore.entitlements --options runtime "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (local sandbox test, $VERSION build $BUILD)"
