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
# 关键：不设 DSH_HOME 时 dsh 按 $HOME/.dsh 解析，rootless 下变成 /var/jb/var/root/.dsh，
# 于是 profiles/ 与 node_modules 全指向另一个空目录 —— 表现为「插件装了但没生效」。
export DSH_HOME=/var/mobile/Library/dsh
# launchd 的作业（sshd / 本引擎）Program 都写的是 /var/jb/bin/sh，而这个文件在
# 某些清理后不存在 → 作业直接 EX_CONFIG 78，重启后 SSH 与引擎全起不来。
# 这里兜底建好链接（幂等，不需要 root：目标可读即可）。
[ -e /var/jb/bin/sh ] || ln -sfn /var/jb/usr/bin/dash /var/jb/bin/sh 2>/dev/null

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
# profile 自带的 cordis.patch.yml 在这台机器上没有生效（--dump-config 不含用户层，
# 实测启动后插件路由 404），所以把补丁文件显式作为 --patch 层传进去。
PATCHF=/var/mobile/Library/dsh/profiles/web/cordis.patch.yml
PATCHARG=""
[ -f "$PATCHF" ] && PATCHARG="--patch $PATCHF"
nohup "$NODE" --jitless --max-old-space-size=1024 --require "$PRE" --expose-internals \
  --experimental-sqlite "$APP" --profile web $PATCHARG --host 127.0.0.1 --port 3080 --no-open >>"$LOG" 2>&1 &
echo $! > "$PIDF"

# 本地反向代理：固定 127.0.0.1:3081，替宿主 App 跟引擎换 cookie（token 每次启动都变）
PROXY=/var/jb/usr/local/lib/dsh/mcp/auth-proxy.mjs
if [ -f "$PROXY" ]; then
  ps -A -o args 2>/dev/null | grep -q "[a]uth-proxy.mjs" || \
    nohup "$NODE" --jitless --require "$PRE" "$PROXY" > /var/mobile/Library/dsh/proxy.log 2>&1 &
fi
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
      # TrollStore 装的宿主 App 是沙盒的，读不到上面两个路径 —— 直接把 token 写进它的
      # 数据容器（按 bundle id 找），这样重开 App 就能自己跟上新 token。
      for meta in /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist; do
        [ -f "$meta" ] || continue
        grep -q 'dsh.go.shell' "$meta" 2>/dev/null || continue
        d=$(dirname "$meta")
        mkdir -p "$d/Documents" 2>/dev/null
        printf '%s\n' "$U" > "$d/Documents/dsh-url.txt" 2>/dev/null && \
          chown mobile:mobile "$d/Documents/dsh-url.txt" 2>/dev/null
      done
      break
    fi
    i=$((i+1)); sleep 2
  done
) &
exit 0
