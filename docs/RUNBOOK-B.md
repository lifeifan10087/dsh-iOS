# 路线 B：把 Node 24 编到 iOS 上（可执行手册）

目标：`/var/jb/usr/bin/node` 是 arm64-iOS 的 Mach-O，`process.platform === 'darwin'`，
`dsh web` 起来后 iPhone 本机就能打开 `127.0.0.1:3080`。

## 0. 前提（二选一）

| 方式 | 命令 | 说明 |
|---|---|---|
| 自己的 Mac | `bash build/preflight.sh` | 需要 Xcode + iOS SDK，磁盘 ≥25GB |
| 没有 Mac | 把整个 `ios-port/` 推到 GitHub，Actions 里跑 `build-node-ios` | macos-14 runner 免费额度够编一次（~40 分钟） |

预检必须全绿再往下。

## 1. 编 Node（20–60 分钟）

```bash
NODE_VER=v24.9.0 bash build/build-node-ios.sh      # 产物 out/node-ios-arm64
bash build/patch-macho-ios.sh out/node-ios-arm64   # 平台号改成 ios + ldid 签名
```

关键设定（脚本里已固化）：

- `--dest-os=mac` 走 Darwin 分支，**不改 configure**，只把目标三元组换成 `arm64-apple-ios14.0`
- `--without-snapshot`：交叉编译时 mksnapshot 跑不起来，先不要 snapshot
- `--without-intl --without-npm --without-corepack --without-inspector`：省体积、少依赖
- `--openssl-no-asm`：iOS 上避免 asm 的 `__ios__` 分支问题（要开就 `OPENSSL_ASM=1`）

失败树：

| 现象 | 处理 |
|---|---|
| `-framework ... not found` | 在 `node.gyp` 的 `xcode_settings.libraries` 里剔掉该框架 |
| `error: unknown OS_IOS` / V8 报 OS 未定义 | `CFLAGS="$CFLAGS -DV8_OS_IOS"` 重跑 |
| 链接报 `-ldl` | `apply-ios-overrides.py` 已剔；再报就手动删 |
| `mksnapshot` 执行失败 | 确认 `--without-snapshot` 生效（configure 输出里能看到） |
| 产物 `file` 显示 Mach-O 但设备拒载 | 用 `vtool -show-build` 确认 `platform IOS`，再 `ldid -S build/entitlements.plist` |

## 2. 备依赖 + 装到设备

设备上的 node 没带 npm，所以依赖在 Mac 侧备好再推（顺带把 darwin 二进制改成 iOS 平台号）：

```bash
bash deploy/bundle-node-modules.sh     # 产出 out/node_modules.tgz
DEVICE=root@192.168.1.20 bash deploy/install-ios.sh out/node-ios-arm64
```

它会：推 node → `ldid` 带 JIT entitlement 签名 → 推移植包 → 跑 `scripts/ios-init.sh`
（装引擎、套 addon JS 替身、写 launchd 常驻）→ 打印 `?token=` 地址。

## 3. 验收清单

```bash
node -p 'process.platform + "/" + process.arch'        # darwin/arm64
node -p 'process.versions.v8'                          # 有版本号 = V8 起来了
node -e 'require("node:sqlite")'                       # 会话检索依赖，24 才有稳定版
node -e 'console.log(require("child_process").execSync("id").toString())'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/     # 401 = 正常
```

全过之后：iPhone 上开 `shell/` 编的 DshGo，或 Safari 打开日志里那行带 token 的地址。

## 4. 可选增强

```bash
bash build/build-node-pty-ios.sh    # 持久终端；不装则只缺 tmux 式交互，bash 工具照常用
```

- 文件搜索：`apt install ripgrep`（Procursus），或自编后指给 `dsh`
- 语音：`sherpa-onnx` 有官方 iOS xcframework，替换 `sherpa-onnx.node` + dylib 后重签
- 图像：`sharp` 需要 libvips，先跳过，缺失会自动降级

## 5. JIT 与后台

- 有 JIT（`allow-jit` entitlement + 越狱签名）→ 正常速度
- 无 JIT → `node --jitless`：能跑，慢 3–10 倍，WASM 不可用
- 常驻靠 `com.dsh.engine.plist`（KeepAlive）；iOS 会杀普通 App 后台，daemon 不会
- 内存：脚本给了 `--max-old-space-size=2048`，jetsam 紧张时降到 1024

## 6. 回滚

```bash
launchctl bootout system /var/jb/Library/LaunchDaemons/com.dsh.engine.plist
rm -f /var/jb/usr/bin/node /var/jb/usr/bin/dsh-ios
rm -rf /var/mobile/Library/dsh
```
