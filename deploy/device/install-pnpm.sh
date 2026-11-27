#!/var/jb/bin/sh
# 在设备上装 pnpm（纯 JS）+ 原生启动器。
#
# 为什么必须是原生启动器：
#   · 设备上没有 /bin/sh（只有 /var/jb/bin/sh）
#   · 更关键：node 的 child_process.spawn 执行**脚本**会返回 EPERM（iOS posix_spawn 限制），
#     而 dsh 的插件管理用 execa spawn("pnpm")，脚本包装器根本起不来
#   所以 pnpm 这个命令得是 Mach-O（launcher/pnpm.c 编出来的），内部 execv 到 node。
#
# 用法: install-pnpm.sh <pnpm-版本包.tgz> <pnpm-原生启动器>
set -e
JB=/var/jb
DEST="$JB/usr/local/lib/dsh/pnpm"
TGZ="${1:-/tmp/pnpm.tgz}"
BIN="${2:-/tmp/pnpm-launcher}"

[ -f "$TGZ" ] || { echo "找不到 $TGZ"; exit 1; }
[ -f "$BIN" ] || { echo "找不到原生启动器 $BIN"; exit 1; }

rm -rf "$DEST"; mkdir -p "$DEST"
tar -C "$DEST" -xzf "$TGZ" --strip-components=1
chmod -R a+rX "$DEST"

install -m 755 "$BIN" "$JB/usr/bin/pnpm"
ldid -S "$JB/usr/bin/pnpm" 2>/dev/null || true
echo "pnpm 启动器: $(ls -l "$JB/usr/bin/pnpm" | sed 's/.* \(.*\)/\1/')"
echo "版本: $("$JB/usr/bin/pnpm" --version 2>&1 | tail -1)"
