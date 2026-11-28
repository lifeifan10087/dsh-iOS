#!/usr/bin/env bash
# 在任意一台装了 Xcode 的 Mac 上，一条命令出 DshGo.ipa
#   bash shell/build-ipa.sh
# 产物：out/DshGo.ipa
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK: $SDK"
rm -rf out Payload
mkdir -p out Payload/DshGo.app
xcrun -sdk iphoneos swiftc -target arm64-apple-ios14.0 -O -sdk "$SDK" \
  -framework UIKit -framework SafariServices \
  -o Payload/DshGo.app/DshGo shell/main.swift
cp shell/Info.plist Payload/DshGo.app/Info.plist
chmod 755 Payload/DshGo.app/DshGo
if command -v ldid >/dev/null 2>&1; then
  ldid -Sshell/entitlements-ipa.plist Payload/DshGo.app/DshGo
  echo "已用 ldid 签名（带 platform-application 等 entitlement）"
else
  echo "没有 ldid：产物未签名，TrollStore/Sideloadly 会自己签"
fi
(cd Payload && zip -qry ../out/DshGo.ipa DshGo.app)
ls -lh out/DshGo.ipa
