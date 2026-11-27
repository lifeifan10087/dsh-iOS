#!/var/jb/bin/sh
# 让 dsh-purge 能在本机的 dsh 0.2.2-rc.1 上跑（幂等）。
#
# 问题：插件的 bundle 补丁和 lib/identity.js 都用 {{cwd}} 拼提示词，而这个版本的
# dsh 只注册了 {{provider}} / {{model}} 两个变量 → 每轮对话直接
#   Internal error: turn failed: unknown prompt variable "{{cwd}}" in section "deployment:persona-suffix"
#
# 处理：
#   1) node_modules/dsh-purge/cordis.patch.yml 里的 personaSuffix 改成空串
#   2) lib/identity.js 里的 {{cwd}} 换成字面量 "the session workspace"
# 注意：pnpm 重装插件会覆盖这些改动，重装后要再跑一次本脚本。
set -u
DSH_HOME="${DSH_HOME:-/var/mobile/Library/dsh}"
n=0
for d in "$DSH_HOME"/profiles/*/node_modules/dsh-purge; do
  [ -d "$d" ] || continue
  yml="$d/cordis.patch.yml"
  if [ -f "$yml" ] && grep -q "{{cwd}}" "$yml" 2>/dev/null; then
    sed -i.bak 's|personaSuffix: Your working directory is {{cwd}}\.|personaSuffix: ""|' "$yml"
    echo "patch yml: $yml"
    n=$((n+1))
  fi
  js="$d/lib/identity.js"
  if [ -f "$js" ] && grep -q "{{cwd}}" "$js" 2>/dev/null; then
    sed -i.bak 's/{{cwd}}/the session workspace/g' "$js"
    echo "patch js:  $js"
    n=$((n+1))
  fi
done
echo "共处理 $n 处（0 表示已经打过）"
