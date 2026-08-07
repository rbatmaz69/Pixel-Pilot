#!/bin/bash
#
# Builds a release disk image and publishes it as a GitHub release.
#
#   Scripts/release.sh 0.2.0            build, package, tag, publish
#   Scripts/release.sh 0.2.0 --dry-run  build and package only, touch nothing else
#
# Why this is not Scripts/install.sh with an extra step: that script signs with
# the development certificate, and an app signed that way runs on no other Mac.
# A development signature is only honoured on devices listed in a provisioning
# profile, so a release built that way would be refused on every machine but
# this one. Everything shipped here is therefore signed ad-hoc — deliberately,
# and verified below rather than assumed.
#
# The cost of ad-hoc: the signature changes with every release, and macOS ties
# the Accessibility grant to it. People have to grant it again after each
# update. Ending that needs a Developer ID certificate and notarisation, which
# needs the paid developer program. The signing arguments are collected in one
# place below so that switch stays a small one.
#
set -euo pipefail

APP_NAME="Pixel Pilot.app"
BUNDLE_ID="dev.rb.pixelpilot"
REPO_URL="https://github.com/rbatmaz69/Pixel-Pilot"
DERIVED_DATA=".build/release"
BUILD_LOG="/tmp/pixelpilot-release-build.log"

# The one place the distribution signature is decided. Swapping in a Developer
# ID identity and a notarisation step means changing this and step 6.
SIGNING_ARGS=(
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=
)

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# MARK: - Arguments

VERSION="${1:-}"
DRY_RUN=0
if [[ "${2:-}" == "--dry-run" ]]; then
  DRY_RUN=1
elif [[ -n "${2:-}" ]]; then
  echo "error: unknown argument '$2'" >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  cat >&2 <<'USAGE'
usage: Scripts/release.sh <version> [--dry-run]

  Scripts/release.sh 0.2.0            build, package, tag, publish
  Scripts/release.sh 0.2.0 --dry-run  build and package only
USAGE
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: '$VERSION' is not a version of the form 1.2.3" >&2
  exit 1
fi

TAG="v$VERSION"
DMG="dist/PixelPilot-$VERSION.dmg"

# MARK: - 1. Preconditions
#
# All of them up front. A release that is going to fail on a missing `gh` login
# should fail before it spends three minutes compiling.

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode." >&2
  exit 1
fi

if [[ $DRY_RUN -eq 0 ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh not found. Install it with: brew install gh" >&2
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh is not logged in. Run: gh auth login" >&2
    exit 1
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: the working tree has uncommitted changes." >&2
    echo "       A release should be a commit you can go back to." >&2
    exit 1
  fi

  if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists." >&2
    exit 1
  fi
fi

# MARK: - 2. Version
#
# project.yml stays the source of truth, so the version shown in the app is the
# version in the repository and not something a script passed in once.
#
# The build number is not written there: it is the commit count, which only ever
# goes up and needs no bookkeeping.

echo "==> Setting the version to $VERSION"
# The trailing .bak and its removal is what makes this work with BSD sed.
sed -i.bak -E "s/^([[:space:]]*MARKETING_VERSION:).*/\1 \"$VERSION\"/" project.yml
rm -f project.yml.bak

if ! grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml; then
  echo "error: could not set MARKETING_VERSION in project.yml." >&2
  exit 1
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"

# MARK: - 3. Project

echo "==> Generating the Xcode project"
./Scripts/generate.sh

# MARK: - 4. Tests
#
# The core suite only. The app suite needs a signed test bundle loaded into the
# app, which the ad-hoc release build below is not set up for.

echo "==> Running the core tests"
if ! ./Scripts/test.sh --core > /tmp/pixelpilot-release-tests.log 2>&1; then
  echo "error: core tests failed. Not releasing." >&2
  grep -E "error:|✘" /tmp/pixelpilot-release-tests.log | head -20 >&2
  echo "  (full log: /tmp/pixelpilot-release-tests.log)" >&2
  exit 1
fi

# MARK: - 5. Build
#
# A derived data path of its own. Sharing .build/xcode with the development
# build would leave an ad-hoc binary where Scripts/install.sh expects the
# signed one — and installing that would drop the Accessibility grant on the
# copy actually in daily use.

echo "==> Building (Release, ad-hoc signed, arm64)"
xcodebuild \
  -project PixelPilot.xcodeproj \
  -scheme PixelPilot \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  "${SIGNING_ARGS[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  build \
  > "$BUILD_LOG" 2>&1 || {
    echo "error: build failed." >&2
    grep -E "error:" "$BUILD_LOG" | head -20 >&2
    echo "  (full log: $BUILD_LOG)" >&2
    exit 1
  }

BUILT="$(pwd)/$DERIVED_DATA/Build/Products/Release/$APP_NAME"
if [[ ! -d "$BUILT" ]]; then
  echo "error: expected a built app at $BUILT" >&2
  exit 1
fi

# MARK: - 6. Verify the signature
#
# The point of this step: catch a build that was signed with the development
# certificate after all. That app looks fine here and refuses to launch on
# every other Mac, which is exactly the failure a release must not ship.

echo "==> Verifying the signature"
codesign --verify --strict "$BUILT" || {
  echo "error: the built app does not pass codesign --verify." >&2
  exit 1
}

SIGNATURE="$(codesign -dvvv "$BUILT" 2>&1)"

if ! grep -q "Signature=adhoc" <<<"$SIGNATURE"; then
  echo "error: the app is not signed ad-hoc — this build would not run on other Macs." >&2
  grep -E "Authority|Signature|TeamIdentifier" <<<"$SIGNATURE" | sed 's/^/  /' >&2
  exit 1
fi

# An ad-hoc signature reports "TeamIdentifier=not set". Anything else means a
# certificate was involved, whatever the line above said.
TEAM="$(grep -E "^TeamIdentifier=" <<<"$SIGNATURE" | head -1 | cut -d= -f2-)"
if [[ -n "$TEAM" && "$TEAM" != "not set" ]]; then
  echo "error: the app carries the team identifier '$TEAM', so it was not signed ad-hoc." >&2
  exit 1
fi

if ! grep -q "Identifier=$BUNDLE_ID" <<<"$SIGNATURE"; then
  echo "error: bundle identifier is not $BUNDLE_ID." >&2
  exit 1
fi

if ! grep -q "flags=.*runtime" <<<"$SIGNATURE"; then
  echo "warning: the hardened runtime is not enabled on this build." >&2
fi

# MARK: - 7. Disk image
#
# hdiutil rather than create-dmg: one fewer thing to install, and the layout
# wanted here is just the app and a symlink beside it.

echo "==> Building $DMG"
mkdir -p dist
rm -f "$DMG"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$BUILT" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "Pixel Pilot" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG" \
  > /dev/null

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "    $DMG ($SIZE)"

# MARK: - 8. Publish

NOTES_FILE="$(mktemp)"
cat > "$NOTES_FILE" <<NOTES
<div align="center">

<img src="https://raw.githubusercontent.com/rbatmaz69/Pixel-Pilot/$TAG/Art/icon.png" width="96" alt="Pixel Pilot">

**Brightness, contrast, colour temperature and volume for external displays on macOS — over DDC/CI, from the menu bar.**

\`PixelPilot-$VERSION.dmg\` · macOS 26 (Tahoe) · Apple Silicon

</div>

## 📦 Install

1. Download \`PixelPilot-$VERSION.dmg\` below and open it.
2. Drag **Pixel Pilot** onto the Applications folder.
3. Launch it, clear the two prompts below, and look for the poppy in the menu
   bar. There is no Dock icon.

> [!IMPORTANT]
> **The first launch is refused: macOS cannot verify the app**, because it is
> not notarised — that needs the paid Apple developer program, and this is not
> in it. Open **System Settings → Privacy & Security**, find the message about
> Pixel Pilot near the bottom, and press **Open Anyway**.

> [!NOTE]
> Pixel Pilot then asks for **Accessibility** permission. It needs it to act on
> the brightness and volume keys, which it reads through an event tap.

> [!WARNING]
> **Updating:** the app is signed ad-hoc, so its signature changes with every
> release, and macOS ties the Accessibility grant to that signature. After
> installing a new version, remove Pixel Pilot from System Settings → Privacy &
> Security → Accessibility and add it again.

NOTES

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo "Dry run. Nothing was committed, tagged or published."
  echo "Note that project.yml now says $VERSION — revert it with:"
  echo "  git checkout project.yml"
  rm -f "$NOTES_FILE"
  exit 0
fi

# Commit, tag, push and publish are the steps that leave this machine and are
# awkward to take back, so they are shown before they happen and asked about
# once.
cat <<PLAN

About to:
  commit  project.yml (version $VERSION)
  tag     $TAG
  push    the commit and the tag to origin
  publish $TAG on GitHub with $DMG attached

PLAN

read -r -p "Go ahead? [y/N] " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Stopped. $DMG is still there; project.yml still says $VERSION."
  rm -f "$NOTES_FILE"
  exit 1
fi

echo "==> Committing and tagging"
git add project.yml
# Releasing the version project.yml already carries leaves nothing staged, and
# git commit treats that as an error. The tag is what marks the release; the
# commit only exists when the number actually changed.
if git diff --cached --quiet; then
  echo "    project.yml already says $VERSION — tagging the commit that is there"
else
  git commit -m "Say which version this is" --quiet
fi
git tag "$TAG"
git push --quiet origin HEAD
git push --quiet origin "$TAG"

echo "==> Publishing $TAG"
gh release create "$TAG" "$DMG" \
  --title "Pixel Pilot $VERSION" \
  --notes-file "$NOTES_FILE" \
  --generate-notes

rm -f "$NOTES_FILE"

echo
echo "Released. $REPO_URL/releases/tag/$TAG"
