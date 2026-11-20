#!/usr/bin/env bash
# 把 macOS 的 arm64 Mach-O（node / *.node / dylib）改成 iOS 平台并重签。
# 依赖: vtool（cctools-port / theos 自带）、ldid
# 用法: bash patch-macho-ios.sh in.bin [out.bin]
set -euo pipefail
IN="${1:?输入文件}"
OUT="${2:-${IN%.*}.ios}"
MIN_IOS="${MIN_IOS:-14.0}"
SDK_VER="${SDK_VER:-18.0}"
ENT="$(cd "$(dirname "$0")" && pwd)/entitlements.plist"

vtool -set-build-version ios "$MIN_IOS" "$SDK_VER" -replace -output "$OUT" "$IN"
# 去掉 macOS 专属的 min_version load command 冲突，并清掉签名后重签
install_name_tool -id "$(basename "$OUT")" "$OUT" 2>/dev/null || true
codesign --remove-signature "$OUT" 2>/dev/null || true
ldid -S"$ENT" "$OUT"
echo "已生成 $OUT"
otool -l "$OUT" | grep -A3 -m1 "LC_BUILD_VERSION" || true
