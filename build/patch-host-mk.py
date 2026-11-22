#!/usr/bin/env python3
"""把 gyp 生成的 host 工具 makefile 改成 macOS 编译。

交叉编译时 gyp 会把 CC/CXX（我们注入的 iOS 包装器）写进 host.mk，
于是构建期工具被编成 iOS 二进制，在构建机上直接 Killed: 9。
这里把 host.mk 里的编译器、sysroot、目标三元组全部换回 macOS。

用法: patch-host-mk.py <out 目录> <macOS SDK> [工具名...]
"""
import pathlib, re, sys

out = pathlib.Path(sys.argv[1])
macsdk = sys.argv[2]
tools = sys.argv[3:] or ["node_js2c", "bytecode_builtins_list_generator", "torque",
                         "gen-regexp-special-case", "node_mksnapshot"]

REPL = [
    # 编译器变量
    ("$(CXX.host)", "clang++"), ("$(CC.host)", "clang"), ("$(LINK.host)", "clang++"),
    ("$(CXX.target)", "clang++"), ("$(CC.target)", "clang"), ("$(LINK.target)", "clang++"),
    # gyp 可能把绝对路径写死
]
changed = 0
targets = []
for tool in tools:
    targets += [out / f"{tool}.host.mk", out / f"{tool}.target.mk"]
# 所有 host 工具集的 makefile 都要改（simdutf、libuv、v8_libbase 等也参与 host 构建）
targets += sorted(out.rglob("*.host.mk"))

for mk in dict.fromkeys(targets):
    if mk is not None and mk.exists():
        text = mk.read_text(encoding="utf-8", errors="replace")
        before = text
        for a, b in REPL:
            text = text.replace(a, b)
        text = re.sub(r"[^\s'\"]*/ios-cxx", "clang++", text)
        text = re.sub(r"[^\s'\"]*/ios-cc", "clang", text)
        text = re.sub(r"/[^\s'\"]*/(?:iPhoneOS|AppleTVOS)[^\s'\"]*\.sdk", macsdk, text)
        text = re.sub(r"-m(?:iphone|appletv)os-version-min=[0-9.]+", "-mmacosx-version-min=11.0", text)
        text = re.sub(r"-target\s+arm64-apple-ios[0-9.]*", "-target arm64-apple-macos11", text)
        if text != before:
            mk.write_text(text, encoding="utf-8")
            print(f"  patched {mk.name}")
            changed += 1
        else:
            print(f"  unchanged {mk.name}")
print(f"共修改 {changed} 个 makefile")
