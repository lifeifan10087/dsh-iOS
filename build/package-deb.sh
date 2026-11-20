#!/usr/bin/env bash
# 打成 rootless deb（Sileo/Zebra 可装），也支持直接 dpkg -i
# 用法: bash package-deb.sh /path/to/staged-root
set -euo pipefail
STAGE="${1:?staged root 目录（里面是 var/jb/... 结构）}"
NAME="${NAME:-com.dsh.go}"
VER="${VER:-0.2.2}"
OUT="${OUT:-/tmp/${NAME}_${VER}_iphoneos-arm64.deb}"

mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $NAME
Name: DSH Go
Version: $VER
Architecture: iphoneos-arm64
Description: DeepSeek Harness engine + native shell for iOS
Maintainer: local
Section: Development
Depends: firmware (>= 14.0)
EOF
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
[ -x /var/jb/usr/bin/uicache ] && /var/jb/usr/bin/uicache -a || uicache -a || true
/var/jb/usr/bin/launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.dsh.engine.plist 2>/dev/null || true
exit 0
EOF
chmod +x "$STAGE/DEBIAN/postinst"
chmod -R go-w "$STAGE"

dpkg-deb -Zgzip -b "$STAGE" "$OUT"
echo "已生成 $OUT"
echo "设备上: dpkg -i $OUT   (或 Sileo 打开)"
