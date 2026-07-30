#!/bin/bash
#
# Runs both test suites: the core package and the app.
#
# They are separate because most logic lives in the UI-free package and runs
# under SwiftPM, while the display reconnect and disappearance paths live in
# AppModel and need the app bundle. Running only the first hides the second, so
# this runs both by default.
#
#   Scripts/test.sh            both suites
#   Scripts/test.sh --core     package only (fast)
#   Scripts/test.sh --app      app only
#
# swift-testing ships inside Xcode. When only the Command Line Tools are
# installed the framework is present but sits outside the default search and
# runtime paths, so `swift test` links fine and then fails to dlopen. This adds
# the paths only in that case — once Xcode is selected the flags disappear and
# plain `swift test` is what runs.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT/Packages/PixelPilotCore"

RUN_CORE=1
RUN_APP=1
case "${1:-}" in
  --core) RUN_APP=0; shift ;;
  --app) RUN_CORE=0; shift ;;
esac

run_app_tests() {
  if [[ ! -d "$ROOT/PixelPilot.xcodeproj" ]]; then
    "$ROOT/Scripts/generate.sh"
  fi
  echo ""
  echo "== App tests =="
  xcodebuild \
    -project "$ROOT/PixelPilot.xcodeproj" \
    -scheme PixelPilot \
    -configuration Debug \
    test 2>&1 | grep -E "error:|✘|✔ Test run with|TEST (SUCCEEDED|FAILED)" || {
      echo "error: app tests failed" >&2
      exit 1
    }
}

if [[ $RUN_CORE -eq 0 ]]; then
  run_app_tests
  exit 0
fi

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

echo "== Core tests =="
# The odd expansion keeps `set -u` happy with an empty array under the bash 3.2
# that ships with macOS.
swift test ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} "$@"

if [[ $RUN_APP -eq 1 ]]; then
  run_app_tests
fi
