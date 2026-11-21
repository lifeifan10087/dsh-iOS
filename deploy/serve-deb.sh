#!/usr/bin/env bash
# 在局域网里把 deb 分享给 iPhone（HTTP），省掉 SSH/数据线
# 用法: bash deploy/serve-deb.sh [deb 路径]
set -euo pipefail
DEB="${1:-out/dsh-go_0.2.2_iphoneos-arm64.deb}"
[ -f "$DEB" ] || { echo "找不到 $DEB"; exit 1; }
DIR="$(cd "$(dirname "$DEB")" && pwd)"; FILE="$(basename "$DEB")"
IP="$(hostname -I 2>/dev/null | awk '{print $2 ? $2 : $1}')"
PORT="${PORT:-8899}"
echo "iPhone 用 Safari 打开下面地址："
echo "  http://${IP:-<这台手机的IP>}:${PORT}/${FILE}"
echo "下载后点“在 Sileo 中打开”，安装即可（不需要 SSH）。"
echo
echo "按 Ctrl+C 停止分享"
cd "$DIR" && exec python3 -m http.server "$PORT" --bind 0.0.0.0
