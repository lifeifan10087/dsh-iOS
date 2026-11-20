#!/usr/bin/env bash
# 编译前预检（在 macOS 或 GitHub macos runner 上跑）
set -uo pipefail
fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

echo "[1] 系统"
[ "$(uname -s)" = Darwin ] && ok "Darwin $(sw_vers -productVersion)" || bad "必须是 macOS"
[ "$(uname -m)" = arm64 ] && ok "Apple Silicon（可交叉编 arm64）" || warn "Intel Mac，交叉编 arm64 可行但慢"

echo "[2] 工具链"
xcode-select -p >/dev/null 2>&1 && ok "$(xcode-select -p)" || bad "缺 Command Line Tools：xcode-select --install"
for t in clang clang++ make python3 git; do
  command -v "$t" >/dev/null && ok "$t: $(command -v $t)" || bad "缺 $t"
done

echo "[3] iOS SDK"
SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
if [ -n "$SDK" ] && [ -d "$SDK" ]; then
  ok "SDK $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null) @ $SDK"
else
  bad "缺 iPhoneOS SDK（Xcode 里装 iOS platform，或 xcodebuild -downloadPlatform iOS）"
fi

echo "[4] 交叉工具（可选）"
for t in vtool ldid otool codesign; do
  command -v "$t" >/dev/null && ok "$t" || warn "缺 $t（打包/改平台号时才需要；ldid 可 brew install ldid）"
done

echo "[5] host node（给 configure/依赖生成用）"
if command -v node >/dev/null; then
  ok "node $(node -v) / npm $(npm -v 2>/dev/null)"
  node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>=22?0:1)' && ok "host node ≥22" || bad "host node 需 ≥22"
else
  bad "缺 host node（brew install node@24 或 setup-node）"
fi

echo "[6] 磁盘"
avail=$(df -Pk "$HOME" | awk 'NR==2{printf "%d", $4/1024/1024}')
[ "${avail:-0}" -ge 25 ] && ok "可用 ${avail}GB" || bad "需要 ≥25GB，当前 ${avail}GB"

echo
if [ $fail -eq 0 ]; then echo "预检通过，可以跑 build-node-ios.sh"; else echo "预检未通过：先修上面的 ✗"; exit 1; fi
