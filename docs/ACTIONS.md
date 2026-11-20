# 零 Mac 落地：GitHub Actions 编 → 手机部署到 iPhone

设备：iOS 26.0.1 + Dopamine（rootless，前缀 `/var/jb`）。
部署机：**就是这台 Android 手机**（已装 `ssh/scp/sshpass`，不用电脑）。

## 0. 准备

- GitHub 账号 + PAT（Settings → Developer settings → Tokens(classic)，勾 `repo` + `workflow`）
- iPhone 与手机连同一个 Wi-Fi；Dopamine 环境里 `openssh-server` 正常（默认 `root` / `alpine`）
- iPhone 上装 `ldid`（Sileo 里 `apt install ldid openssh-server`，一般越狱自带）

## 1. 建一个空仓库（30 秒）

网页上 New repository → 名字随便（如 `dsh-ios`）→ **不要**勾 README/.gitignore → Create。

## 2. 推代码 + 自动触发编译

```bash
cd /sdcard/Download/DSH-Go/ios-port
GITHUB_TOKEN=ghp_xxxxxxxx bash deploy/push-to-github.sh 你的用户名/dsh-ios
```

脚本会：`git init` → 提交 → 推送 → 调 API 触发 `build-node-ios`
（默认 `NODE_VER=v24.9.0 MIN_IOS=14.0`，要改就前置环境变量）。

进度页：`https://github.com/<你>/dsh-ios/actions`，约 **40 分钟**（V8 最慢）。

## 3. 取产物（编完后）

```bash
GITHUB_TOKEN=ghp_xxxxxxxx node deploy/fetch-artifact.mjs 你的用户名/dsh-ios
```

解到 `out/`：

| 文件 | 说明 |
|---|---|
| `node-ios-patched` | arm64-iOS 的 Node 24，platform 已改成 IOS 并签名 |
| `node_modules.tgz` | dsh 依赖（按 darwin-arm64 解析，原生件已改平台号，addon 已套 JS 替身） |

## 4. 部署到 iPhone

```bash
SSHPASS=alpine DEVICE=root@192.168.1.23 bash deploy/install-ios.sh out/node-ios-patched
```

内部顺序：推 node → `ldid` 带 JIT entitlement 签名 → 推 kit + 依赖 → `scripts/ios-init.sh`
（装引擎、套替身、写 `com.dsh.engine.plist` 到 `/var/jb/Library/LaunchDaemons`）→ 打印 token 地址。

端口不是 22 就加 `PORT=2222`；用密钥就把 `SSHPASS=` 去掉。

## 5. 验收

```bash
SSHPASS=alpine ssh root@<iphone> 'node -p process.platform+"/"+process.arch'
# 期望 darwin/arm64
SSHPASS=alpine ssh root@<iphone> 'node -e "require(\"node:sqlite\");console.log(\"sqlite ok\")"'
```

最后 iPhone 上用 `shell/` 编的 DshGo，或 Safari 打开日志里 `http://127.0.0.1:3080/?token=...`。

## 6. iOS 26 + Dopamine 专属说明

- 路径全是 `/var/jb`，脚本自动识别，rootful 也能跑
- JIT 依赖越狱层的签名豁免；node 一启动就 `SIGKILL`/`bus error` 时，先在
  `/var/jb/usr/local/bin/dsh-ios` 里加 `--jitless` 验证是否 JIT 问题（慢 3–10 倍，WASM 不可用）
- `ldid` 报 `signature error` 时：`apt install ldid` 后再 `ldid -S/var/jb/tmp/ent-dsh.plist /var/jb/usr/bin/node`
- iOS 26 的 ATS 不影响 127.0.0.1；壳里已开 `NSAllowsLocalNetworking`
- 后台靠 launchd `KeepAlive`；被系统更新破坏越狱后重跑第 4 步即可

## 7. Actions 侧失败树

| 现象 | 处理 |
|---|---|
| Preflight ✗ 缺 SDK | runner 是 macos-14，自带 Xcode；重跑一次 |
| 编译 OOM/超时 | 把 `JOBS` 降为 4，或 timeout-minutes 提到 180 |
| `patch-macho-ios` 失败 | 工作流会回退用未改平台号的产物；这时设备上手动 `ldid -S` 再试 |
| artifact 过期（14 天） | 重跑 workflow |
| `brew install ldid` 慢 | 已 `|| true`，不阻塞 |
