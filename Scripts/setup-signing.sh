#!/bin/zsh
# 润物 Runwu —— 本地稳定签名身份一次性配置
#
# 作用：生成自签代码签名证书 "Runwu Local"（10 年期）导入登录钥匙串并开启
#       代码签名信任。此后 Scripts/build-app.sh 自动用它签名：
#       macOS 的 TCC 授权（辅助功能、登录项等）按「证书 + Bundle ID」记忆，
#       重新构建等于升级——授权一次，后续构建与升级都不再重置。
#       ad-hoc 签名没有稳定身份，系统按每次构建产物的哈希（cdhash）认应用，
#       每次重建都被当成新 App，授权与登录项整体作废（2026-10-10 实测）。
#
# 用法：zsh Scripts/setup-signing.sh
# 幂等：已存在 "Runwu Local" 身份时只做检查与提醒，不再重复生成。
# 参考：gourd 项目 tools/setup-signing.sh（同一套本地签名做法）。
set -euo pipefail

IDENTITY_NAME="Runwu Local"
BACKUP_DIR="$HOME/Library/Application Support/Runwu/signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY_NAME\""; then
  echo "✅ 已存在 \"$IDENTITY_NAME\" 签名身份，无需重复配置。"
  security find-identity -v -p codesigning | grep "\"$IDENTITY_NAME\""
  echo
  echo "提醒：这份签名身份的私钥备份在："
  echo "    $BACKUP_DIR"
  echo "    身份一旦更换（私钥丢失后重建同名新证书也算），所有用户的 TCC 授权与登录项都会重置。"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "① 生成自签代码签名证书（CN=$IDENTITY_NAME，有效期 10 年）…"
openssl req -x509 -newkey rsa:2048 -keyout "$work/key.pem" -out "$work/cert.pem" -days 3650 -nodes \
  -subj "/CN=$IDENTITY_NAME/O=cmeng/C=CN" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning,1.2.840.113635.100.6.1.13" 2>/dev/null
openssl pkcs12 -export -out "$work/identity.p12" -inkey "$work/key.pem" -in "$work/cert.pem" \
  -passout pass:runwu-local-import

echo "② 导入登录钥匙串（只允许 codesign 使用这张私钥）…"
security import "$work/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P runwu-local-import -T /usr/bin/codesign

# 备份落盘：钥匙串里的私钥受 ACL 保护（上面只授给了 codesign），事后想从
# 钥匙串导出需要一次人工授权、不一定成。所以生成时就把 p12 留一份出来。
mkdir -p "$BACKUP_DIR"
backup="$BACKUP_DIR/Runwu-Local-$(date +%Y%m%d).p12"
cp "$work/identity.p12" "$backup"
chmod 600 "$backup"

echo "③ 开启代码签名信任（用户域，只作用于代码签名策略，不影响 TLS 等）…"
security add-trusted-cert -r trustRoot -p codeSign "$work/cert.pem"

security find-identity -v -p codesigning | grep "\"$IDENTITY_NAME\""
echo "✅ 完成。之后 zsh Scripts/build-app.sh 自动使用这个身份签名。"
echo
echo "⚠️  私钥备份：$backup（导入密码 runwu-local-import）"
echo "    请移到密码管理器附件或加密备份里，不要留在同步盘、更不要进仓库。"
echo "    私钥丢失后重建同名新证书 = 换了签名身份，TCC 授权与登录项会整体重置。"
