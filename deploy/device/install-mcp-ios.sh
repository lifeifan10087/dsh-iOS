#!/bin/sh
# 装 iOS MCP server（stdio）并注册到 web profile。幂等。
set -e
JB=/var/jb
DEST="$JB/usr/local/lib/dsh/mcp"
DSH_HOME=/var/mobile/Library/dsh
PATCH="$DSH_HOME/profiles/web/cordis.patch.yml"

mkdir -p "$DEST"
cp /tmp/mcp-ios-server.mjs "$DEST/mcp-ios-server.mjs"
chmod 644 "$DEST/mcp-ios-server.mjs"

touch "$PATCH"
if ! grep -q "mcp-ios" "$PATCH" 2>/dev/null; then
  cat >> "$PATCH" <<'EOF'

# iOS 侧手机操控（stdio MCP server）
- id: mcp-ios
  name: "@deepseek-ai/dsh-mcp-client"
  config:
    transport: stdio
    serverName: ios
    command: /var/jb/usr/local/lib/dsh/node
    args:
      - --jitless
      - --require
      - /var/mobile/Library/dsh/shim/ios-preload.cjs
      - /var/jb/usr/local/lib/dsh/mcp/mcp-ios-server.mjs
    cwd: /var/mobile/Library/dsh
    failOnStartupError: false
EOF
  echo "已写入 mcp-ios 到 $PATCH"
else
  echo "mcp-ios 已存在，跳过"
fi

echo "== 自检：直接用 node 跑一次 tools/list"
printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | "$JB/usr/local/lib/dsh/node" --jitless --require "$DSH_HOME/shim/ios-preload.cjs" "$DEST/mcp-ios-server.mjs" 2>/dev/null \
  | tail -1 | cut -c1-200
