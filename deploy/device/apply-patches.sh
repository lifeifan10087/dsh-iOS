#!/var/jb/bin/sh
# apply-patches.sh —— 把所有「本机魔改」一次性、幂等地补齐（以 root 运行）
#
# 为什么需要它：iOS 上有若干必须改的地方（sh 路径、osascript、DSH_HOME、插件配置…），
# 这些改动直接落在 node_modules / profiles 里，**重装或升级就被覆盖**，
# 于是「昨天还好好的，今天插件失效/不能执行命令」。
# 由 deb 的 postinst 调用，也可以在升级后手动跑一遍。
#
# 用法：apply-patches.sh [--quiet]
set -u
Q=0; [ "${1:-}" = "--quiet" ] && Q=1
say() { [ "$Q" = 1 ] || echo "$@"; }

H=${DSH_HOME:-/var/mobile/Library/dsh}
APP=$H/app/node_modules
JB=/var/jb
NODE=$JB/usr/local/lib/dsh/node
MCPD=$JB/usr/local/lib/dsh/mcp
KIT=$JB/usr/local/lib/dsh          # deb 里这些资源放这里
changed=0

# —— 1) /var/jb/bin/sh（launchd 作业的 Program，缺了所有守护进程 EX_CONFIG 78）——
if [ ! -e "$JB/bin/sh" ]; then
  mkdir -p "$JB/bin"
  ln -sfn "$JB/usr/bin/dash" "$JB/bin/sh"
  say "  + /var/jb/bin/sh -> dash"; changed=$((changed+1))
fi

# —— 2) dsh 里写死的 /bin/sh、/bin/bash → 越狱路径（iOS 没有 /bin/sh）——
for f in \
  "$APP/@deepseek-ai/dsh-subprocess-local/lib/runner.js" \
  "$APP/@deepseek-ai/dsh-api-terminal-controller/lib/index.js" \
  "$APP/@deepseek-ai/dsh-terminal-bash/lib/index.js" ; do
  [ -f "$f" ] || continue
  if grep -q '"/bin/\(sh\|bash\)"' "$f" 2>/dev/null; then
    cp -f "$f" "$f.debpatch.bak" 2>/dev/null || true
    sed -i '' 's|"/bin/sh"|"/var/jb/bin/sh"|g; s|"/bin/bash"|"/var/jb/bin/bash"|g' "$f" 2>/dev/null || \
      sed -i 's|"/bin/sh"|"/var/jb/bin/sh"|g; s|"/bin/bash"|"/var/jb/bin/bash"|g' "$f"
    say "  + shell 路径: $(basename "$(dirname "$(dirname "$f")")")"; changed=$((changed+1))
  fi
done

# —— 3) dsh-purge：{{cwd}} 会让每轮对话报 unknown prompt variable ——
for d in "$H"/profiles/*/node_modules/dsh-purge; do
  [ -d "$d" ] || continue
  y="$d/cordis.patch.yml"; j="$d/lib/identity.js"
  if [ -f "$y" ] && grep -q '{{cwd}}' "$y" 2>/dev/null; then
    cp -f "$y" "$y.debpatch.bak" 2>/dev/null || true
    sed -i '' 's|personaSuffix: Your working directory is {{cwd}}\.|personaSuffix: ""|' "$y" 2>/dev/null || \
      sed -i 's|personaSuffix: Your working directory is {{cwd}}\.|personaSuffix: ""|' "$y"
    say "  + purge 补丁: $(basename "$(dirname "$d")")"; changed=$((changed+1))
  fi
  if [ -f "$j" ] && grep -q '{{cwd}}' "$j" 2>/dev/null; then
    cp -f "$j" "$j.debpatch.bak" 2>/dev/null || true
    sed -i '' 's/{{cwd}}/the session workspace/g' "$j" 2>/dev/null || \
      sed -i 's/{{cwd}}/the session workspace/g' "$j"
    say "  + purge identity.js 已改"; changed=$((changed+1))
  fi
done

# —— 4) osascript 替身（Mach-O；iOS 没有 AppleScript，脚本形式会被 node 以 EPERM 拒绝）——
# 注意：ldid 重签会让字节每次都变，所以幂等判断用「源文件指纹」而不是比对成品
STAMP=$H/.apply-patches.osascript
for src in "$KIT/osascript-ios-arm64" "$KIT/bin/osascript-ios-arm64" "$H/osascript-ios-arm64"; do
  [ -f "$src" ] || continue
  SUM=$(cksum < "$src" 2>/dev/null)
  if [ ! -x "$JB/usr/bin/osascript" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$SUM" ]; then
    cp -f "$src" "$JB/usr/bin/osascript"; chmod 755 "$JB/usr/bin/osascript"
    ldid -S "$JB/usr/bin/osascript" 2>/dev/null || true
    printf '%s' "$SUM" > "$STAMP"
    say "  + osascript 替身已装"; changed=$((changed+1))
  fi
  break
done

# —— 5) root MCP 与固定入口代理 ——
mkdir -p "$MCPD"
for pair in "mcp-ios-server.mjs:mcp-ios-server.mjs" "auth-proxy.mjs:auth-proxy.mjs"; do
  from=${pair%%:*}; to=${pair##*:}
  for src in "$KIT/bin/$from" "$KIT/$from" "$H/$from"; do
    [ -f "$src" ] || continue
    if ! cmp -s "$src" "$MCPD/$to" 2>/dev/null; then
      cp -f "$src" "$MCPD/$to"; chmod 755 "$MCPD/$to"
      say "  + $to 已更新"; changed=$((changed+1))
    fi
    break
  done
done

# —— 6) profile 补丁层（MCP + dsh-purge 的 insert 定义）——
for p in web acp; do
  d=$H/profiles/$p; [ -d "$d" ] || continue
  src=""
  for c in "$KIT/profile-patch.yml" "$KIT/bin/profile-patch.yml" "$H/profile-patch.yml"; do
    [ -f "$c" ] && { src=$c; break; }
  done
  [ -n "$src" ] || continue
  if ! cmp -s "$src" "$d/cordis.patch.yml" 2>/dev/null; then
    [ -f "$d/cordis.patch.yml" ] && cp -f "$d/cordis.patch.yml" "$d/cordis.patch.yml.pre-deb" 2>/dev/null
    cp -f "$src" "$d/cordis.patch.yml"; chmod 644 "$d/cordis.patch.yml"
    say "  + profile 补丁层: $p"; changed=$((changed+1))
  fi
done

# —— 7) boot-start 必须有 DSH_HOME 与越狱 PATH ——
BS=$H/boot-start.sh
if [ -f "$BS" ]; then
  if ! grep -q 'export DSH_HOME' "$BS" 2>/dev/null; then
    sed -i '' '1a\
export DSH_HOME=/var/mobile/Library/dsh\
export PATH="/var/jb/usr/bin:/var/jb/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
' "$BS" 2>/dev/null || true
    say "  + boot-start 补 DSH_HOME/PATH"; changed=$((changed+1))
  fi
fi

# —— 8) 终端功能：node-pty 在 iOS 上 spawn 成功但收不到任何输出（实测三次），
#        交互终端不可用，保留 run_command 作为替代。这里只记录，不改配置。——
# —— 9) 「在文件夹中显示」在 iOS 上必失败（原实现用 macOS 的 open -R）——
#     改成走「文件」App 深链；工作区文件先复制进宿主 App 容器再跳过去。
PATCH_SRC=$KIT/bin/patch-reveal-ios.mjs
for c in "$PATCH_SRC" "$H/patch-reveal-ios.mjs" "$KIT/patch-reveal-ios.mjs"; do
  [ -f "$c" ] || continue
  "$NODE" --jitless "$c" 2>/dev/null | sed 's/^/  /' || true
  break
done

say "  · node-pty: 不可用（已实测），终端面板不建议开启"

say "apply-patches: $changed 处改动"
exit 0
