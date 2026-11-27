# 交接文档 · DSH Go 移植到 iPhone

> 任何新会话先读这一份，再动手。最后更新：见 git log。

## 一句话状态（2026-11-27 晚）

**跑通了。** 设备（`mobile@192.168.10.229`，iPhone12,1 / iOS 26.0.1 / rootless Dopamine 式越狱）
上 node 已换成 **v22.20.0**，dsh 引擎在 `127.0.0.1:3080` 正常服务，四条验收全过：

| 验收 | 结果 |
|---|---|
| `process.platform` 覆盖成 darwin | `darwin/arm64` ✓（原生上报 `ios/arm64`） |
| `node:sqlite` | `sqlite ok` ✓ |
| 无 token `GET /` | **401** ✓ |
| 带 token 打开 | **200**，40KB HTML，Set-Cookie ✓ |
| 另测 | `\p{ID_Continue}` ✓、node v22.20.0 ✓、三个原生 addon platform=2 ✓ |

核心解锁点：**越狱机给不了 JIT**，必须 `--jitless`；而 `--jitless` 会把 `WebAssembly` 整个关掉，
Node 自带 undici（`fetch` / `node:http` 的 `WebSocket`）在**模块加载期**就要 `WebAssembly.compile`，
于是 dsh 直接 `fatal load failure`。解法是预载 `shim/wasm-fake.cjs`（假 WebAssembly，只保证加载能过）。

**出站 HTTP 也通了**（2026-11-27 20:55）：`shim/fetch-http.cjs` 用 `node:http/https` 实现了
Fetch 子集（真 ReadableStream 的 body、gzip/deflate/br 解压、redirect follow/manual/error、
跳转时带 cookie、AbortSignal），设备实测：https 拉到 180KB 正常、SSE 逐块读正常、
`/?token=` → 303 → 带 cookie → **200 + 40102 字节 HTML**。

**真跑通了一轮对话**（2026-11-27 22:07）：用 ACP（JSON-RPC over stdio，`dsh --profile acp`）在设备上
`initialize` → `session/new` → `session/prompt`，模型答完 `stopReason: end_turn`，
收到 **4279 字符**正文，首字 22s、总 30.8s。中途修了三处：

1. **`process.platform` 谎报 darwin**：设备上报 `ios`，`@deepseek-ai/node-addon-system` 的 flock
   只认 linux/darwin，直接 `ERR_FLOCK_UNSUPPORTED_PLATFORM` → 会话持久化失败。已在
   `shim/ios-preload.cjs` 里统一改成 darwin/arm64。
2. **原生 addon 路径沙箱**：从 `/var/mobile/Library/dsh/app/node_modules/*.node` dlopen 会报
   `file system sandbox blocked mmap()`；从 `/var/jb/...` 加载正常。解法：
   `deploy/device/relocate-addons.sh` 把 12 个 `.node` 搬到 `/var/jb/usr/local/lib/dsh/addons/`，
   原位置留符号链接（幂等）。`jbctl trustcache add` 和 `ldid` 重签都**不解决**这个。
3. **模型凭证**：`/var/mobile/Library/dsh/env.sh`（600）里放 `DEEPSEEK_API_KEY`，
   `boot-start.sh` 启动前 source；引擎日志可见 `model listing ... loaded 2 model(s)`。

**bash 工具也打通了**（2026-11-27 22:25）：原来失败是因为 iOS 上没有沙箱后端
（`dsh-sandbox-local` 按平台选 runner 链：linux=[bwrap,landlock]、darwin=[seatbelt]，iOS 一条都没有 → fail closed）。
不需要改代码：`dsh-bash-sandbox` 在 `sandboxPolicy.mode === "danger-full-access"` 时**直接跳过限制**，
而 profile 里的 approval 策略本来就是 `DSH_PERMISSION_MODE ?? 'workspace-write'`。
所以只要 `env.sh` 里加 `DSH_PERMISSION_MODE=danger-full-access`，bash / read / write / glob / web_fetch 全部可用（已实测）。

**常驻也解决了**（2026-11-27 21:15）。关键有两条，缺一不可：

1. **`ExecuteAllowed`**：Procursus 的 launchd 对 `/var/jb` 下的作业要求 plist 里带
   `<key>ExecuteAllowed</key><true/>`，否则**任何**作业（连 `/bin/sleep`）都是 `78 EX_CONFIG`。
2. **作业只负责 nohup，不负责运行**：launchd 作业的进程自身带着 per-process jetsam 限额
   （dsh 常驻 ~250MB，128MB 堆也超），但 `nohup` 出去、`ppid` 变成 1 的子进程不受该限额约束。

所以最终形态是 `/var/jb/Library/LaunchDaemons/com.dsh.bootstrap.plist` → 跑
`/var/mobile/Library/dsh/boot-start.sh`（幂等）→ nohup 出引擎 → sh 自己退出；
`StartInterval=120` 让这个作业每两分钟复查一次，引擎挂了就重新拉起。
实测：引擎 pid 2794、`ppid=1`、RSS 244MB，跨过心跳仍在，`GET /` = 401。

## 手机操控 & 插件安装（2026-11-27 23:00）

**手机操控已打通并验证**（`mcp__ios__*`）：
- 来源：`com.witchan.ios-mcp`（tweak，注入 SpringBoard；装核心 dylib 即可，跳过 installd/frontboard 钩子）
- 位置：`/var/jb/Library/MobileSubstrate/DynamicLibraries/ios-mcp.{dylib,plist}`，respring 后生效
- 服务：`http://127.0.0.1:8090/mcp`（`/health` 200），工具：screenshot / tap_screen / tap_element /
  swipe_screen / get_screen_info / get_clipboard / set_clipboard / launch_app / type_text / wake
- 实测：读屏（414×896pt / 828×1792px @2x）、剪贴板写入读回 `dsh-on-ios-ok`、
  `launch_app com.apple.Preferences` 并确认 frontmost
- 注册：`profiles/*/cordis.patch.yml`，**必须写在 `insert:` 下面**（只写 id/name 会被当成改已有插件而忽略）：
  ```yaml
  - insert:
      - id: mcp-ios
        name: "@deepseek-ai/dsh-mcp-client"
        config: { transport: streamable-http, serverName: ios, url: "http://127.0.0.1:8090/mcp" }
  ```

**pnpm 装好了但 `dsh plugin` 还起不来**：
- `pnpm 10.18.0` 在设备上直跑正常（`/var/jb/usr/bin/pnpm` 目前是临时 shell 包装器）
- 但 `dsh plugin` → `execa` → `spawn("pnpm")` 报 **EPERM**：这台设备上 **node 无法 spawn 脚本**
  （实测 `spawn("/var/jb/usr/bin/ls")` OK，`spawn("/tmp/t1.sh")` EPERM）；另外设备上**没有 `/bin/sh`**
- 解法：把 pnpm 命令做成 **Mach-O 启动器**（`launcher/pnpm.c`，execv 到 node + pnpm.cjs），
  用 `build-jitlaunch.yml` 编出来，装到 `/var/jb/usr/bin/pnpm`
- **在那之前插件安装已经可用**：`deploy/device/add-plugin.sh`（设备上 `/var/mobile/Library/dsh/add-plugin.sh`）
  直接 cd 进 profile 跑 pnpm，绕开 `dsh plugin` 的 spawn。实测：
  `add-plugin.sh web add is-odd@3.0.1` → 2.8s 装好，`ls` 能看到，`remove` 后干净，lockfile 正常写入。

## dsh-purge 插件（2026-11-27 23:35，能跑）

`zpjio/dsh-purge@1.1.71` 是纯 JS、零依赖、engines>=18，iOS 上能装能跑，已装进
`profiles/web` 和 `profiles/acp` 的 node_modules，并在两边的 `cordis.patch.yml` 里 insert 了
`dsh-purge` / `dsh-purge-redteam[-store|-ui]`。

装法（绕开 `dsh plugin`，因为它 spawn 脚本会 EPERM）：
```sh
cd /var/mobile/Library/dsh/profiles/web && pnpm add /tmp/dsh-purge.tgz
```

**必须改两处才能跑**（否则每轮对话直接失败）——`deploy/device/patch-purge-persona.sh` 已封装，幂等：
1. `node_modules/dsh-purge/cordis.patch.yml`：`personaSuffix: Your working directory is {{cwd}}.` → `""`
2. `node_modules/dsh-purge/lib/identity.js`：`{{cwd}}` → `the session workspace`
原因：本机 dsh 只注册了 `{{provider}}`/`{{model}}` 两个提示词变量，`{{cwd}}` 会报
`unknown prompt variable "{{cwd}}" in section "deployment:persona-suffix"`。
> pnpm 重装插件会覆盖这两处，重装后再跑一次脚本。

另外：插件自带的 patch 里那条「`- id: dsh-purge` + `inject:`」是**改已有条目**，
本机 profile 没有该条目 → `patch: entry "dsh-purge" not found`，要删掉，只保留 `insert:` 里的定义。

实测：ACP 里让 agent 调 `purge_status`，返回真实状态（surface: web），工具注册成功。

## 关键坐标

| 项 | 值 |
|---|---|
| 代码仓库 | `lifeifan10087/dsh-iOS`（GitHub，默认分支 main） |
| 需要凭证 | classic PAT，勾 `repo` + `workflow`（每次新会话由用户重新提供） |
| 构建入口 | `build/build-node-ios.sh`，workflow `.github/workflows/build-node-ios.yml` |
| 最近一次构建 | run `44999614926` → **success**（v22.20.0 + ICU，产物 226.8MB kit） |
| 上一次构建 | run `44992516975` → failure：只差最后链接（见坑表 CoreFoundation 那条） |
| 产物 | `out/node-ios-patched`（110MB，platform=2）、`out/node_modules.tgz`（183MB） |
| 一键包 | `out/dsh-go_0.2.4_iphoneos-arm64.deb`（含 wasm 替身）；手机侧 `/sdcard/Download/DSH-Go/` |
| 设备 node | `/var/jb/usr/local/lib/dsh/node`（22.20.0，旧版备份 `node.bak-<时间戳>`） |
| 设备替身 | `/var/mobile/Library/dsh/shim/{ios-preload,wasm-fake,fetch-http}.cjs` |
| 自启作业 | `/var/jb/Library/LaunchDaemons/com.dsh.bootstrap.plist`（`ExecuteAllowed` + `StartInterval=120`） |
| 自启脚本 | `/var/mobile/Library/dsh/boot-start.sh`（幂等，已在跑就跳过） |
| 手动启动 | `deploy/start-engine.sh`（SSH 版） |
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
| launchd 作业一律 `78 EX_CONFIG`（连 `/bin/sleep`） | Procursus launchd 要求 plist 带 `ExecuteAllowed` | 加 `<key>ExecuteAllowed</key><true/>` |
| 作业能起但立刻 `JETSAM_REASON_MEMORY_PERPROCESSLIMIT` | 作业进程自身带 per-process 限额，dsh 常驻 ~250MB 超了 | 作业改成「nohup 出引擎后自己退出」，孤立的子进程不受限；`StartInterval` 做看门狗 |
| `ERR_FLOCK_UNSUPPORTED_PLATFORM`（会话持久化失败） | `process.platform === "ios"`，flock 只认 linux/darwin | 预载里把 platform/arch 谎报成 darwin/arm64（darwin 那套 addon 已改成 platform=2） |
| bash 工具 `SANDBOX_UNAVAILABLE` / 命令失败 | iOS 没有 bwrap/landlock/seatbelt，`dsh-sandbox-local` 的 runner 链为空 → fail closed | `DSH_PERMISSION_MODE=danger-full-access`（此时 `dsh-bash-sandbox` 直接跳过限制，不改代码） |
| `dsh plugin` → `spawn pnpm EPERM` | 设备上 node 不能 spawn **脚本**（shebang），且没有 `/bin/sh` | pnpm 必须是 Mach-O 启动器（`launcher/pnpm.c`） |
| tweak 装完 8090 没起来 | dylib 需要 respring 才加载 | `killall -9 SpringBoard`，等 15s 再查 `/health` |
| `file system sandbox blocked mmap()` 加载 `.node` | 沙箱只允许从 `/var/jb` 之类的越狱路径映射可执行页 | `deploy/device/relocate-addons.sh` 搬到 `/var/jb/usr/local/lib/dsh/addons/` + 原处符号链接；`trustcache add`/`ldid` 都无效 |
| `ECONNRESET` / `Error: aborted` 崩进程 | 替身里用 `res.destroy()` 收尾、或 `Readable.toWeb` 时没人接 `res` 的 `error`/`aborted` 事件 | 用 `Readable.toWeb` + `res.on("error"|"aborted", ()=>{})`；跳转时留空的 error 监听（`emit('error')` 无监听会变成 uncaughtException） |
| 带 token 仍 401 | `/?token=` 是 303 + Set-Cookie，客户端必须带 cookie 再请求 | 替身在同源跳转时把 `set-cookie` 合进 `cookie` 头 |
| `Bus error: 10`（不带 `--jitless`） | 越狱机没有 JIT 授权；`jbctl proc_set_debugged`（CS_DEBUGGED）和 `jbctl trustcache add` **都不管用**，jitprobe 实测 `MAP_JIT` 返回 EINVAL；崩溃报告显示 `KERN_PROTECTION_FAILURE` 在 `Builtins_InterpreterEntryTrampoline` | 只能 `--jitless`（保留 `launcher/jitlaunch.c` 作为记录，不再依赖它） |
| `ReferenceError: WebAssembly is not defined` → `dsh: fatal load failure` | jitless 下 V8 关掉 WebAssembly，undici 模块加载期就要它 | 预载 `shim/wasm-fake.cjs`（`--require`），加载能过；真解析仍不可用（见下一步） |
| launchd 启动返回 `78 EX_CONFIG` | 用 shell 脚本当 `ProgramArguments[0]` 时被判配置错误 | plist 里**直接写 node 的绝对真实路径**（`readlink -f /var/jb/...`），参数全部展开 |
| 守护进程被杀，`last exit reason = JETSAM_REASON_MEMORY_PERPROCESSLIMIT` | iOS 给 LaunchDaemon 的 per-process 内存上限很低 | 未解决：`--max-old-space-size=384` 仍被杀；临时靠 `nohup` 脱离会话跑（pid 的 ppid=1 能活过 SSH 断开），重启失效 |
| 设备上 `sudo` 拿不到密码 | 远程单引号里 `echo $SSHPASS` 在设备侧是空的 | 本机 `printf '%s\n' "$IPHONE_PASS" \| sshpass -e ssh ... 'sudo -S -p "" ...'`，把密码喂给 ssh 的 stdin |
| 设备上 `system()` 不可用 / 无 `awk` `setsid` `file` | iOS SDK 与精简 userland | 原生代码改用 `posix_spawn`；脚本里只用 `sed/cp/mv/chmod/ldid/tar` |
| `api.github.com` 间歇 `ECONNABORTED`/握手超时 | 大陆线路抖动（`github.com`/`raw.githubusercontent.com` 完全不通，`api`+`codeload` 通） | `deploy/gh-put.mjs`、`deploy/fetch-artifact.mjs` 都已带重试；不要用 `git push` |

## 阻塞项（2026-11-22 记）

- **设备 SSH 不通**：`192.168.10.229` 完全超时（旧地址/已关机）；`192.168.10.230` 的 62078
  lockdown 开着、22 端口 refused → 是那台 iPhone，但 sshd 没起来（越狱插件没开或重启后未激活）。
  探段命令：`node deploy/discover-iphone.mjs 192.168.10`（或 `node /tmp/scan.mjs 192.168.10` 扫 22/62078/3080）。
- 不依赖 SSH 的路子：把 `out/dsh-go_0.2.3_iphoneos-arm64.deb` 拷进手机，Filza/Sileo 点装，
  postinst 自动起引擎并把 token 写到 `/var/mobile/Documents/dsh-url.txt`。
- 本机出口网段会漂：2026-11-22 是 `10.111.33.x`（跟手机不同网段），11-27 回到 `192.168.10.216`。

## 下一步（按顺序，2026-11-27 21:00 更新）

1. ~~常驻~~ 已解决（见「一句话状态」）。**待验证**：重启设备后是否自动起来 —— 这设备是半绑定越狱，
   重启后要先在越狱 App 里重新激活，launchd 才会加载 `/var/jb/Library/LaunchDaemons`；届时顺带确认
   引擎自动上线（`com.dsh.bootstrap` 的 `RunAtLoad`）。
2. ~~模型调用实测~~ 已完成（ACP 跑通一轮，见上）。下一步：**修 dsh 的 bash 工具**（沙箱后端在 iOS 不可用），
   让 agent 真能执行命令；顺带看长上下文（1M）下的内存表现。
3. 装 ios-mcp（`/tmp/ios-mcp.deb` 重启后已清空，需重下）→ `cordis.patch.yml` 接 `mcp-ios`。
4. 一把梭脚本 `deploy/after-build.sh` 里 deb 版本号还是 0.2.2，改成从产物读。

## 旧计划（已完成的部分留着备查）

0. ~~盯构建 + 取产物~~ 已完成：`node deploy/fetch-artifact.mjs lifeifan10087/dsh-iOS dsh-ios-kit 44999614926`
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
