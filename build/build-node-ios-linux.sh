#!/usr/bin/env bash
# 在 Linux 上交叉编 Node for iOS（无 Mac 兜底方案）
# 依赖: clang / lld / ninja / python3 + iPhoneOS SDK（theos/sdks）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$PWD/work}"
SDK_ROOT="${SDK_ROOT:-/tmp/sdks}"
MIN_IOS="${MIN_IOS:-14.0}"
NODE_VER="${NODE_VER:-v24.9.0}"
NPROC="$(nproc)"

[ -d "$SDK_ROOT" ] || { echo "缺 SDK：git clone --depth 1 https://github.com/theos/sdks.git $SDK_ROOT"; exit 1; }
SDK="$(find "$SDK_ROOT" -maxdepth 1 -type d -name 'iPhoneOS*.sdk' | sort -V | tail -1)"
[ -n "$SDK" ] || { echo "没找到 iPhoneOS*.sdk"; ls "$SDK_ROOT"; exit 1; }
echo "SDK: $SDK"

# gyp 需要 xcodebuild / xcrun / otool 这些 macOS 工具的存在，全部用 shim 顶掉
mkdir -p "$WORK/bin"
cat > "$WORK/bin/xcrun" <<EOF
#!/bin/sh
case "\$*" in
  *--show-sdk-path*)    echo "$SDK" ;;
  *--show-sdk-version*) echo "${MIN_IOS}" ;;
  *--find*)             shift; command -v "\$1" || echo "/usr/bin/\$1" ;;
  *--version*)          echo "xcrun 15.0" ;;
  *)                    echo "$SDK" ;;
esac
EOF
cat > "$WORK/bin/xcodebuild" <<'EOF'
#!/bin/sh
printf 'Xcode 15.0\nBuild version 15A240d\n'
EOF
cat > "$WORK/bin/install_name_tool" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK/bin/codesign" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK/bin/dsymutil" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK/bin/otool" <<'EOF'
#!/bin/sh
exec llvm-otool "$@" 2>/dev/null || exit 0
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

mkdir -p "$WORK"; cd "$WORK"
[ -d node ] || git clone --depth 1 --branch "$NODE_VER" https://github.com/nodejs/node.git
cd node
python3 "$HERE/apply-ios-overrides.py" . || true

export CC=clang CXX=clang++ AR=llvm-ar NM=llvm-nm
# host 侧工具（torque/mksnapshot/bytecode 生成器）用本机编译器
export CC_host=clang CXX_host=clang++
export CFLAGS_host="-O2" CXXFLAGS_host="-O2" LDFLAGS_host=""
export CFLAGS="-target arm64-apple-ios${MIN_IOS} -isysroot $SDK -O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-fuse-ld=lld -target arm64-apple-ios${MIN_IOS} -isysroot $SDK -Wl,-platform_version,ios,${MIN_IOS},18.0"

./configure --dest-os=mac --dest-cpu=arm64 --cross-compiling \
  --without-snapshot --without-intl --without-npm --without-corepack \
  --without-inspector --openssl-no-asm --prefix="$WORK/out"

set +e
make -j"$NPROC" V=0 >"$WORK/build.log" 2>&1
rc=$?
set -e
[ $rc -eq 0 ] || { echo "编译失败，尾部日志："; tail -50 "$WORK/build.log"; exit $rc; }

mkdir -p "$WORK/out"
cp -f out/Release/node "$WORK/out/node-ios-arm64"
file "$WORK/out/node-ios-arm64"
echo "产物: $WORK/out/node-ios-arm64"
