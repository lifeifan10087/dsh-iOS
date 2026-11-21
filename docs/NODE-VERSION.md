# iOS 上跑 dsh 需要哪个 Node 版本

实测结论：**Node 18 不行，最低 Node 22，推荐 24**。

## 证据

| 版本 | 结果 | 原因 |
|---|---|---|
| 18.20.4 | ❌ 起不来 | `dsh-app-boot` 里 `import { parseEnv } from "node:util"`；`parseEnv` 是 Node 20.12 才加的 |
| 22.x | ✅ 能起 | 本机实测 `dsh web` 返回 401（正常鉴权），`node:sqlite` 需 `--experimental-sqlite` |
| 24.x | ✅ 官方目标 | `engines.node >= 24.9.0`，`node:sqlite` 稳定 |

具体报错（Node 18.20.4）：

```
SyntaxError: The requested module 'node:util' does not provide an export named 'parseEnv'
```

## 现成的 iOS 预编译包

社区有一个 **Node 18.20.4 for jailbroken iOS** 的 deb：

- 仓库：`imcynic/nodejs-ios`（`nodejs_18.20.4-1_iphoneos-arm64.deb`，12.9MB）
- 二进制：71MB，`LC_BUILD_VERSION platform=iOS 13.0`，签名 entitlements 与本项目一致
  （`platform-application`、`no-sandbox`、`allow-jit`、`dynamic-codesigning`）
- **用途**：验证工具链与签名思路；不能跑 dsh（版本太老）

目前**没有**找到 Node 22/24 的公开 iOS 预编译包，所以还是要自己编（本项目 GitHub
Actions / Codemagic / Azure 三条通道）。

## 如果以后只想跑点简单脚本

Node 18 那个 deb 装上就能用：

```bash
# 设备上（Sileo 或命令行）
dpkg -i nodejs_18.20.4-1_iphoneos-arm64.deb
node -v          # v18.20.4
```

但 dsh 需要 ≥22，这一步只用于确认越狱环境的 node 能正常加载 JIT。
