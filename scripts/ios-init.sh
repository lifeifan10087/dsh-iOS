#!/usr/bin/env bash
# 在越狱 iPhone 上初始化 dsh 引擎（rootless /var/jb 与 rootful 都能跑）
# 依赖: node>=22 已在 PATH（Procursus: apt install nodejs，或自编后放到 /var/jb/usr/bin/node）
set -euo pipefail

JB=""
[ -d /var/jb ] && JB="/var/jb"
HOME_DIR="/var/mobile/Library/dsh"
APP="$HOME_DIR/app"
NODE_BIN="${NODE_BIN:-$(command -v node || echo /var/jb/usr/bin/node)}"
LOG="/var/mobile/Library/Logs/dsh-engine.log"
LAUNCHER="$JB/usr/local/bin/dsh-ios"
PLIST="$JB/Library/LaunchDaemons/com.dsh.engine.plist"

[ -x "$NODE_BIN" ] || { echo "找不到 node，可 export NODE_BIN=/path/to/node"; exit 1; }
"$NODE_BIN" -e "const [a,b]=process.versions.node.split('.').map(Number); if(a<22) throw new Error('node 版本过低: '+process.versions.node)"

mkdir -p "$HOME_DIR" "$APP" "$(dirname "$LOG")" "$JB/usr/local/bin" "$JB/Library/LaunchDaemons"

# 1) 装引擎（首次）；已装则跳过
#    iOS 上的 node 是不带 npm 编译的，所以优先用 Mac 侧打好的 node_modules.tgz
if [ ! -d "$APP/node_modules/@deepseek-ai/dsh" ]; then
  if [ -f /tmp/node_modules.tgz ]; then
    echo "用 Mac 侧打包的 node_modules"
    tar -C "$APP" -xzf /tmp/node_modules.tgz
  elif command -v npm >/dev/null 2>&1; then
    cd "$APP"; npm init -y >/dev/null
    npm config set registry https://registry.npmmirror.com
    npm i @deepseek-ai/dsh@0.2.2-rc.1 --omit=dev --ignore-scripts
  else
    echo "没有 npm 也没有 /tmp/node_modules.tgz"
    echo "先在 Mac 上跑 deploy/bundle-node-modules.sh，再 scp out/node_modules.tgz 到设备 /tmp/"
    exit 1
  fi
fi

# 2) 原生 addon 换 JS 替身
bash "$(dirname "$0")/../shim/apply-shim.sh" "$APP/node_modules"

# 3) 启动器：--expose-internals 是替身的前提
mkdir -p "$(dirname "$LAUNCHER")"
# --jitless 是必须的（越狱机没给 JIT，V8 一分配代码页就 SIGBUS，见 HANDOFF 坑表）；
# wasm-fake.cjs 让 undici 在"没有 WebAssembly"的 jitless 下也能加载完模块。
cp "$(dirname "$0")/../shim/wasm-fake.cjs" "$HOME_DIR/wasm-fake.cjs" 2>/dev/null || true
chmod 644 "$HOME_DIR/wasm-fake.cjs" 2>/dev/null || true
cat > "$LAUNCHER" <<EOF
#!/bin/sh
export DSH_HOME="$HOME_DIR"
exec "$NODE_BIN" --jitless --require "$HOME_DIR/wasm-fake.cjs" --expose-internals --max-old-space-size=2048 --experimental-sqlite \\
  "$APP/node_modules/@deepseek-ai/dsh/lib/bin.js" "\$@"
EOF
chmod +x "$LAUNCHER"

# 4) launchd 常驻（iOS 不给普通进程后台，daemon 才稳）
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.dsh.engine</string>
  <key>ProgramArguments</key>
  <array>
    <string>$LAUNCHER</string><string>web</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>3080</string>
    <string>--no-open</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$JB/usr/bin:/usr/bin:/bin:$JB/usr/sbin:/usr/sbin</string>
    <key>HOME</key><string>/var/mobile</string>
  </dict>
  <key>WorkingDirectory</key><string>$HOME_DIR</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
EOF

launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load "$PLIST"
sleep 6
URL="$(grep -oE 'http://127\.0\.0\.1:3080/\?token=[A-Za-z0-9_-]+' "$LOG" | tail -1 || true)"
[ -n "$URL" ] && printf '%s' "$URL" > "$HOME_DIR/.web-url" && echo "打开: $URL"
echo "日志: $LOG"
