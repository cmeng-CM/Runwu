#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# DMG distribution currently uses ad-hoc signing only, regardless of inherited
# signing or notarization environment variables. No network notarization runs.
CODESIGN_IDENTITY=- zsh "$ROOT/Scripts/build-app.sh"

APP="$ROOT/润物.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/润物-${VERSION}.dmg"
mkdir -p "$ROOT/dist"
# Keep the temporary image on the destination filesystem so the final rename
# replaces an existing release only after creation and verification succeed.
WORK="$(mktemp -d "$ROOT/dist/.runwu-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/润物.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "润物" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO "$WORK/润物-${VERSION}.dmg"
hdiutil verify "$WORK/润物-${VERSION}.dmg"
mv -f "$WORK/润物-${VERSION}.dmg" "$DMG"
echo "Built $DMG (ad-hoc signed; not notarized)"
