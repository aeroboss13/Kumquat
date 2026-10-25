#!/bin/zsh
# Xcode build phase: re-signs the embedded ffmpeg with the sandbox-inherit entitlements.
# Xcode signs the app itself afterwards, and re-signs both on export for the App Store.
set -euo pipefail
HELPER="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/ffmpeg"
[[ -f "$HELPER" ]] || { echo "error: ffmpeg missing at $HELPER (run scripts/build-ffmpeg.sh)"; exit 1; }
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime \
  --entitlements "$SRCROOT/Resources/Helper.entitlements" "$HELPER"
