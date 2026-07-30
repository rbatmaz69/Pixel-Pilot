#!/bin/bash
#
# Runs the PixelPilotCore test suite.
#
# swift-testing ships inside Xcode. When only the Command Line Tools are
# installed the framework is present but sits outside the default search and
# runtime paths, so `swift test` links fine and then fails to dlopen. This adds
# the paths only in that case — once Xcode is selected the flags disappear and
# plain `swift test` is what runs.
#
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Packages/PixelPilotCore" && pwd)"
cd "$PACKAGE_DIR"

DEVELOPER_DIR="$(xcode-select -p)"
EXTRA_FLAGS=()

if [[ "$DEVELOPER_DIR" == *"CommandLineTools"* ]]; then
  FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
  LIBS="$DEVELOPER_DIR/Library/Developer/usr/lib"

  if [[ ! -d "$FRAMEWORKS/Testing.framework" ]]; then
    echo "error: Testing.framework not found under $FRAMEWORKS" >&2
    echo "       Install Xcode, or update the Command Line Tools." >&2
    exit 1
  fi

  echo "note: using Command Line Tools toolchain — adding swift-testing paths"
  EXTRA_FLAGS=(
    -Xswiftc -F -Xswiftc "$FRAMEWORKS"
    -Xlinker -F -Xlinker "$FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$LIBS"
  )
fi

# The odd expansion keeps `set -u` happy with an empty array under the bash 3.2
# that ships with macOS.
exec swift test ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} "$@"
