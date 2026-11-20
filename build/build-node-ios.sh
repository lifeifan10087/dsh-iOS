#!/usr/bin/env bash
# 编译 Node for iOS/arm64（在 macOS 上跑；GitHub macos-14 runner 也行）
# 用法:
#   NODE_VER=v24.9.0 bash build-node-ios.sh
#   OPENSSL_ASM=1 NODE_VER=v24.9.0 bash build-node-ios.sh    # 想开 OpenSSL asm 时
set -euo pipefail

NODE_VER="${NODE_VER:-v24.9.0}"
WORK="${WORK:-$HOME/node-ios-build}"
OUT="${OUT:-$WORK/out}"
MIN_IOS="${MIN_IOS:-14.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$(uname -s)" = Darwin ] || { echo "必须在 macOS 上跑（需要 iPhoneOS SDK）"; exit 1; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VER="$(xcrun --sdk iphoneos --show-sdk-version)"
echo "SDK $SDK_VER @ $SDK | iOS min $MIN_IOS | Node $NODE_VER | jobs $JOBS"

mkdir -p "$WORK" "$OUT"
cd "$WORK"
if [ ! -d node ]; then
  git clone --depth 1 --branch "$NODE_VER" https://github.com/nodejs/node.git
else
  git -C node fetch --depth 1 origin "$NODE_VER" && git -C node checkout -q FETCH_HEAD
fi
cd node

echo "== 注入 iOS gyp 覆盖"
python3 "$HERE/apply-ios-overrides.py" .

TARGET="arm64-apple-ios${MIN_IOS}"
export CC="$(xcrun -f clang)"
export CXX="$(xcrun -f clang++)"
export CFLAGS="-target $TARGET -isysroot $SDK -fembed-bitcode-marker -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-target $TARGET -isysroot $SDK -Wl,-platform_version,ios,$MIN_IOS,$SDK_VER"

CONF=(
  --dest-os=mac
  --dest-cpu=arm64
  --without-snapshot          # 交叉编译时 mksnapshot 跑不起来；需要 snapshot 就先编 host mksnapshot
  --without-intl
  --without-npm
  --without-corepack
  --without-inspector
  --prefix="$OUT"
)
[ "${OPENSSL_ASM:-0}" = 1 ] || CONF+=(--openssl-no-asm)

echo "== configure ${CONF[*]}"
./configure "${CONF[@]}"

echo "== make -j$JOBS（首次 20~60 分钟）"
set +e
make -j"$JOBS" V=0 >"$WORK/build.log" 2>&1
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "编译失败，日志尾部："
  tail -60 "$WORK/build.log"
  echo
  echo "常见原因："
  echo " 1) 链接期 -framework 报错 → 在 node.gyp 的 xcode_settings 里剔除该框架"
  echo " 2) V8 报 OS_IOS 未定义 → 加 CFLAGS=-DV8_OS_IOS 重跑"
  echo " 3) 缺 python 模块 → pip3 install --user packaging"
  exit $rc
fi

BIN="$WORK/node/out/Release/node"
cp -f "$BIN" "$OUT/node-ios-arm64"
echo "== 产物校验"
file "$OUT/node-ios-arm64"
vtool -show-build "$OUT/node-ios-arm64" 2>/dev/null | head -12 || true
echo "产物: $OUT/node-ios-arm64"
echo "下一步: bash patch-macho-ios.sh $OUT/node-ios-arm64"
