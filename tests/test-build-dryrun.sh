#!/usr/bin/env bash
# 干跑 build-node-ios.sh：用假工具链走完整控制流，抓脚本级 bug（未定义变量、目录未建）
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP=$(mktemp -d)
export PATH="$ROOT/tests/dryrun/bin:$PATH"
export WORK="$TMP/work" OUT="$TMP/out"

mkdir -p "$WORK/node"
cat > "$WORK/node/configure" <<'EOF'
#!/bin/sh
# 造出 configure 后应有的输出
mkdir -p out
cat > config.gypi <<'GI'
{"variables":{}}
GI
exit 0
EOF
chmod +x "$WORK/node/configure"

echo "== 干跑 build-node-ios.sh"
set +e
bash build/build-node-ios.sh >"$TMP/log" 2>&1
rc=$?
set -e
tail -20 "$TMP/log"
echo "退出码: $rc"
if [ $rc -eq 0 ] && grep -q "产物" "$TMP/log"; then
  echo "  ✓ 控制流跑通"
  rc=0
else
  echo "  ✗ 脚本在干跑中失败（见上面日志）"
  rc=1
fi
rm -rf "$TMP"
exit $rc
