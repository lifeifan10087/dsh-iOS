#!/bin/sh
# start-engine.sh —— 在设备上（或经 SSH）把 dsh 引擎拉起来
#
# 为什么不是 launchd：iOS 给 LaunchDaemon 的 per-process 内存上限低于 dsh 的
# 常驻内存（~280MB），一启动就被 JETSAM_REASON_MEMORY_PERPROCESSLIMIT 杀掉；
# 设备上也没有 cron 可以当看门狗。所以用 nohup 脱离会话运行：
#   · 活得过 SSH 断开（ppid 会变成 1）
#   · 设备重启后要重跑一次本脚本
#
# 用法：sh /var/mobile/Library/dsh/start-engine.sh
set -e

NODE=/var/jb/usr/local/lib/dsh/node
HOME_DIR=/var/mobile/Library/dsh
PRE="$HOME_DIR/shim/ios-preload.cjs"
APP="$HOME_DIR/app/node_modules/@deepseek-ai/dsh/lib/bin.js"
LOG=/var/mobile/Library/Logs/dsh-engine.log

[ -x "$NODE" ] || { echo "找不到 node: $NODE"; exit 1; }
[ -f "$PRE" ] || { echo "找不到 preload: $PRE"; exit 1; }

# 已经在跑就不重复启动（端口只有一份）
if ps -A -o args 2>/dev/null | grep -q "[d]sh/lib/bin.js web"; then
  echo "引擎已在运行："
  ps -A -o pid,rss,args 2>/dev/null | grep "[d]sh/lib/bin.js web" | head -2
else
  mkdir -p "$(dirname "$LOG")"
  nohup "$NODE" --jitless --max-old-space-size=1024 --require "$PRE" \
    --expose-internals --experimental-sqlite "$APP" \
    web --host 127.0.0.1 --port 3080 --no-open >>"$LOG" 2>&1 &
  echo "已启动，等它监听……"
  sleep 12
fi

URL="$(grep -oE 'http://127\.0\.0\.1:3080/\?token=[A-Za-z0-9_-]+' "$LOG" 2>/dev/null | tail -1)"
if [ -n "$URL" ]; then
  printf '%s' "$URL" > "$HOME_DIR/.web-url"
  printf '%s\n' "$URL" > /var/mobile/Documents/dsh-url.txt 2>/dev/null || true
  echo "token 地址已写入 $HOME_DIR/.web-url"
  echo "在「文件」App 里看：/var/mobile/Documents/dsh-url.txt"
else
  echo "还没拿到 token，看看日志：tail -20 $LOG"
fi
