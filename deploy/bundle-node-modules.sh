#!/usr/bin/env bash
# 在 Mac 上把 node_modules 备好（按 darwin-arm64 选可选包），顺手把 macOS 二进制改成 iOS 平台号。
# 产物: out/node_modules.tgz  —— 推到设备解包即用，设备上不需要 npm。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$HERE/out}"
BUILD="$OUT/bundle"
VER="${DSH_VER:-0.2.2-rc.1}"

mkdir -p "$BUILD" "$OUT"
cd "$BUILD"
[ -f package.json ] || npm init -y >/dev/null
echo "== 安装（按 darwin/arm64 解析可选依赖）"
npm i "@deepseek-ai/dsh@$VER" --omit=dev --ignore-scripts --os=darwin --cpu=arm64 --no-audit --no-fund

echo "== 套 addon JS 替身"
bash "$HERE/shim/apply-shim.sh" "$BUILD/node_modules"

echo "== 把 darwin 原生二进制改成 iOS 平台号"
found=0
while IFS= read -r bin; do
  found=$((found+1))
  case "$(file -b "$bin")" in
    *Mach-O*) bash "$HERE/build/patch-macho-ios.sh" "$bin" "$bin.ios" && mv -f "$bin.ios" "$bin" || echo "  跳过 ${bin}（vtool 失败）";;
    *) echo "  跳过 ${bin}（非 Mach-O）";;
  esac
done < <(find "$BUILD/node_modules" -type f \( -name "*.node" -o -name "rg" -o -name "landlock-run" \) 2>/dev/null)
echo "处理了 $found 个二进制"

tar -C "$BUILD" -czf "$OUT/node_modules.tgz" node_modules
echo "产物: $OUT/node_modules.tgz ($(du -h "$OUT/node_modules.tgz" | cut -f1))"
