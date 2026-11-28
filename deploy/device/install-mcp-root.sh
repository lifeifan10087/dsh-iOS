#!/var/jb/bin/sh
# 安装 root 侧 MCP（补 tweak 沙箱做不到的活），并重启引擎让它生效
set -e
SRC="${1:-/tmp/mcp-ios-server.mjs}"
DST=/var/jb/usr/local/lib/dsh/mcp
mkdir -p "$DST"
cp -f "$SRC" "$DST/mcp-ios-server.mjs"
chmod 755 "$DST/mcp-ios-server.mjs"
chown root:wheel "$DST/mcp-ios-server.mjs" 2>/dev/null || true
echo "已装 $DST/mcp-ios-server.mjs ($(wc -c < "$DST/mcp-ios-server.mjs") bytes)"
echo "== 自检：起一个 stdio 会话列工具"
printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
 | /var/jb/usr/local/lib/dsh/node --jitless --require /var/mobile/Library/dsh/shim/ios-preload.cjs "$DST/mcp-ios-server.mjs" 2>/dev/null \
 | /var/jb/usr/local/lib/dsh/node --jitless -e '
let b="";process.stdin.on("data",d=>b+=d);process.stdin.on("end",()=>{
 for (const l of b.split("\n")) { if(!l.trim())continue; try{const m=JSON.parse(l); if(m.id===2) console.log("工具数:", (m.result?.tools||[]).length, "->", (m.result?.tools||[]).map(t=>t.name).join(","))}catch{} }
});'
