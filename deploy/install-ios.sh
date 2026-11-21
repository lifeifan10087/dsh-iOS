#!/usr/bin/env bash
# 从 Mac 部署到越狱 iPhone（默认 root@设备:22，OpenSSH/dropbear 均可）
# 用法: DEVICE=root@192.168.1.20 bash deploy/install-ios.sh out/node-ios-arm64
set -euo pipefail
DEVICE="${DEVICE:?DEVICE=root@<iphone-ip>}"
NODE_LOCAL="${1:?本地 node-ios-arm64 路径}"
KIT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-22}"

# 有 SSHPASS 就走密码（越狱机默认 root/alpine），否则用密钥
if [ -n "${SSHPASS:-}" ]; then
  SSHPASS_BIN="$(command -v sshpass || true)"
  [ -n "$SSHPASS_BIN" ] || { echo "需要 sshpass：apt install sshpass"; exit 1; }
  sshx() { sshpass -p "$SSHPASS" ssh -p "$PORT" -o StrictHostKeyChecking=no "$@"; }
  scpx() { sshpass -p "$SSHPASS" scp -P "$PORT" -o StrictHostKeyChecking=no "$@"; }
else
  sshx() { ssh -p "$PORT" "$@"; }
  scpx() { scp -P "$PORT" "$@"; }
fi

JB="$(sshx "$DEVICE" '[ -d /var/jb ] && echo /var/jb' || true)"
REMOTE_NODE="$JB/usr/bin/node"
REMOTE_HOME="/var/mobile/Library/dsh"
echo "设备: $DEVICE | 越狱前缀: ${JB:-/(rootful)}"

echo "== 1) 推 node + entitlements 并签名"
scpx "$NODE_LOCAL" "$DEVICE:/tmp/node-ios"
scpx "$KIT/build/entitlements.plist" "$DEVICE:/tmp/ent-dsh.plist"
sshx "$DEVICE" "set -e
  mkdir -p $JB/usr/bin
  mv /tmp/node-ios $REMOTE_NODE && chmod 755 $REMOTE_NODE
  if command -v ldid >/dev/null; then ldid -S/tmp/ent-dsh.plist $REMOTE_NODE; echo 'ldid 已签名'; else echo '无 ldid，跳过签名'; fi"

echo "== 2) 推移植包 + 依赖包"
tar -C "$KIT" -czf /tmp/ios-port.tgz --exclude .git --exclude out .
scpx /tmp/ios-port.tgz "$DEVICE:/tmp/"
MATS="$KIT/out/node_modules.tgz"
if [ -f "$MATS" ]; then scpx "$MATS" "$DEVICE:/tmp/node_modules.tgz"; else echo "  （没找到 ${MATS}，设备上需要有 npm 才能自己装）"; fi
sshx "$DEVICE" "mkdir -p /tmp/ios-port && tar -C /tmp/ios-port -xzf /tmp/ios-port.tgz"

echo "== 3) 设备内初始化（装引擎+替身+launchd）"
sshx "$DEVICE" "NODE_BIN=$REMOTE_NODE bash /tmp/ios-port/scripts/ios-init.sh"

echo "== 4) 验收"
sshx "$DEVICE" "$REMOTE_NODE -p 'process.platform + \"/\" + process.arch + \" node \" + process.versions.node'"
sshx "$DEVICE" "grep -oE 'http://127\\.0\\.0\\.1:3080/\\?token=[A-Za-z0-9_-]+' $REMOTE_HOME/../Logs/dsh-engine.log | tail -1 || echo '没拿到 token，看日志'"
