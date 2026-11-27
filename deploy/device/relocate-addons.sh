#!/bin/sh
# 把 node_modules 里的原生 addon 搬到 /var/jb 并留符号链接。
#
# 原因：越狱机的沙箱只允许从 /var/jb（以及系统路径）mmap 可执行页；直接从
# /var/mobile/Library/dsh/app/node_modules/... dlopen 原生 addon 会报
#   file system sandbox blocked mmap() of '...'
# 符号链接指向 /var/jb 里的实体后，内核按真实路径判定，就能加载了。
# 幂等：已经是符号链接的会跳过。
set -u
BASE="${1:-/var/mobile/Library/dsh/app/node_modules}"
DEST="${2:-/var/jb/usr/local/lib/dsh/addons}"

mkdir -p "$DEST" || exit 0
n=0
for f in $(find "$BASE" -name "*.node" -type f 2>/dev/null); do
  rel=${f#$BASE/}
  safe=$(echo "$rel" | tr '/' '_')
  cp -f "$f" "$DEST/$safe" 2>/dev/null || continue
  chmod 755 "$DEST/$safe"
  rm -f "$f"
  ln -s "$DEST/$safe" "$f"
  n=$((n+1))
done
echo "relocate-addons: 处理 $n 个"
