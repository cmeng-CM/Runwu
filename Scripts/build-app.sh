#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/润物.app"
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
# 优先用 Scripts/setup-signing.sh 一次性配好的稳定身份签名：TCC 按「证书 +
# Bundle ID」记忆授权，重建不再重置辅助功能与登录项；证书不在（新机器、CI）
# 时退回 ad-hoc。显式给出 CODESIGN_IDENTITY 时以它为准。本脚本只读取身份，
# 从不创建证书或改动钥匙串信任设置（那是 setup-signing.sh 的事）。
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"Runwu Local"'; then
  IDENTITY="Runwu Local"
else
  IDENTITY="-"
fi
# Disable network timestamps for reproducible local builds, including a supplied
# development identity. Distribution/notarization is a separate explicit action.
codesign --force --options runtime --timestamp=none \
  --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (signed with $IDENTITY)"
