#!/bin/sh
# 由 launchd 作业 com.dsh.bootstrap 调用：把引擎 nohup 出去后立刻退出。
# 关键点：作业自己的进程受 jetsam per-process 限额（dsh 常驻 ~250MB，一超就被杀），
# 但 nohup 出去、ppid 变成 1 的子进程不受该限额约束 —— 这是唯一能跑起来的起法。
NODE=/var/jb/usr/local/lib/dsh/node
# shim 可能在两处：手动部署放的 DSH_HOME/shim，或 deb 装的 lib/dsh/shim
PRE=/var/mobile/Library/dsh/shim/ios-preload.cjs
[ -f "$PRE" ] || PRE=/var/jb/usr/local/lib/dsh/shim/ios-preload.cjs
APP=/var/mobile/Library/dsh/app/node_modules/@deepseek-ai/dsh/lib/bin.js
LOG=/var/mobile/Library/Logs/dsh-engine.log

# launchd 默认 PATH 不含 /var/jb/usr/bin，导致引擎 spawn osascript/zenity 之类一律 ENOENT
# （典型症状：「选择文件夹」报 directory picker failed: spawn osascript ENOENT）
export PATH="/var/jb/usr/bin:/var/jb/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# 模型凭证等环境变量放这里（600），有就用
if [ -f /var/mobile/Library/dsh/env.sh ]; then
  . /var/mobile/Library/dsh/env.sh
  export DEEPSEEK_API_KEY DEEPSEEK_BASE_URL
fi

# 原生 addon 必须先搬到 /var/jb，否则 dlopen 会被沙箱拦（幂等）
[ -x /var/mobile/Library/dsh/relocate-addons.sh ] && sh /var/mobile/Library/dsh/relocate-addons.sh >/dev/null 2>&1

# 幂等判断用 pidfile（`ps` 在设备上会截断参数，grep 不可靠；早期版本因此可能重复拉起多个引擎）
PIDF=/var/mobile/Library/dsh/engine.pid
if [ -f "$PIDF" ]; then
  OLD=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    echo "already running pid=$OLD"
    exit 0
  fi
fi
# ps 在设备上会把命令行截断，所以匹配串只能用靠前的部分（不能用 "dsh/lib/bin.js web"）
if ps -A -o args 2>/dev/null | grep -q "[u]sr/local/lib/dsh/node"; then
  echo "already running (ps match)"
  exit 0
fi

MARK="=== dsh start $(date +%s) ==="
echo "$MARK" >>"$LOG"
nohup "$NODE" --jitless --max-old-space-size=1024 --require "$PRE" --expose-internals \
  --experimental-sqlite "$APP" web --host 127.0.0.1 --port 3080 --no-open >>"$LOG" 2>&1 &
echo $! > "$PIDF"
echo "spawned $!"

# 引擎每次启动都会生成新 token，壳（WKWebView）读的是 .web-url，这里把它同步成最新的。
# 放到后台跑，作业自己马上退出（作业进程不能长时间活着，见文件头说明）。
(
  i=0
  while [ $i -lt 60 ]; do
    # 只看本次启动标记之后的部分，否则会把上一次的旧 token 写进 .web-url
    U="$(sed -n "\|$MARK|,\$p" "$LOG" 2>/dev/null | grep -oE 'http://127\.0\.0\.1:3080/\?token=[A-Za-z0-9_-]+' | tail -1)"
    if [ -n "$U" ]; then
      printf '%s' "$U" > /var/mobile/Library/dsh/.web-url
      printf '%s\n' "$U" > /var/mobile/Documents/dsh-url.txt 2>/dev/null || true
      break
    fi
    i=$((i+1)); sleep 2
  done
) &
exit 0
