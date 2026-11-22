#!/usr/bin/env bash
# 在 iPhone 上装 ios-mcp（越狱 MCP 服务）并接进 dsh —— 全程走 SSH，零代码改动。
# 依赖：deploy/ 目录同级的 ios-mcp deb，或指定路径。
# 用法: SSHPASS=xxx DEVICE=mobile@192.168.10.229 bash deploy/enable-ios-mcp.sh [deb路径]
set -euo pipefail
DEVICE="${DEVICE:?DEVICE=mobile@<ip>}"
DEB="${1:-/tmp/ios-mcp.deb}"
KIT="$(cd "$(dirname "$0")/.." && pwd)"
S() { sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$DEVICE" "$@"; }
SCP() { sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"; }
ROOT() { S "echo \$SSHPASS | sudo -S -p '' sh -c \"$1\""; }

[ -f "$DEB" ] || { echo "找不到 $DEB（从 https://github.com/witchan/ios-mcp/releases 下 iphoneos-arm64 版）"; exit 1; }

echo "== 1) 上传并安装 ios-mcp"
SCP "$DEB" "$DEVICE:/tmp/ios-mcp.deb"
ROOT "/var/jb/usr/bin/dpkg -i /tmp/ios-mcp.deb || /var/jb/usr/bin/dpkg -i /tmp/ios-mcp.deb"

echo "== 2) 健康检查（关键一步）"
for i in 1 2 3 4 5; do
  H="$(S "curl -s -m 3 http://127.0.0.1:8090/health || true" 2>/dev/null || true)"
  if printf '%s' "$H" | grep -q '"status":"ok"'; then
    echo "   ✅ MCP 服务活着: $H"; break
  fi
  echo "   第 $i 次没通，等 3 秒…"; sleep 3
done
printf '%s' "$H" | grep -q '"status":"ok"' || { echo "   ❌ 8090 没响应：可能是 iOS 版本不兼容或服务没启动"; exit 2; }

echo "== 3) 接进 dsh（cordis.patch.yml 追加一条 MCP 配置）"
S "P=/var/mobile/Library/dsh/profiles/web/cordis.patch.yml
mkdir -p \$(dirname \$P); touch \$P
if grep -q 'serverName: ios' \$P 2>/dev/null; then
  echo '   已经有 ios 的 MCP 配置，跳过'
else
  cat >> \$P <<'YAML'

- id: mcp-ios
  name: \"@deepseek-ai/dsh-mcp-client\"
  config:
    transport: streamable-http
    serverName: ios
    url: http://127.0.0.1:8090/mcp
    reconnect:
      enabled: true
YAML
  echo '   已追加 mcp-ios 配置'
fi"

echo "== 4) 重启引擎"
ROOT "launchctl bootout system /var/jb/Library/LaunchDaemons/com.dsh.engine.plist 2>/dev/null || true; launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.dsh.engine.plist 2>/dev/null || launchctl load /var/jb/Library/LaunchDaemons/com.dsh.engine.plist || true"
sleep 6

echo "== 5) 看引擎有没有报错"
S "tail -20 /var/mobile/Library/Logs/dsh-engine.log 2>/dev/null | tail -15"
echo
echo "工具名会是 mcp__ios__<tool>，例如 mcp__ios__tap_screen / mcp__ios__screenshot / mcp__ios__get_ui_elements"
