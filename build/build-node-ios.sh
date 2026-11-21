#!/usr/bin/env bash
# 编 Node for iOS/arm64（macOS 上跑）。
#
# 两阶段的原因：Node 的构建过程要跑若干"构建期工具"（node_js2c、torque、
# bytecode_builtins_list_generator…）。交叉编译时它们会被编成 iOS 二进制，
# 在构建机上直接 Killed: 9。所以：
#   阶段A：用 macOS 目标全量编一遍，拿到这些工具 + 生成文件（平台无关）
#   阶段B：切到 iOS 目标，复用阶段A的工具与生成文件，只编真正的目标代码
#
# 用法: NODE_REF=update22-9-0 bash build-node-ios.sh
set -euo pipefail

NODE_VER="${NODE_VER:-v24.9.0}"
NODE_REPO="${NODE_REPO:-https://github.com/nodejs-mobile/nodejs-mobile.git}"
NODE_REF="${NODE_REF:-$NODE_VER}"
DEST_OS="${DEST_OS:-ios}"
WORK="${WORK:-$HOME/node-ios-build}"
OUT="${OUT:-$WORK/out}"
MIN_IOS="${MIN_IOS:-14.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$(uname -s)" = Darwin ] || { echo "必须在 macOS 上跑（需要 iPhoneOS SDK）"; exit 1; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VER="$(xcrun --sdk iphoneos --show-sdk-version)"
echo "SDK $SDK_VER | iOS min $MIN_IOS | 源码 $NODE_REF | jobs $JOBS"

mkdir -p "$WORK" "$OUT"
cd "$WORK"
if [ ! -d node ]; then
  git clone --depth 1 --branch "$NODE_REF" "$NODE_REPO" node
else
  git -C node fetch --depth 1 origin "$NODE_REF" && git -C node checkout -q FETCH_HEAD
fi
cd node

echo "== iOS 兼容头"
mkdir -p "$WORK/compat/sys"
cat > "$WORK/compat/sys/random.h" <<'EOF'
#ifndef DSH_IOS_COMPAT_SYS_RANDOM_H
#define DSH_IOS_COMPAT_SYS_RANDOM_H
#include <sys/types.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
int getentropy(void *buf, size_t buflen);
#ifdef __cplusplus
}
#endif
#endif
EOF

echo "== 注入 iOS gyp 覆盖"
python3 "$HERE/apply-ios-overrides.py" . || true

# ============ 阶段A：macOS 全量构建，拿下构建期工具与生成文件 ============
HOSTTOOLS="node_js2c bytecode_builtins_list_generator torque gen-regexp-special-case"

if [ "${PROBE:-0}" = "2" ]; then
  echo "== PROBE2：跳过阶段A，只做阶段B configure"
  PHASE_A_SKIP=1
fi
if [ -f "$WORK/host/torque" ] && [ -f "$WORK/host/gen.tar.gz" ]; then
  echo "== 阶段A：命中缓存，跳过（已有 torque + gen.tar.gz）"
  PHASE_A_DONE=1
else
  PHASE_A_DONE=0
fi

if [ "$PHASE_A_DONE" = "0" ] && [ "${PHASE_A_SKIP:-0}" = "0" ]; then
echo "== 阶段A：macOS 构建（约 25-40 分钟）"
if ! CC=clang CXX=clang++ ./configure --dest-os=mac --dest-cpu=arm64 \
      --without-intl --without-npm --without-corepack --without-inspector \
      --openssl-no-asm >"$WORK/phaseA.configure.log" 2>&1; then
  echo "阶段A configure 失败"; tail -25 "$WORK/phaseA.configure.log"; exit 1
fi
export CFLAGS="-DHAVE_UNISTD_H=1 -DNGHTTP3_HAVE_UNISTD_H=1 -DNGTCP2_HAVE_UNISTD_H=1"
set +e
make -j"$JOBS" V=0 \
  out/Release/node_js2c out/Release/bytecode_builtins_list_generator \
  out/Release/torque out/Release/gen-regexp-special-case \
  >"$WORK/phaseA.log" 2>&1
rcA=$?
if [ $rcA -ne 0 ]; then
  echo "   只编工具没成功，退回全量构建"
  make -j"$JOBS" V=0 >>"$WORK/phaseA.log" 2>&1
  rcA=$?
fi
set -e
unset CFLAGS
if [ $rcA -ne 0 ]; then
  echo "阶段A 编译失败："; tail -40 "$WORK/phaseA.log"; exit 1
fi

mkdir -p "$WORK/host"
for t in $HOSTTOOLS; do
  [ -x "out/Release/$t" ] && cp -f "out/Release/$t" "$WORK/host/$t" && echo "   工具 $t ✓"
done
tar -C out/Release -czf "$WORK/host/gen.tar.gz" obj/gen 2>/dev/null || true
ls -lh "$WORK/host" | tail -6
rm -rf out
fi

# ============ 阶段B：iOS 目标 ============
echo "== 阶段B：iOS 目标构建"
TARGET="arm64-apple-ios${MIN_IOS}"
mkdir -p "$WORK/bin"
# 包装器按输出路径判断：写进 obj.host/ 的（构建期工具）用 macOS 编译器，
# 其余（真正的目标代码）才加上 iOS 三元组。这样不用猜 gyp 生成哪些 host makefile。
cat > "$WORK/bin/ios-cc" <<EOF
#!/bin/sh
case "\$*" in
  *obj.host/*|*lib.host/*) exec xcrun --sdk macosx clang "\$@" ;;
  *) exec xcrun -sdk iphoneos clang -target $TARGET -isysroot $SDK -I$WORK/compat -O1 "\$@" ;;
esac
EOF
cat > "$WORK/bin/ios-cxx" <<EOF
#!/bin/sh
case "\$*" in
  *obj.host/*|*lib.host/*) exec xcrun --sdk macosx clang++ "\$@" ;;
  *) exec xcrun -sdk iphoneos clang++ -target $TARGET -isysroot $SDK -I$WORK/compat -O1 "\$@" ;;
esac
EOF
chmod +x "$WORK/bin/ios-cc" "$WORK/bin/ios-cxx"
export CC="$WORK/bin/ios-cc" CXX="$WORK/bin/ios-cxx"
unset CFLAGS CXXFLAGS LDFLAGS 2>/dev/null || true
export GYP_DEFINES="host_os=mac host_arch=arm64"

if ! ./configure --dest-os="$DEST_OS" --dest-cpu=arm64 --cross-compiling \
      --without-intl --without-npm --without-corepack --without-inspector \
      --openssl-no-asm --prefix="$OUT" >"$WORK/phaseB.configure.log" 2>&1; then
  echo "阶段B configure 失败"; tail -25 "$WORK/phaseB.configure.log"; exit 1
fi

echo "   复用阶段A的生成文件"
mkdir -p out/Release
[ -f "$WORK/host/gen.tar.gz" ] && tar -C out/Release -xzf "$WORK/host/gen.tar.gz" 2>/dev/null || true
for t in $HOSTTOOLS; do
  [ -f "$WORK/host/$t" ] || continue
  cp -f "$WORK/host/$t" "out/Release/$t"
  chmod +x "out/Release/$t"
done
MACSDK="$(xcrun --sdk macosx --show-sdk-path)"
python3 "$HERE/patch-host-mk.py" out "$MACSDK" $HOSTTOOLS || true
python3 "$HERE/skip-generated.py" out || true

if [ "${PROBE:-0}" = "2" ]; then
  echo "== PROBE2: js2c 相关 makefile"
  ls out/*.mk | grep -i js2c || echo "  没有 js2c 的 mk"
  for f in $(ls out/*.mk | grep -i js2c); do
    echo "--- $f"; head -30 "$f" | cut -c1-160
    grep -n "CXX\|CC\b\|LINK" "$f" | head -10 | cut -c1-160
  done
  grep -n "js2c" out/node.target.mk 2>/dev/null | head -8 | cut -c1-160
  exit 0
fi

echo "== 阶段B 编译（约 30-60 分钟）"
set +e
# 关键：host 工具集必须用 macOS 编译器。gyp 的 host 规则默认继承 CC/CXX（也就是
# 我们那个 iOS 包装器），结果 node_js2c 被编成 iOS 二进制、构建机上 Killed: 9。
make -j"$JOBS" V=0 \
  CC.host=clang CXX.host=clang++ LINK.host=clang++ AR.host=ar NM.host=nm \
  CFLAGS.host="-O2" CXXFLAGS.host="-O2" LDFLAGS.host="" \
  >"$WORK/build.log" 2>&1
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "编译失败，日志尾部："; tail -60 "$WORK/build.log"; exit $rc
fi

cp -f out/Release/node "$OUT/node-ios-arm64"
echo "== 产物"
file "$OUT/node-ios-arm64"
vtool -show-build "$OUT/node-ios-arm64" 2>/dev/null | head -10 || true
echo "产物: $OUT/node-ios-arm64"
