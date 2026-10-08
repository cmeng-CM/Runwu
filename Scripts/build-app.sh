#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/Runwu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Pico" "$APP/Contents/MacOS/Runwu"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon ships as a classic .icns (CFBundleIconFile=AppIcon in Info.plist).
# actool silently drops the AppIcon asset set on this project, so the icon is
# committed as Resources/AppIcon.icns instead of living in the catalog.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# MIT obligation rides with the distributed copy: keep LICENSE inside the bundle.
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp Resources/Icons/ATTRIBUTION.md "$APP/Contents/Resources/ICON-ATTRIBUTION.md"

# Compile the remaining asset catalog images (menu bar / history icons).
xcrun actool \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --compile "$APP/Contents/Resources" \
  Resources/Assets.xcassets

ENTITLEMENTS="$ROOT/Resources/Pico.entitlements"
# Local builds use ad-hoc signing unless an existing identity is selected.
# This script never creates certificates or changes Keychain trust/settings.
IDENTITY="${CODESIGN_IDENTITY:--}"
# Disable network timestamps for reproducible local builds, including a supplied
# development identity. Distribution/notarization is a separate explicit action.
codesign --force --options runtime --timestamp=none \
  --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (signed with $IDENTITY)"
