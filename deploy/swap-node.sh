#!/usr/bin/env bash
# 把新编的 iOS node 替换到设备上，重启守护进程并跑验收。
# 用法: source .secrets.env && SSHPASS=xxx bash deploy/swap-node.sh out/node-ios-patched
#       DEVICE=mobile@1.2.3.4 bash deploy/swap-node.sh out/node-ios-patched --no-accept
# 说明:
#   - node 路径从启动器 /usr/local/bin/dsh-ios 里读，读不到回退 /var/jb/usr/bin/node
#   - 替换前留 node.bak-<时间戳>，出问题可一条 mv 回滚
#   - 启动器带 --jitless：越狱机没给 JIT 授权时 node 会 SIGBUS（见 HANDOFF 坑表）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NEW="${1:?新 node 二进制路径（out/node-ios-patched）}"
shift || true
DO_ACCEPT=1
for a in "$@"; do [ "$a" = "--no-accept" ] && DO_ACCEPT=0; done

DEVICE="${DEVICE:-${IPHONE_USER:-mobile}@${IPHONE_IP:-192.168.10.229}}"
PORT="${PORT:-22}"
SSHOPT=(-p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR -o ConnectTimeout=12)
if [ -n "${SSHPASS:-}" ]; then
  S()   { sshpass -e ssh "${SSHOPT[@]}" "$DEVICE" "$@"; }
  SCP() { sshpass -e scp "${SSHOPT[@]/#-p/-P}" "$@"; }
else
  S()   { ssh "${SSHOPT[@]}" "$DEVICE" "$@"; }
  SCP() { scp "${SSHOPT[@]/#-p/-P}" "$@"; }
fi
SUDO='echo $SSHPASS | sudo -S -p ""'

[ -f "$NEW" ] || { echo "没有这个文件: $NEW"; exit 1; }
echo "== 0) 本地产物预检"
python3 "$HERE/verify-node-ios.py" "$NEW" 22.20 || { echo "产物校验没过，先别上设备"; exit 1; }

echo "== 1) 探测设备"
JB="$(S '[ -d /var/jb ] && echo /var/jb' | tr -d '\r')"
LAUNCHER="$JB/usr/local/bin/dsh-ios"
HOME_DIR="/var/mobile/Library/dsh"
NODE="${NODE_BIN:-}"
[ -n "$NODE" ] || NODE="$(S "sed -n 's|.*exec \\\"\\?\\([^ \\\"]*node\\)\\\"\\?.*|\\1|p' $LAUNCHER 2>/dev/null | head -1" | tr -d '\r')"
[ -n "$NODE" ] || NODE="/var/jb/usr/bin/node"
echo "   越狱前缀: ${JB:-/（rootful）}"
echo "   node: $NODE"
S "[ -x '$NODE' ]" || { echo "设备上找不到 $NODE"; exit 1; }

echo "== 2) 上传并替换（先备份）"
SCP "$NEW" "$DEVICE:/tmp/node-new" >/dev/null
SCP "$HERE/../build/entitlements.plist" "$DEVICE:/tmp/ent.plist" >/dev/null
S "NODE='$NODE' sh -c '
set -e
bak=\"\$NODE.bak-\$(date +%Y%m%d-%H%M%S)\"
cp -p \"\$NODE\" \"\$bak\"
echo \"  备份: \$bak\"
chmod 755 /tmp/node-new
if command -v ldid >/dev/null 2>&1; then ldid -S/tmp/ent.plist /tmp/node-new; echo \"  ldid 已重签\"; else echo \"  ! 没有 ldid，跳过签名\"; fi
mv -f /tmp/node-new \"\$NODE\"
chmod 755 \"\$NODE\"
'" 2>&1 | sed 's/^/   /'

echo "== 3) 重写启动器（--jitless + --expose-internals）"
S "NODE='$NODE' HOME_DIR='$HOME_DIR' sh -c '
cat > $LAUNCHER <<EOF
#!/bin/sh
export DSH_HOME=\"\$HOME_DIR\"
exec \"\$NODE\" --jitless --expose-internals --max-old-space-size=2048 --experimental-sqlite \\
  \"\$HOME_DIR/app/node_modules/@deepseek-ai/dsh/lib/bin.js\" \"\\\$@\"
EOF
chmod 755 $LAUNCHER
cat $LAUNCHER
'" 2>&1 | sed 's/^/   /'

echo "== 4) 重启守护进程"
S "$SUDO launchctl kickstart -k system/com.dsh.engine" 2>/dev/null \
  || S "$SUDO sh -c 'launchctl bootout system $JB/Library/LaunchDaemons/com.dsh.engine.plist 2>/dev/null || true; launchctl bootstrap system $JB/Library/LaunchDaemons/com.dsh.engine.plist'" 2>/dev/null || true
sleep 8
S "tail -6 /var/mobile/Library/Logs/dsh-engine.log 2>/dev/null" | sed 's/^/   /' | cut -c1-170 || true

if [ "$DO_ACCEPT" = "1" ]; then
  echo "== 5) 四条验收"
  DEVICE="$DEVICE" SSHPASS="${SSHPASS:-}" NODE_BIN="$NODE" bash "$HERE/accept-device.sh"
fi
