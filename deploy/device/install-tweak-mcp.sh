#!/var/jb/bin/sh
# 装 iOS 手机操控 MCP server（com.witchan.ios-mcp 的核心 dylib）+ 验证 8090。
#
# 只用它的核心 dylib（注入 SpringBoard），跳过 installd/frontboard 两个钩子（少风险）。
# 装完必须 respring 一次才生效；respring 过 SSH 不会断（sshd 是独立 daemon）。
# 需要：/tmp/iosmcp-payload/{ios-mcp.dylib,ios-mcp.plist}
set -e
DL=/var/jb/Library/MobileSubstrate/DynamicLibraries
SRC="${1:-/tmp/iosmcp-payload}"
NODE=/var/jb/usr/local/lib/dsh/node
PRE=/var/mobile/Library/dsh/shim/ios-preload.cjs

[ -f "$SRC/ios-mcp.dylib" ] || { echo "没有 $SRC/ios-mcp.dylib"; exit 1; }
mkdir -p "$DL"
cp "$SRC/ios-mcp.dylib" "$DL/ios-mcp.dylib"
cp "$SRC/ios-mcp.plist" "$DL/ios-mcp.plist"
chmod 755 "$DL/ios-mcp.dylib"; chmod 644 "$DL/ios-mcp.plist"
ldid -S "$DL/ios-mcp.dylib" 2>/dev/null || true
echo "dylib 已就位，respring…"
(killall -9 SpringBoard 2>/dev/null || launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null) || true
sleep 15
i=0
while [ $i -lt 10 ]; do
  H=$("$NODE" --jitless --require "$PRE" -e 'fetch("http://127.0.0.1:8090/health").then(async r=>{console.log(r.status);process.exit(0)}).catch(e=>{console.log("ERR");process.exit(0)})' 2>/dev/null | grep -v Warning | tail -1)
  [ "$H" = "200" ] && { echo "8090 /health = 200 ✓"; exit 0; }
  i=$((i+1)); sleep 5
done
echo "8090 没起来（最后结果: $H）"
exit 1
