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

if ps -A -o args 2>/dev/null | grep -q "[d]sh/lib/bin.js web"; then
  echo "already running"
  exit 0
fi

nohup "$NODE" --jitless --max-old-space-size=1024 --require "$PRE" --expose-internals \
  --experimental-sqlite "$APP" web --host 127.0.0.1 --port 3080 --no-open >>"$LOG" 2>&1 &
echo "spawned $!"
exit 0
