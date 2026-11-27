# 交接文档 · DSH Go 移植到 iPhone

> 任何新会话先读这一份，再动手。最后更新：见 git log。

## 一句话状态

**Node 22.20 的 iOS 包已经编出来了并通过产物校验**（run `44999614926` success，产物已拉到
`out/node-ios-patched`，platform=2 / minos 14.0 / 带 ICU / 带版本串 v22.20.0），一键 deb 也打好了
（`out/dsh-go_0.2.3_iphoneos-arm64.deb`，216MB，已复制到手机 `/sdcard/Download/DSH-Go/`）。

**卡在最后一步**：手机 `192.168.10.229` 已不在线，网段内只探到 `192.168.10.230`
（62078 lockdown 开着 = 是台 iOS 设备，但 22 端口 refused，说明 sshd/越狱没起来）。
设备侧第 3–5 步（替换 node、四条验收、装 ios-mcp）等 SSH 恢复，或直接走 deb 装。

## 关键坐标

| 项 | 值 |
|---|---|
| 代码仓库 | `lifeifan10087/dsh-iOS`（GitHub，默认分支 main） |
| 需要凭证 | classic PAT，勾 `repo` + `workflow`（每次新会话由用户重新提供） |
| 构建入口 | `build/build-node-ios.sh`，workflow `.github/workflows/build-node-ios.yml` |
| 最近一次构建 | run `44999614926` → **success**（v22.20.0 + ICU，产物 226.8MB kit） |
| 上一次构建 | run `44992516975` → failure：只差最后链接（见坑表 CoreFoundation 那条） |
| 产物 | `out/node-ios-patched`（110MB，platform=2）、`out/node_modules.tgz`（183MB） |
| 一键包 | `out/dsh-go_0.2.3_iphoneos-arm64.deb`；手机侧 `/sdcard/Download/DSH-Go/` |
| 设备 | `mobile@192.168.10.229`，密码由用户提供；`echo <pw> \| sudo -S -p ""` 可提权 |
| 设备已装 | `gzip`、`ldid`、`com.dsh.go`(0.2.2，内含 22.9 版 node) |
| 待装 | `/tmp/ios-mcp.deb`（23.6MB，已下载，未安装） |

## 已经打通的

1. **可行性**：把 `process.platform` 谎报成 darwin 后 dsh web 正常监听、401 正常
2. **原生 addon 替身**：`node-addon-require-builtin` → 纯 JS（需 `--expose-internals`）
3. **两阶段交叉编译**：阶段A（macOS 编构建期工具）+ 阶段B（iOS 目标），缓存已配
4. **iOS 补丁移植**：nodejs-mobile 的 22.9 iOS 补丁 → 官方 22.20（`patches/ios-22.20.patch` + `build/port-ios-strings.py`）
5. **设备侧**：SSH + sudo 通，deb 安装链路验证过（缺 gzip/ldid 的坑已修进脚本）
6. **一键包**：`deploy/make-install-deb.sh` + `deploy/serve-deb.sh`（局域网 HTTP 分发）

## 已定位的坑（别重复踩）

| 现象 | 原因 | 处理 |
|---|---|---|
| `Killed: 9` 跑构建期工具 | 工具被编成 iOS 二进制 | 阶段A 产 macOS 版 + 清空 `*.host.mk`（但 **跳过 `/tools/icu/`**） |
| `simdutf built for iOS` | host/target 混编 | wrapper 按 `obj.host/` 路径分流 |
| `No space left` | 同时存两套 V8 | 换 `actions/cache` 只存 `work/host`；workflow 里清理 Xcode 平台 |
| `kSecTrustSettings*` 未定义 | iOS 没有该 API | `-DDSH_TARGET_IOS` + `port-ios-strings.py` 给 macOS 分支加保护 |
| `\p{ID_Continue} Invalid property` | 构建用了 `--without-intl` | 已去掉，改回 ICU |
| `import.meta.main` 静默退出 | Node < 22.20 无此特性 | 必须 ≥22.20 |
| `unsupported Node module loader` | 22.9 的 ESM 内部接口太旧 | 同上 |
| node 一启动 SIGBUS | 设备 JIT 未授权 | 启动器加 `--jitless` |
| deb 装完目录 700 | 打包时 mkdir 权限 | `make-install-deb.sh` 已加 chmod 755 |
| `_CFRelease/_CFTimeZoneCopyDefault undefined`（链接 `cctest`/`embedtest`/`node`） | abseil 的 cctz `time_zone_lookup.cc` 在 `__APPLE__` 下走 CoreFoundation 分支；node 的 gyp 只在 `OS=="mac"` 分支才自动带 `-framework CoreFoundation`，我们走 iOS 目标 | `build-node-ios.sh` 的 `ios-cc`/`ios-cxx` 包装器：**只在链接（无 `-c`）时**追加 `-framework CoreFoundation -framework CoreServices -liconv` |
| `api.github.com` 间歇 `ECONNABORTED`/握手超时 | 大陆线路抖动（`github.com`/`raw.githubusercontent.com` 完全不通，`api`+`codeload` 通） | `deploy/gh-put.mjs`、`deploy/fetch-artifact.mjs` 都已带重试；不要用 `git push` |

## 阻塞项（2026-11-22 记）

- **设备 SSH 不通**：`192.168.10.229` 完全超时（旧地址/已关机）；`192.168.10.230` 的 62078
  lockdown 开着、22 端口 refused → 是那台 iPhone，但 sshd 没起来（越狱插件没开或重启后未激活）。
  探段命令：`node deploy/discover-iphone.mjs 192.168.10`（或 `node /tmp/scan.mjs 192.168.10` 扫 22/62078/3080）。
- 不依赖 SSH 的路子：把 `out/dsh-go_0.2.3_iphoneos-arm64.deb` 拷进手机，Filza/Sileo 点装，
  postinst 自动起引擎并把 token 写到 `/var/mobile/Documents/dsh-url.txt`。
- 本机出口网段会漂：2026-11-22 是 `10.111.33.x`（跟手机不同网段），11-27 回到 `192.168.10.216`。

## 下一步（按顺序）

1. ~~盯构建 + 取产物~~ 已完成：`node deploy/fetch-artifact.mjs lifeifan10087/dsh-iOS dsh-ios-kit 44999614926`
2. ~~校验产物~~ 已完成：`python3 deploy/verify-node-ios.py out/node-ios-patched 22.20` → PASS
   （platform=2 / minos 14.0 / sdk 18.5 / 已签名 / 版本串 v22.20.0；三个原生 addon 也已验为 platform=2）
3. 替换设备 node（需 SSH）：`source .secrets.env && bash deploy/swap-node.sh out/node-ios-patched`
   （自动探测 node 路径、留 `node.bak-<时间戳>`、重写启动器带 `--jitless`、顺带跑验收）
4. 验收四条：`bash deploy/accept-device.sh` → 探针 + JSON 判定：
   `process.platform=darwin`、`node:sqlite`、`127.0.0.1:3080` 无 token 401、带 token 200
5. 手机操控：装 `/tmp/ios-mcp.deb` → `curl http://127.0.0.1:8090/health` → 在
   `/var/mobile/Library/dsh/profiles/web/cordis.patch.yml` 追加：
   ```yaml
   - id: mcp-ios
     name: "@deepseek-ai/dsh-mcp-client"
     config:
       transport: streamable-http
       serverName: ios
       url: http://127.0.0.1:8090/mcp
   ```
   重启引擎，工具名形如 `mcp__ios__tap_screen`

## 常用命令

```bash
# 触发构建（新 token）
curl -X POST -H "Authorization: Bearer $T" \
  https://api.github.com/repos/lifeifan10087/dsh-iOS/actions/workflows/build-node-ios.yml/dispatches \
  -d '{"ref":"main","inputs":{"node_ref":"v22.20.0","min_ios":"14.0","probe":"0","node_tarball":"https://nodejs.org/dist/v22.20.0/node-v22.20.0.tar.gz"}}'

# 设备诊断
sshpass -e ssh mobile@192.168.10.229 'tail -20 /var/mobile/Library/Logs/dsh-engine.log'
sshpass -e ssh mobile@192.168.10.229 'cat /var/mobile/Documents/dsh-url.txt'

# 离线测试（10 项，秒级）
bash tests/run-tests.sh
```

---

# 附：决策与教训（从长对话里蒸馏，新会话必读）

## 三条硬约束（违反就白跑）

1. **Node 必须 ≥ 22.20**：`bin.js` 底部是 `if (import.meta.main) await runCli()`，
   22.9 里这玩意儿是 `undefined` → **静默退出、退出码 0、没有任何报错**。
   再加上 22.9 的 ESM 内部接口缺 `resolveSync` / `getModuleJobForImport`，
   dsh 的插件加载会抛 `unsupported Node module loader`。
2. **必须带 ICU**：`--without-intl` 会让 V8 丢掉 Unicode 属性表，
   dsh 里一条 `\p{ID_Continue}` 正则直接 `Invalid property name`，启动即死。
3. **设备 JIT 未授权**：node 不加 `--jitless` 会 SIGBUS（退出码 138）。
   `--jitless` 能跑但慢 3–10 倍、WASM 不可用。

## 构建期的四个"看起来像编译错误"其实都不是

| 症状 | 真实原因 | 解法 |
|---|---|---|
| `Killed: 9` + `Error 137` | 构建期工具被编成 iOS 二进制，在 macOS 上执行被内核杀掉 | 阶段A 产 macOS 版，阶段B 清空 `*.host.mk` 阻止重编 |
| `building for 'macOS', but linking in object file built for 'iOS'` | host 与 target 混编（`obj.host/` 里躺了 iOS 目标文件） | wrapper 按 `obj.host/` 路径分流到 macOS clang |
| `No space left on device`（写 libv8 静态库时） | 同时存了两套 V8（host + target），14GB 盘不够 | 只缓存 `work/host`；workflow 里删 Xcode 的 tvOS/watchOS 平台与模拟器运行时 |
| `No rule to make target .../genccode` | 清空 host makefile 时把 ICU 的工具也清了 | 清空时排除 `/tools/icu/` |

## 设备侧踩过的坑

| 症状 | 原因 | 处理 |
|---|---|---|
| `tar: gzip: Cannot exec` | iOS 默认没有 gzip | `apt-get install gzip`（已写进 deb 的 Depends） |
| `ldid: command not found` | 没装签名工具 | `apt-get install ldid`（同样进 Depends） |
| `ls: Permission denied` 访问 `/var/jb/usr/local` | 打包时目录建成 700 | `make-install-deb.sh` 里补 chmod 755 |
| 启动器报找不到 `@deepseek-ai/dsh` | 启动器指向 `/var/jb/.../app`，实际解压到 `/var/mobile/Library/dsh/app` | 已统一到后者 |

## 架构上已经确定的选择（别推翻）

- **不写原生手机操控**：用 MCP 边界。ios-mcp（越狱设备上的 deb，HTTP 8090）提供 46 个工具，
  dsh 的 MCP 客户端原生支持 `streamable-http`，加一条 `cordis.patch.yml` 即可，
  **零代码**。它的失败不影响 dsh 本身。
- **不改 dsh 源码**：所有改动都在构建脚本、补丁文件、设备配置三处。
- **原生 UI 卡片（dsh-ui）先不做**：那是 Swift 重写，与"引擎能跑"是两件事。

## 判断"成功"的标准

```bash
node -p 'process.platform + "/" + process.arch'      # darwin/arm64
node -e 'require("node:sqlite")'                      # 22 需 --experimental-sqlite
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/   # 401
# 最后：Safari 打开 token 地址能看到界面
```

四条全过 = 引擎移植完成。手机操控是加分项，不是验收项。
