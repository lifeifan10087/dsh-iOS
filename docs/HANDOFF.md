# 交接说明（下一步只差外部条件）

## 已完成

| 模块 | 状态 | 证据 |
|---|---|---|
| 可行性 | ✅ | 本机把 platform 谎报成 darwin 后 `dsh web` 正常监听、401 正常 |
| 原生 addon 替身 | ✅ | `--expose-internals` + JS 替身，5 个内部模块全部拿到 |
| 构建脚本 | ✅ | 两阶段（macOS 工具 + iOS 目标），干跑测试通过 |
| 补丁脚本 | ✅ | `patch-host-mk.py` / `patch-macho-ios.py` / `skip-generated.py` 均有单测 |
| 依赖包 | ✅ | 132MB，darwin-arm64 原生件已改成 iOS 平台号（platform=2 已验证） |
| 设备部署脚本 | ✅ | `deploy/install-ios.sh`，支持 key/密码、rootless 自动识别 |
| CI 配置 | ✅ | GitHub Actions / Codemagic / Azure 三套 |
| Node 版本下限 | ✅ | 18 不行（缺 `util.parseEnv`），22 起，推荐 24 |

## 两个外部阻塞

1. **GitHub 账号 `lifeifan381` 被封** → Actions 不可用
   - 申诉材料：`docs/APPEAL.md`
   - 或改用 Codemagic（`codemagic.yaml`，邮箱注册即可）／Azure（`azure-pipelines.yml`）
2. **iPhone 未开 SSH** → 扫描 `192.168.10.0/24` 无 22 端口
   - 需要：Sileo 安装并启动 `openssh-server`，默认 `root` / `alpine`

## 解封后第 1 分钟要做的

```bash
# 有 GitHub 了
GITHUB_TOKEN=xxx bash deploy/push-to-github.sh <user>/dsh-ios
GITHUB_TOKEN=xxx node deploy/fetch-artifact.mjs <user>/dsh-ios

# 或任何 Mac 上
NODE_REF=update22-9-0 bash build/build-node-ios.sh
bash build/patch-macho-ios.sh out/node-ios-arm64

# 部署（iPhone 已开 SSH）
SSHPASS=alpine DEVICE=root@<iphone-ip> bash deploy/install-ios.sh out/node-ios-patched
```

## 验收标准

```bash
node -p 'process.platform + "/" + process.arch'   # darwin/arm64
node -e 'require("node:sqlite")'                  # Node 22 需 --experimental-sqlite
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/   # 401
```
