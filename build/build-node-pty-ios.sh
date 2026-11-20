#!/usr/bin/env bash
# 编 node-pty 的 iOS 版（N-API，不挑 Node ABI）。缺失时只影响"持久终端"，普通 bash 工具照跑。
set -euo pipefail
WORK="${WORK:-$HOME/node-pty-ios}"
MIN_IOS="${MIN_IOS:-14.0}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios${MIN_IOS}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$(uname -s)" = Darwin ] || { echo "需要 macOS"; exit 1; }
command -v node-gyp >/dev/null || npm i -g node-gyp

mkdir -p "$WORK"; cd "$WORK"
[ -d node-pty ] || git clone --depth 1 https://github.com/microsoft/node-pty.git
cd node-pty

export CFLAGS="-target $TARGET -isysroot $SDK -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-target $TARGET -isysroot $SDK -Wl,-platform_version,ios,$MIN_IOS,18.0"

node-gyp rebuild --arch=arm64 --jobs max -- -Dtarget_arch=arm64 -Dtarget_os=mac

NODE_FILE="$(find build -name 'pty.node' | head -1)"
[ -n "$NODE_FILE" ] || { echo "没产出 pty.node，看上面的编译错误"; exit 1; }
cp "$NODE_FILE" "$WORK/pty.node.raw"
bash "$HERE/patch-macho-ios.sh" "$WORK/pty.node.raw" "$WORK/pty.node"
echo "产物: $WORK/pty.node"
echo "装到设备:"
echo "  scp $WORK/pty.node root@<device>:<DSH_HOME>/app/node_modules/node-pty/build/Release/pty.node"
