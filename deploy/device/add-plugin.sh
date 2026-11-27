#!/var/jb/bin/sh
# 往 dsh profile 里装/删插件：绕开 `dsh plugin`（它 spawn("pnpm") 在 iOS 上 EPERM），
# 直接在同目录跑 pnpm。用法：
#   add-plugin.sh web add <包名> [更多参数]
#   add-plugin.sh web remove <包名>
#   add-plugin.sh web ls
set -e
PROFILE="${1:?用法: add-plugin.sh <profile> <pnpm 子命令> [参数...]}"
shift
export DSH_HOME="${DSH_HOME:-/var/mobile/Library/dsh}"
DIR="$DSH_HOME/profiles/$PROFILE"
[ -d "$DIR" ] || { echo "没有这个 profile: $DIR"; exit 1; }
export PATH="/var/jb/usr/bin:/var/jb/usr/local/bin:/usr/bin:/bin"
cd "$DIR"
echo "== pnpm $*（cwd=$DIR）"
exec pnpm --reporter=append-only "$@"
