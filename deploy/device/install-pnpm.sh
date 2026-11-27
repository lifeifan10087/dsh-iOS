#!/bin/sh
# 在设备上装一份纯 JS 的 pnpm（node 是 --without-npm 编的，没有 npm/npx，
# 但 dsh plugin 把参数转发给 pnpm，所以只要有 pnpm 就能装插件）。
set -e
JB=/var/jb
DEST="$JB/usr/local/lib/dsh/pnpm"
SRC="${1:-/tmp/pnpm.tgz}"

[ -f "$SRC" ] || { echo "找不到 $SRC"; exit 1; }
rm -rf "$DEST"; mkdir -p "$DEST"
tar -C "$DEST" -xzf "$SRC" --strip-components=1
chmod -R a+rX "$DEST"

cat > "$JB/usr/local/bin/pnpm" <<'EOF'
#!/bin/sh
# 用设备上的 iOS 版 node 跑 pnpm；带 preload（平台谎报 darwin + fetch 替身）
exec /var/jb/usr/local/lib/dsh/node --jitless \
  --require /var/mobile/Library/dsh/shim/ios-preload.cjs \
  /var/jb/usr/local/lib/dsh/pnpm/bin/pnpm.cjs "$@"
EOF
chmod 755 "$JB/usr/local/bin/pnpm"
echo "pnpm 已装: $("$JB/usr/local/bin/pnpm" --version 2>&1 | tail -1)"
