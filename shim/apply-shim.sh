#!/usr/bin/env bash
# 把原生 addon 换成纯 JS 替身（幂等，可回滚）
# 用法: bash apply-shim.sh /var/mobile/Library/dsh/app/node_modules
set -euo pipefail
NM="${1:?node_modules 路径}"
PKG="$NM/node-addon-require-builtin"
SHIM="$(cd "$(dirname "$0")" && pwd)/node-addon-require-builtin.js"

[ -d "$PKG" ] || { echo "找不到 $PKG"; exit 1; }
mkdir -p "$PKG/lib"
[ -f "$PKG/lib/index.js.orig" ] || cp "$PKG/lib/index.js" "$PKG/lib/index.js.orig"
cp "$SHIM" "$PKG/lib/index.js"

# 丢掉其它平台的预编译包，省 ~50MB 空间（可选）
rm -rf "$NM"/node-addon-require-builtin-{darwin,linux,win32}-* 2>/dev/null || true

echo "已套用 JS 替身 -> $PKG/lib/index.js"
echo "回滚: mv $PKG/lib/index.js.orig $PKG/lib/index.js"
