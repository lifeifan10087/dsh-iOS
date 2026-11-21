#!/usr/bin/env python3
"""让 make 跳过"构建期工具生成文件"的 action。

gyp 的 action 用 *.intermediate 作为戳文件；戳在、生成物在，make 就不会再跑
js2c / torque / bytecode 生成器。阶段A（macOS）已经把它们生成好了，这里补戳。
用法: skip-generated.py <out 目录>
"""
import pathlib, re, sys, time

out = pathlib.Path(sys.argv[1])
now = time.time()
stamps = set()
for mk in out.glob("*.mk"):
    text = mk.read_text(encoding="utf-8", errors="replace")
    for m in re.finditer(r"[^\s'\":;]+\.intermediate", text):
        stamps.add(m.group(0))

made = 0
for s in stamps:
    p = out / s if not s.startswith("out/") else pathlib.Path(s)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists():
            p.write_text("")
            made += 1
        p.touch()
    except Exception as e:
        print(f"  跳过 {s}: {e}")

# 生成文件也刷新时间，保证比源码新
gen = out / "Release/obj/gen"
n = 0
if gen.exists():
    for f in gen.rglob("*"):
        if f.is_file():
            try:
                f.touch()
                n += 1
            except OSError:
                pass

print(f"  创建/刷新 intermediate 戳 {made} 个；刷新生成文件 {n} 个")
