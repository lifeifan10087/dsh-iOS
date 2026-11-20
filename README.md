# dsh-go 引擎移植到 iOS（越狱机）实施方案

结论：**能移植，引擎侧没有硬阻塞**。本机已在 Linux 上把 `process.platform` 谎报成 `darwin/arm64`
真实启动过引擎（`dsh web` 正常监听、页面 401/200 正常），唯一拦路的原生 addon 用纯 JS 替身绕过。
真正的工作量在「给 iOS 编一个 Node 运行时」和「原生壳 + iOS 专属能力」。

## 一、实测结论（本次会话验证）

| 检查项 | 结果 |
|---|---|
| 代码里的平台硬判断 | 只有 win32 分支为主，`darwin` 分支齐全（sandbox=`seatbelt`，打开文件/目录选择器走 `open`/`osascript`） |
| 谎报 darwin 启动 CLI | `dsh --version` → `0.2.2-rc.1`，正常 |
| 谎报 darwin 启动 `dsh web` | 正常，打印 `http://127.0.0.1:3399/?token=...`，HTTP 401 → 带 token 可进 |
| 唯一启动阻塞 | `node-addon-require-builtin`（NARB，原生 N-API），必须在 iOS 重编或用 JS 替身 |
| 替身可行性 | 已验证：`node --expose-internals` 下 CJS `require('internal/modules/...')` 五个模块全部拿到 |

原生依赖矩阵（`/opt/dsh/node_modules` 实测）：

| 包 | 作用 | iOS 方案 |
|---|---|---|
| `node-addon-require-builtin` | 加载 Node 内部 ESM/CJS loader | **JS 替身**（已给），无需重编 |
| `node-pty` | 持久 bash、终端 | 用 iPhoneOS SDK 重编（libSystem 有 `forkpty`） |
| `@koromix/koffi` | FFI | 上游有 `darwin_arm64`，改 LC_BUILD_VERSION 为 iOS 后重签 |
| `@vscode/ripgrep` | 文件搜索 | Procursus 装 `ripgrep`，或自编 arm64-iOS `rg` |
| `sharp` | 图像处理 | 自编 libvips 代价高 → 可选功能，缺失降级 |
| `sherpa-onnx` | 本地语音识别 | 上游有 iOS xcframework，换 dylib + `.node` 重编 |
| `node-addon-system`(landlock) | Linux 沙箱 | iOS 走 `seatbelt` 分支；本会话已是 danger-full-access，不依赖它 |

## 二、三条路线

**路线 A：虚拟机跑（今天就能用，功能最全）**
iOS 侧装 UTM（越狱可开 JIT），起 Debian arm64，直接把现有 `linux-arm64` 依赖搬进去。
零重编译、零适配，性能约为原生 1/3（有 JIT）～1/10（UTM SE）。
适合先验证「在 iPhone 上能不能干活」。

**路线 B：原生 Node（体验最好，工程量最大）**
Mac 上编 Node 24 for iOS arm64 → 重编 `node-pty` → 打 iOS 版 prebuilt → `ldid` 签名 +
`/var/jb` 落盘 + launchd 常驻 → Swift/WKWebView 壳（或 Flutter iOS 版）连 `127.0.0.1:3080`。
约 2–4 周，主要风险是 Node 24 对 iOS 的补丁（nodejs-mobile 补丁集停在 Node 18/22）。

**路线 C：手机只做壳（最稳，一天出活）**
引擎跑在 Mac/家里服务器/云，iPhone 用 WKWebView 或 Safari 连过去（`--host 0.0.0.0` + token）。
功能 = Web 客户端全部（会话/工具/子代理/定时/插件/工作流），缺原生卡片与手机操控。

推荐：**C 或 A 先跑起来 → 按缺口补 B**。

## 三、"完整功能版"还差什么

Android 版 dsh-go 的原生部分在 iOS 上要重写：

- 手机操控 MCP（`mcp__phone__*`）：iOS 无公开 UI 自动化，需要越狱注入
  `IOHIDEvent` + Accessibility 私有框架的 helper（等同 AutoTouch 的实现思路），或退化到
  Shortcuts / URL Scheme / `intent` 等价物。
- dsh-ui 原生卡片（Flutter 侧渲染）：Web 端有对应渲染，原生壳里需 Swift 重做。
- 通知、剪贴板、分享、常驻前台：越狱后可用 `launchd` + `pbcopy/pbpaste` + `CFNotificationCenter`。
- dsh-go 本地插件（Flutter 插件目录 `$DSH_HOME/dsh-go/plugins`）：iOS 侧要换成 Swift 插件宿主。

## 四、文件

```
shim/node-addon-require-builtin.js  原生 addon 的纯 JS 替身
shim/apply-shim.sh                  套用/回滚
scripts/ios-init.sh                 设备内初始化：装引擎 + 替身 + launchd 常驻
build/preflight.sh                  编译前预检（Xcode/SDK/磁盘/host node）
build/build-node-ios.sh             Mac 上编 Node for iOS arm64
build/apply-ios-overrides.py        往 Node 源码注入 iOS 交叉编译覆盖
build/patch-macho-ios.sh            Mach-O 平台号改 ios + ldid 重签
build/entitlements.plist            JIT / no-sandbox 等 entitlement
build/build-node-pty-ios.sh         编 node-pty 的 iOS 版（持久终端用）
build/package-deb.sh                打成 rootless deb
deploy/install-ios.sh               推 node、签名、初始化、验收（支持 key / 密码）
deploy/bundle-node-modules.sh       宿主机按 darwin-arm64 备依赖并改平台号
deploy/push-to-github.sh            建仓+推送+触发 Actions
deploy/fetch-artifact.mjs           无 gh 也能拉 Actions 产物
docs/RUNBOOK-B.md                   路线 B 全流程 + 失败树 + 验收清单
docs/ACTIONS.md                     零 Mac 版：Actions 编 → 手机部署
.github/workflows/build-node-ios.yml  没 Mac 就用 GitHub Actions 编
shell/{main.swift,Makefile,Info.plist}  Theos 的 WKWebView 原生壳
```

## 四.1 本机复现记录（Linux 上验证 darwin 分支）

```bash
# 1) 谎报平台
cat > shim-darwin.mjs <<'EOF'
Object.defineProperty(process,'platform',{value:'darwin'});
Object.defineProperty(process,'arch',{value:'arm64'});
EOF
# 2) 套替身 + 起引擎
bash shim/apply-shim.sh /opt/dsh/node_modules
DSH_HOME=/tmp/iostest node --expose-internals --import ./shim-darwin.mjs \
  /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js web --port 3399 --no-open
# 输出 http://127.0.0.1:3399/?token=… ；直连返回 401，带 token 正常
```

## 五、路线 B：怎么走（详见 docs/RUNBOOK-B.md）

```bash
# 有 Mac：
bash build/preflight.sh                     # 预检必须全绿
NODE_VER=v24.9.0 bash build/build-node-ios.sh
bash build/patch-macho-ios.sh out/node-ios-arm64

# 没有 Mac：把 ios-port/ 推到 GitHub，跑 Actions「build-node-ios」，下 artifact

# 装到设备（rootless /var/jb 自动识别）：
DEVICE=root@192.168.1.20 bash deploy/install-ios.sh out/node-ios-arm64
```

`install-ios.sh` 内部依次：推 node → `ldid` 带 JIT entitlement 签名 → 推包 →
`scripts/ios-init.sh`（装引擎、套 addon JS 替身、写 launchd 常驻）→ 打印带 token 的地址。

验收：`node -p process.platform` 应为 `darwin`；`curl 127.0.0.1:3080` 返回 401 即正常。
`node-pty` 不编也能用（普通 bash 工具走 child_process，只有 tmux 式持久终端缺失）。

## 六、风险

- Node 24 官方不支持 iOS，需自己套 iOS 补丁；备选降 Node 22 试跑（引擎标注 `>=24.9`，多半只警告）。
- JIT：iOS 必须先拿 JIT entitlement（`ldid -S` 带 `allow-jit` + 关掉 CDHash 校验），否则只能 `--jitless`，慢且 WASM 不可用。
- 后台常驻依赖 launchd，iOS 会回收非 daemon 进程；不走 daemon 会掉线。
- iCloud/系统更新后越狱环境可能失效，需保留可重装脚本。
