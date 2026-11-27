#!/usr/bin/env bash
# 一键把 pnpm + iOS MCP server 部署到设备（需要 SSH 可达）
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.secrets.env; set +a
DEVICE="${DEVICE:-${IPHONE_USER}@${IPHONE_IP}}"
PORT="${PORT:-22}"
SSHOPT=(-p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
        -o ConnectTimeout=25 -o ServerAliveInterval=10
        -o PreferredAuthentications=password -o PubkeyAuthentication=no)
S()   { printf '%s\n' "${SSHPASS:-}" | sshpass -e ssh "${SSHOPT[@]}" "$DEVICE" "sudo -S -p '' $*"; }
SCP() { sshpass -e scp "${SSHOPT[@]/#-p/-P}" "$@"; }

echo "== 1) 上传 pnpm 包、MCP server、安装脚本"
SCP /tmp/pnpm.tgz deploy/device/install-pnpm.sh mcp/mcp-ios-server.mjs deploy/device/install-mcp-ios.sh \
    deploy/device/boot-start.sh deploy/device/start-engine.sh "$DEVICE:/tmp/" >/dev/null

echo "== 2) 装 pnpm"
S 'sh /tmp/install-pnpm.sh /tmp/pnpm.tgz'

echo "== 3) 装 MCP server 并注册"
S 'sh /tmp/install-mcp-ios.sh'

echo "== 4) 更新启动脚本（pidfile 幂等 + relocate-addons）"
S 'cp /tmp/boot-start.sh /var/mobile/Library/dsh/boot-start.sh; chmod 755 /var/mobile/Library/dsh/boot-start.sh'
S 'cp /tmp/start-engine.sh /var/mobile/Library/dsh/start-engine.sh; chmod 755 /var/mobile/Library/dsh/start-engine.sh'

echo "== 5) 重启引擎"
S 'for p in $(ps -A -o pid,args 2>/dev/null | grep "[d]sh/lib/bin.js web" | sed "s/^ *//" | cut -d" " -f1); do kill -9 $p; done; echo killed'

echo "== 6) 等自启（最多 150 秒）后验收"
S 'i=0; while [ $i -lt 30 ]; do R=$(/var/jb/usr/local/lib/dsh/node --jitless --require /var/mobile/Library/dsh/shim/ios-preload.cjs -e "fetch(\"http://127.0.0.1:3080/\").then(async r=>{console.log(r.status);process.exit(0)}).catch(()=>{console.log(\"ERR\");process.exit(0)})" 2>/dev/null | tail -1); [ "$R" = "401" ] && break; i=$((i+1)); sleep 5; done; echo "GET / = $R"'
