#!/usr/bin/env bash
# 把「iOS 版 node + 引擎依赖 + 启动脚本 + launchd」打成一个 deb，
# iPhone 上用 Sileo/Filza 点开即装，postinst 自动完成剩余步骤（不需要 SSH）。
# 用法: bash deploy/make-install-deb.sh <node-ios 二进制> [依赖包 tgz]
set -euo pipefail
# root 的 umask 常是 077：不打散的话 /var、/var/jb/... 会被打成 700，
# 装上设备就会改坏 /var 的权限（HANDOFF 坑表「deb 装完目录 700」）。
umask 022
NODE_BIN="${1:?用法: make-install-deb.sh <node-ios 二进制> [node_modules.tgz]}"
MODS="${2:-out/node_modules.tgz}"
VER="${VER:-0.2.2}"
KIT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)/stage"
JB="var/jb"
APP="$JB/usr/local/lib/dsh"

[ -f "$NODE_BIN" ] || { echo "找不到 node 二进制: $NODE_BIN"; exit 1; }
[ -f "$MODS" ] || { echo "找不到依赖包: $MODS（先跑 deploy/bundle-node-modules.sh）"; exit 1; }

mkdir -p "$STAGE/$APP" "$STAGE/$JB/usr/local/bin" "$STAGE/$JB/Library/LaunchDaemons" "$STAGE/DEBIAN"
chmod 755 "$STAGE/$JB" "$STAGE/$JB/usr" "$STAGE/$JB/usr/local" "$STAGE/$JB/usr/local/lib" "$STAGE/$JB/usr/local/bin" "$STAGE/$JB/Library" "$STAGE/$JB/Library/LaunchDaemons"
cp "$NODE_BIN" "$STAGE/$APP/node"; chmod 755 "$STAGE/$APP/node"
cp "$MODS" "$STAGE/$APP/node_modules.tgz"; chmod 644 "$STAGE/$APP/node_modules.tgz"
cp "$KIT/shim/wasm-fake.cjs" "$STAGE/$APP/wasm-fake.cjs"; chmod 644 "$STAGE/$APP/wasm-fake.cjs"

# 启动器（--jitless：越狱机没给 JIT 授权时 node 会 SIGBUS，见 HANDOFF 坑表）
cat > "$STAGE/$JB/usr/local/bin/dsh-ios" <<'EOF'
#!/bin/sh
export DSH_HOME=/var/mobile/Library/dsh
exec /var/jb/usr/local/lib/dsh/node --jitless --require /var/jb/usr/local/lib/dsh/wasm-fake.cjs \
  --expose-internals --experimental-sqlite \
  --max-old-space-size=2048 \
  /var/mobile/Library/dsh/app/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
EOF
chmod 755 "$STAGE/$JB/usr/local/bin/dsh-ios"

# launchd 常驻
cat > "$STAGE/$JB/Library/LaunchDaemons/com.dsh.engine.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.dsh.engine</string>
  <key>ProgramArguments</key>
  <array>
    <string>/var/jb/usr/local/bin/dsh-ios</string><string>web</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>3080</string>
    <string>--no-open</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/var/jb/usr/bin:/usr/bin:/bin:/var/jb/usr/sbin:/usr/sbin</string>
    <key>HOME</key><string>/var/mobile</string>
  </dict>
  <key>WorkingDirectory</key><string>/var/mobile/Library/dsh</string>
  <key>StandardOutPath</key><string>/var/mobile/Library/Logs/dsh-engine.log</string>
  <key>StandardErrorPath</key><string>/var/mobile/Library/Logs/dsh-engine.log</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
EOF

# postinst：解依赖、套 JS 替身、加载守护进程、记录 token 地址
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
APP=/var/jb/usr/local/lib/dsh
DSH_HOME=/var/mobile/Library/dsh
mkdir -p "$DSH_HOME" /var/mobile/Library/Logs
if [ ! -d "$DSH_HOME/app/node_modules/@deepseek-ai/dsh" ]; then
  mkdir -p "$DSH_HOME/app"
  tar -C "$DSH_HOME/app" -xzf "$APP/node_modules.tgz"
fi
# JS 替身（原生 addon 在 iOS 上不可用）
P="$DSH_HOME/app/node_modules/node-addon-require-builtin/lib"
if [ -f "$P/index.js" ] && [ ! -f "$P/index.js.orig" ]; then
  cp "$P/index.js" "$P/index.js.orig"
  cat > "$P/index.js" <<'JS'
"use strict";
Object.defineProperty(exports,"__esModule",{value:true});
const {createRequire}=require("node:module");
const req=createRequire(__filename);const cache=new Map();
function requireBuiltin(id){if(cache.has(id))return cache.get(id);try{const m=req(id);cache.set(id,m);return m}catch(e){const err=new Error(`requireBuiltin(${id}) 失败: ${e.code||e.message}（需 --expose-internals）`);err.cause=e;throw err}}
function isAllowedInternalId(id){return typeof id==="string"&&id.startsWith("internal/")}
function getBindingInfo(){return{backend:"expose-internals"}}
exports.requireBuiltin=requireBuiltin;exports.isAllowedInternalId=isAllowedInternalId;exports.getBindingInfo=getBindingInfo;
JS
fi
chown -R mobile:mobile "$DSH_HOME" 2>/dev/null || true
if command -v ldid >/dev/null 2>&1; then ldid -S "$APP/node" || true; fi
launchctl bootout system /var/jb/Library/LaunchDaemons/com.dsh.engine.plist 2>/dev/null || true
launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.dsh.engine.plist 2>/dev/null || \
  launchctl load /var/jb/Library/LaunchDaemons/com.dsh.engine.plist || true
sleep 5
URL="$(grep -oE 'http://127\.0\.0\.1:3080/\?token=[A-Za-z0-9_-]+' /var/mobile/Library/Logs/dsh-engine.log 2>/dev/null | tail -1 || true)"
[ -n "$URL" ] && printf '%s' "$URL" > "$DSH_HOME/web-url.txt"
# 再放一份到「文件」App 能看到的目录，方便用 Filza 打开
mkdir -p /var/mobile/Documents 2>/dev/null || true
[ -n "$URL" ] && printf '%s\n' "$URL" > /var/mobile/Documents/dsh-url.txt 2>/dev/null || true
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

chmod 755 "$STAGE" "$STAGE/DEBIAN"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: com.dsh.go
Name: DSH Go Engine
Version: $VER
Architecture: iphoneos-arm64
Description: DeepSeek Harness engine for iOS (bundled arm64 iOS Node)
Maintainer: local
Section: Development
Depends: firmware (>= 14.0), gzip, ldid
EOF

chmod 755 "$STAGE" "$STAGE/var" "$STAGE/$APP" "$STAGE/DEBIAN"
chmod 644 "$STAGE/$JB/Library/LaunchDaemons/com.dsh.engine.plist"
OUT_DIR="${OUT_DIR:-out}"; mkdir -p "$OUT_DIR"
OUT_DEB="$OUT_DIR/dsh-go_${VER}_iphoneos-arm64.deb"
dpkg-deb -Zgzip -b "$STAGE" "$OUT_DEB" >/dev/null
echo "已生成: $OUT_DEB ($(du -h "$OUT_DEB" | cut -f1))"
rm -rf "$(dirname "$STAGE")"
