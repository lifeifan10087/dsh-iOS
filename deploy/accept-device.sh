#!/usr/bin/env bash
# 设备侧验收：四条硬指标（platform=darwin / Unicode / node:sqlite / 401+token）一次跑完。
# 用法: source .secrets.env && bash deploy/accept-device.sh
#       DEVICE=mobile@1.2.3.4 SSHPASS=xxx bash deploy/accept-device.sh
# 依赖: 本机 sshpass；设备上有 node（路径自动探测，也可 NODE_BIN=... 指定）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

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

pass=0; fail=0
ok() { echo "  ✓ $1"; pass=$((pass+1)); }
no() { echo "  ✗ $1"; fail=$((fail+1)); }

echo "== 0) 连通性"
if ! S 'echo ok' >/dev/null 2>&1; then
  no "SSH 不通 $DEVICE"
  echo "  本机出口 IP: $(python3 -c 'import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(("8.8.8.8",80));print(s.getsockname()[0])' 2>/dev/null || echo '?')"
  echo "  （手机不在同一网段时无法继续；回到 192.168.10.x 再跑）"
  exit 1
fi
ok "SSH 可达 $DEVICE"

JB="$(S '[ -d /var/jb ] && echo /var/jb' 2>/dev/null | tr -d '\r')"
LAUNCHER="$JB/usr/local/bin/dsh-ios"
HOME_DIR="/var/mobile/Library/dsh"
LOG="/var/mobile/Library/Logs/dsh-engine.log"

NODE="${NODE_BIN:-}"
if [ -z "$NODE" ]; then
  NODE="$(S "sed -n 's|.*exec \\\"\\?\\([^ \\\"]*node\\)\\\"\\?.*|\\1|p' $LAUNCHER 2>/dev/null | head -1" | tr -d '\r')"
fi
[ -n "$NODE" ] || NODE="/var/jb/usr/bin/node"
S "[ -x '$NODE' ]" 2>/dev/null && ok "node: $NODE" || { no "node 不存在: $NODE"; exit 1; }
echo "  · 越狱前缀: ${JB:-/（rootful）}  启动器: $LAUNCHER"

echo "== 1) 重启引擎"
S "echo \$SSHPASS | sudo -S -p '' launchctl kickstart -k system/com.dsh.engine" >/dev/null 2>&1 \
  && echo "  · kickstart 已发出" || echo "  · kickstart 失败（引擎可能没装）"
sleep 6

echo "== 2) 上传探针并执行"
SCP "$HERE/accept-device.mjs" "$DEVICE:/tmp/dsh-accept.mjs" >/dev/null 2>&1 || { no "探针上传失败"; exit 1; }
URL="$(S "cat $HOME_DIR/.web-url 2>/dev/null || grep -oE 'http://127\\.0\\.0\\.1:3080/\\?token=[A-Za-z0-9_-]+' $LOG 2>/dev/null | tail -1" | tr -d '\r' | tail -1)"
[ -n "$URL" ] && echo "  · 拿到 token 地址（长度 ${#URL}）" || echo "  · 没找到 token 地址"
RAW="$(S "echo \$SSHPASS | sudo -S -p '' env DSH_URL='$URL' '$NODE' --jitless --experimental-sqlite /tmp/dsh-accept.mjs" 2>/dev/null | tr -d '\r' | tail -1)"
echo "  · 原始输出: ${RAW:0:400}"

python3 - "$RAW" <<'PY'
import json, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except Exception:
    print("  ✗ 探针没有返回 JSON（node 可能在启动时就崩了）")
    sys.exit(1)
checks = []
def c(name, cond, detail=""):
    checks.append((name, bool(cond), detail))
ver = d.get("node", "0.0.0").split(".")
try: vok = (int(ver[0]), int(ver[1])) >= (22, 20)
except Exception: vok = False
c("node ≥ v22.20", vok, d.get("node", ""))
c("platform 谎报 darwin", d.get("shimPlatform") == "darwin/arm64", f"{d.get('shimPlatform')} / 原生 {d.get('nativePlatform')}/{d.get('nativeArch')}")
c("Unicode \\p{ID_Continue}", d.get("unicode") == "ok", str(d.get("unicode")))
c("node:sqlite", d.get("sqlite") == "ok", str(d.get("sqlite")))
root = d.get("root") or {}
c("GET / 返回 401", root.get("status") == 401, f"status={root.get('status')} err={root.get('error')}")
tok = d.get("token") or {}
c("token 能打开界面", tok.get("status") == 200 and (tok.get("bytes") or 0) > 1000, json.dumps(tok, ensure_ascii=False))
p, f = 0, 0
for name, happened, detail in checks:
    print(f"  {'✓' if happened else '✗'} {name}  ({detail})")
    p, f = (p + 1, f) if happened else (p, f + 1)
print(f"\n小计: {p} 通过, {f} 失败")
sys.exit(0 if f == 0 else 1)
PY
rc=$?

echo "== 3) 日志尾部"
S "tail -8 $LOG 2>/dev/null" | sed 's/^/    /' | cut -c1-180

echo
if [ "$rc" -eq 0 ]; then echo "验收: 全通过"; else echo "验收: 有失败项（见上）"; fi
exit "$rc"
