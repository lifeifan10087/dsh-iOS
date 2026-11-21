#!/usr/bin/env python3
"""把 gyp 生成文件里构建期工具的编译/链接命令换成 true。

原因：这些工具（node_js2c / bytecode_builtins_list_generator / torque / ...）
在交叉编译时会被编成 iOS 二进制，在构建机上跑不起来。我们在阶段 A 已经用
macOS 目标把它们编好并放进 out/Release，这里让 make 的规则变成空操作，
避免覆盖掉那份能跑的二进制。

用法: neutralize-host-tools.py <out 目录> <工具名...>
"""
import pathlib, re, sys

out = pathlib.Path(sys.argv[1])
tools = sys.argv[2:]
COMPILER_VARS = ["$(CXX.target)", "$(CXX)", "$(CC.target)", "$(CC)",
                 "$(LINK.target)", "$(LINK)", "$(AR.target)", "$(AR)"]

for tool in tools:
    mk = out / f"{tool}.target.mk"
    if not mk.exists():
        print(f"  skip {mk.name}")
        continue
    text = mk.read_text(encoding="utf-8", errors="replace")
    before = text
    for var in COMPILER_VARS:
        text = text.replace(var, "true")
    # gyp 有时把编译器写成绝对路径
    text = re.sub(r"[^\s'\"]*/ios-cxx", "true", text)
    text = re.sub(r"[^\s'\"]*/ios-cc", "true", text)
    if text != before:
        mk.write_text(text, encoding="utf-8")
        print(f"  neutralized {mk.name}")
    else:
        print(f"  unchanged {mk.name}")
