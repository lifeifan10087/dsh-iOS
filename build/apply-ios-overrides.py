#!/usr/bin/env python3
"""在 Node 源码树里注入 iOS 交叉编译所需的 gyp 覆盖。

策略：**不改 --dest-os**（Node 的 configure 不认 ios），用 --dest-os=mac 走 Darwin 分支，
只把编译/链接目标换成 arm64-apple-ios。这里做三件必要的事：
  1. common.gypi / node.gyp 里对 mac 硬编码的 -mmacosx-version-min 去掉，改由 CFLAGS 提供 -target
  2. 去掉 iOS 上不存在的框架/库（-ldl 之类）
  3. 关掉依赖 macOS 专有 API 的开关（fsevents 之类，如出现）
每处替换都会打印命中数；0 命中时给出人工检查提示，不静默放过。
"""
import pathlib, sys

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
RULES = [
    ("common.gypi", "-mmacosx-version-min=", ""),
    ("node.gyp",   "-mmacosx-version-min=", ""),
    ("node.gyp",   "'-ldl'", ""),
    ("deps/uv/uv.gyp", "-mmacosx-version-min=", ""),
    ("deps/openssl/openssl.gypi", "-mmacosx-version-min=", ""),
]

hits, misses = 0, 0
for rel, needle, repl in RULES:
    p = ROOT / rel
    if not p.exists():
        print(f"  skip  {rel}（不存在）"); continue
    text = p.read_text(encoding="utf-8")
    n = text.count(needle)
    if n:
        p.write_text(text.replace(needle, repl), encoding="utf-8")
        print(f"  patch {rel}: {needle!r} x{n}")
        hits += n
    else:
        print(f"  none  {rel}: 未出现 {needle!r}（可能版本差异，需人工确认）")
        misses += 1

print(f"完成：命中 {hits} 处，未命中文件 {misses} 个")
if hits == 0:
    print("⚠ 一处都没命中：确认源码版本，或直接检查 node.gyp 的 'xcode_settings' 段")
