#!/bin/bash
#
# Builds Pixel Pilot in Release and installs it to /Applications.
#
# Why this exists: running the app straight out of DerivedData works, but that
# directory is Xcode's scratch space. A "Clean Build Folder", a scheme change or
# Xcode's own housekeeping deletes it — and with it the app and its
# Accessibility grant, which macOS ties to the bundle's path and signature.
#
# Install first, grant Accessibility second. The other order means granting
# permission to a copy that is about to be replaced.
#
set -euo pipefail

BUNDLE_ID="dev.rb.pixelpilot"
APP_NAME="Pixel Pilot.app"
DESTINATION="/Applications/$APP_NAME"

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -d PixelPilot.xcodeproj ]]; then
  echo "==> Generating the Xcode project"
  ./Scripts/generate.sh
fi

echo "==> Building (Release)"
xcodebuild \
  -project PixelPilot.xcodeproj \
  -scheme PixelPilot \
  -configuration Release \
  -derivedDataPath .build/xcode \
  build \
  > /tmp/pixelpilot-build.log 2>&1 || {
    echo "error: build failed. Last 30 lines:" >&2
    tail -30 /tmp/pixelpilot-build.log >&2
    exit 1
  }

BUILT="$(pwd)/.build/xcode/Build/Products/Release/$APP_NAME"
if [[ ! -d "$BUILT" ]]; then
  echo "error: expected a built app at $BUILT" >&2
  exit 1
fi

echo "==> Quitting any running instance"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
# Give it a moment to restore any gamma tables it had applied before we replace
# the binary underneath it.
sleep 1
pkill -f "$APP_NAME/Contents/MacOS" 2>/dev/null || true

if [[ -e "$DESTINATION" ]]; then
  # Only ever replace our own app. Reading the identifier first means a typo in
  # APP_NAME can never delete something else out of /Applications.
  EXISTING_ID="$(defaults read "$DESTINATION/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")"
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "error: $DESTINATION exists but its bundle id is '$EXISTING_ID', not '$BUNDLE_ID'." >&2
    echo "       Refusing to replace it. Move it aside manually if this is intentional." >&2
    exit 1
  fi
  echo "==> Removing the previous install"
  rm -rf "$DESTINATION"
fi

echo "==> Installing to $DESTINATION"
cp -R "$BUILT" "$DESTINATION"

echo "==> Launching"
open "$DESTINATION"

echo
echo "Installed. Signature:"
codesign -dv "$DESTINATION" 2>&1 | grep -E "Identifier|Signature" | sed 's/^/  /'
echo
if codesign -dv "$DESTINATION" 2>&1 | grep -q adhoc; then
  cat <<'NOTE'
Note: this build is signed ad-hoc, so its signature changes every time you run
this script. macOS will ask for the Accessibility permission again after each
install. Adding an Apple ID in Xcode → Settings → Accounts produces a stable
development certificate and ends that — see README.
NOTE
fi
