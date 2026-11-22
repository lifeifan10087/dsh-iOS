#!/usr/bin/env python3
"""把 iOS 需要的几处字符串/条件改动打到 Node 源码树上（幂等）。

这些是 nodejs-mobile 22.9 补丁里没被 ios.patch 命中、但语义等价的改动：
gyp 的 OS 列表要加上 ios，libuv 的 fs.c 要排除 iOS 走 sendfile 分支。
用法: port-ios-strings.py <node 源码目录>
"""
import pathlib, sys

root = pathlib.Path(sys.argv[1])
edits = []

def edit(rel, old, new, note):
    p = root / rel
    if not p.exists():
        print(f"  skip {rel}（不存在）"); return
    t = p.read_text(encoding="utf-8", errors="surrogateescape")
    if new in t:
        print(f"  已有 {rel}: {note}"); return
    if old not in t:
        print(f"  ⚠ 未匹配 {rel}: {note}"); return
    p.write_text(t.replace(old, new, 1), encoding="utf-8", errors="surrogateescape")
    edits.append(f"{rel}: {note}")
    print(f"  改好 {rel}: {note}")

edit("deps/uv/src/unix/fs.c",
     "#elif defined(__APPLE__) || defined(__DragonFly__) || defined(__FreeBSD__)",
     "#elif (defined(__APPLE__) && !TARGET_OS_IPHONE) || \\\n      defined(__DragonFly__)       || \\\n      defined(__FreeBSD__)",
     "iOS 不走 sendfile（22.9 写法）")

edit("deps/uv/src/unix/fs.c",
     "#elif defined(__APPLE__) ||                                     \\\n      defined(__DragonFly__) ||                                   \\\n      defined(__FreeBSD__)",
     "#elif (defined(__APPLE__) && !TARGET_OS_IPHONE) ||               \\\n      defined(__DragonFly__) ||                                   \\\n      defined(__FreeBSD__)",
     "iOS 不走 sendfile（22.20 写法）")

edit("node.gyp",
     """[ 'OS in "linux freebsd mac solaris openharmony" and '""",
     """[ 'OS in "linux freebsd mac ios solaris openharmony" and '""",
     "large code pages 条件加 ios")

edit("node.gyp",
     """[ 'OS in "linux mac openharmony"', {""",
     """[ 'OS in "linux mac ios openharmony"', {""",
     "js2c 字符串字面量条件加 ios")

edit("node.gypi",
     """[ 'coverage=="true" and node_shared=="false" and OS in "mac freebsd linux openharmony"', {""",
     """[ 'coverage=="true" and node_shared=="false" and OS in "mac ios freebsd linux openharmony"', {""",
     "coverage 条件加 ios")


# iOS 上 Security.framework 没有 SecTrustSettings* / 钥匙串检索 API，
# 用 DSH_TARGET_IOS 把 macOS 专属分支关掉（iOS 编译时由 wrapper 定义该宏）
ios_guard = "defined(__APPLE__) && !defined(DSH_TARGET_IOS)"
ctx = root / "src/crypto/crypto_context.cc"
if ctx.exists():
    t = ctx.read_text(encoding="utf-8", errors="surrogateescape")
    n = t.count("#ifdef __APPLE__")
    if n and "DSH_TARGET_IOS" not in t:
        t = t.replace("#ifdef __APPLE__", f"#if {ios_guard}")
        ctx.write_text(t, encoding="utf-8", errors="surrogateescape")
        print(f"  改好 src/crypto/crypto_context.cc: {n} 处 __APPLE__ 加上 !DSH_TARGET_IOS")
    else:
        print(f"  skip src/crypto/crypto_context.cc（已处理或不含 __APPLE__）")

print(f"完成，改动 {len(edits)} 处")
