#!/usr/bin/env bash
# 无 macOS 也能跑的单元测试：验证三个补丁脚本的行为
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok(){ echo "  ✓ $1"; pass=$((pass+1)); }
no(){ echo "  ✗ $1"; fail=$((fail+1)); }

echo "[1] patch-host-mk.py：iOS 标志应被换成 macOS"
tmp=$(mktemp -d); mkdir -p "$tmp/out"
cp tests/fixtures/sample.host.mk "$tmp/out/node_js2c.host.mk"
python3 build/patch-host-mk.py "$tmp/out" "/SDK/MacOSX.sdk" node_js2c >/dev/null
grep -q "iPhoneOS" "$tmp/out/node_js2c.host.mk" && no "仍残留 iPhoneOS 路径" || ok "iPhoneOS 路径已清除"
grep -q "arm64-apple-ios" "$tmp/out/node_js2c.host.mk" && no "仍残留 iOS 三元组" || ok "三元组已改为 macOS"
grep -q "clang++" "$tmp/out/node_js2c.host.mk" && ok "编译器已换回 clang++" || no "编译器没换"
grep -q "mmacosx-version-min" "$tmp/out/node_js2c.host.mk" && ok "版本标记已改为 macOS" || no "版本标记没改"
rm -rf "$tmp"

echo "[2] patch-macho-ios.py：Mach-O 平台号改成 iOS"
bin=$(find /tmp/bundle/node_modules -name "koffi.node" 2>/dev/null | head -1)
if [ -n "$bin" ]; then
  cp "$bin" /tmp/t.node
  python3 build/patch-macho-ios.py /tmp/t.node 14.0 18.0 >/dev/null
  plat=$(python3 - <<'PY'
import struct
b=open('/tmp/t.node','rb').read(4096)
n=struct.unpack_from('<I',b,16)[0]; p=32
for _ in range(n):
    c,s=struct.unpack_from('<II',b,p)
    if c==0x32:
        print(struct.unpack_from('<I',b,p+8)[0]); break
    p+=s
PY
)
  [ "$plat" = "2" ] && ok "platform=2 (iOS)" || no "platform=$plat"
else
  echo "  - 跳过（没有 darwin 二进制样本）"
fi

echo "[3] apply-shim.sh：原生 addon 被换成 JS 替身"
tmp=$(mktemp -d); mkdir -p "$tmp/node_modules/node-addon-require-builtin/lib"
echo 'module.exports={requireBuiltin(){throw new Error("native")}}' > "$tmp/node_modules/node-addon-require-builtin/lib/index.js"
bash shim/apply-shim.sh "$tmp/node_modules" >/dev/null
grep -q "expose-internals" "$tmp/node_modules/node-addon-require-builtin/lib/index.js" && ok "替身已就位" || no "替身没装上"
[ -f "$tmp/node_modules/node-addon-require-builtin/lib/index.js.orig" ] && ok "留有回滚副本" || no "没有回滚副本"
rm -rf "$tmp"

echo "[4] skip-generated.py：能创建 intermediate 戳"
tmp=$(mktemp -d); mkdir -p "$tmp/out/Release/obj/gen"; echo x > "$tmp/out/Release/obj/gen/a.cc"
printf 'rule: f85f.intermediate\n' > "$tmp/out/node.target.mk"
python3 build/skip-generated.py "$tmp/out" >/dev/null
[ -f "$tmp/out/f85f.intermediate" ] && ok "戳已创建" || no "戳没创建"
rm -rf "$tmp"

echo "[5] 引擎 API 版本要求核对"
grep -rq "parseEnv" /opt/dsh/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js && ok "确认用到 util.parseEnv（需 Node ≥20.12）" || echo "  - 未检出 parseEnv"

echo "[6] build-node-ios.sh 干跑（假工具链）"
if bash tests/test-build-dryrun.sh >/tmp/dryrun.out 2>&1; then ok "控制流跑通"; else no "干跑失败（见 /tmp/dryrun.out）"; fi

echo
echo "结果：通过 $pass，失败 $fail"
[ "$fail" -eq 0 ]
