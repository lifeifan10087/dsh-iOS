# 交接：把官方 dsh-go（Flutter）搬到 iPhone —— 进度与下一步

更新时间：2026-11-28 23:40（Asia/Shanghai）

## 一、总体目标

在越狱 iPhone（iOS 26.0.1，iPhone12,1，Dopamine rootless，jbroot=/var/jb）上运行 **官方 dsh-go** 的原生界面，并连上本机 DSH 引擎正常对话。

当前状态：**界面已完全跑通，卡在最后一层——App 的沙箱禁止网络（EPERM）**。

## 二、设备与访问

| 项 | 值 |
|---|---|
| iPhone IP | `192.168.10.229` |
| SSH | `mobile@192.168.10.229`，密码 `518111`（`sudo` 用同一密码） |
| 凭证文件 | `/root/workspace/ios-port/.secrets.env`（`IPHONE_USER` / `IPHONE_PASS` / `IPHONE_IP` / `GITHUB_TOKEN`） |
| SSH 用法 | `printf '%s\n' "$IPHONE_PASS" \| sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@$IPHONE_IP '…'`；需要 root 时 `sudo -S -p "" /var/jb/bin/sh -c "…"` |
| Android 侧 | `192.168.10.216`（本机），可起 `python3 -m http.server 9110` 给手机拉文件 |

## 三、两个 App（都在 TrollStore 里）

| Bundle ID | 名称 | 状态 |
|---|---|---|
| `com.dsh.go.shell` | DSH Go 0.2.2（我写的 SwiftUI 原生客户端） | **完全可用**：发消息/流式/工具卡片/会话抽屉/主题/文件跳转 |
| `io.github.ccch1mneyyy.dshgo` | DSH Go 1.4.x（官方 Flutter，我们自己编译的） | 界面可用，**连接时 EPERM** |

## 四、官方 Flutter 版是怎么来的

1. 源码：`https://github.com/ccch1mneyyy/dsh-Go`（Flutter monorepo，`app/` 下含 `app/ios/Runner.xcworkspace`）
2. 我们仓库 `lifeifan10087/dsh-iOS` 的 `.github/workflows/build-dshgo-flow.yml`：
   - `macos-15` runner + 最新 Xcode + `subosito/flutter-action`
   - `flutter build ios --release --no-codesign`
   - 打包 `Payload/Runner.app` → `DshGoFlow.ipa`
3. 该 workflow 里用 python 注入的**源码补丁**（都在跑，别丢）：
   - 顶栏加「+ 添加主机」按钮（绕开小屏够不到的底部入口）
   - `ssh_host_form.dart` 预填：名称「本机」/主机 `127.0.0.1`/用户 `mobile`/令牌/端口 3081/`attachOnly`
   - 密码通过 `workflow_dispatch` 输入 `ssh_password` 注入（**不落库**，日志 `::add-mask::`）
   - 表单底栏 `bottom + 44`（离开 Home 指示条手势区）
   - 列表底部留白 `+120`
   - 去掉 DSH Remote 的 `RelayCredit` 页脚（它的大热区会吞掉主机行的点击）
   - `ssh_transport.dart` 把真实 socket 错误拼进提示（诊断用，可保留）
   - 版本号自增（TrollStore 不接受同版本覆盖，会误报 Parse Error 301）

## 五、部署到手机的流程（TrollStore 装不上时的替代方案）

TrollStore Lite 现在装任何 IPA 都报 `Parse Error 301`（连之前成功过的包也报）→ 用**手工替换**绕过：

```sh
# 1) Android 侧打包（把 CI 产物里的 Payload/Runner.app 打成 tar）
cd /tmp/x && tar czf /sdcard/Download/DSH-Go/flowNN-app.tar.gz Payload/Runner.app
# 2) 起 HTTP
cd /sdcard/Download/DSH-Go && nohup python3 -m http.server 9110 --bind 0.0.0.0 &
# 3) 手机上用 node 拉（脚本 /tmp/getNN.mjs，模板见 deploy/）
sudo /var/jb/usr/local/lib/dsh/node --jitless \
  --require /var/mobile/Library/dsh/shim/ios-preload.cjs /var/mobile/Library/dsh/tmp/getNN.mjs
# 4) 部署脚本 /var/mobile/Library/dsh/tmp/deploy14.sh：解包→替换 Runner.app→
#    chmod 755 目录 / 644 文件 / Runner 与 Frameworks 可执行→ ldid -S<ent.plist> →
#    chown -R _installd:_installd → uicache -p
```

entitlements 文件：`/var/mobile/Library/dsh/tmp/ent.plist`（不含 no-sandbox，能启动）

## 六、卡点（唯一剩下的）

- 点「本机」→ 提示 `127.0.0.1:22 没有响应 [Operation not permitted]`
- 源码定位：`app/lib/remote/ssh/ssh_transport.dart` 的 `describeSocketError` 兜底分支 → 真实原因是 **EPERM**
- 结论：**App 运行在沙箱里，socket 被拒**。TrollStore 安装时会注入 entitlements + 把 App 加进 launchd 免沙箱名单；我们手工替换二进制只做了签名，没做第二件事
- 试过 `com.apple.private.security.no-sandbox`（单独/带 container-required=false 两种）→ **AMFI 拒绝，App 起不来**，已回滚

## 七、下一步（按顺序）

1. **修好 TrollStore Lite 的安装能力**（当前它对所有 IPA 报 301）：
   - 它是 `/var/jb/Applications/TrollStoreLite.app`，可尝试 `uicache -a` + respring、或重装它自身
   - 修好后用 TrollStore 重装 `DshGoFlow*.ipa`（此时会正确注入权限 + 免沙箱）
2. 打开 App → 引导页「继续」→ 点「本机 mobile@127.0.0.1」→ 首次会弹指纹确认 → 信任
3. 进聊天界面后发一条消息验证（引擎在 3080，代理 3081，token 在 `/var/mobile/Library/dsh/.web-url`）
4. 若 TrollStore 修不好：改它的传输层，把 `HostKind.ssh` 换成直连 `http://127.0.0.1:3081`（跳过整个 SSH 客户端）

## 八、服务端现状（iPhone 上）

| 组件 | 说明 |
|---|---|
| 引擎 | `dsh web --host 127.0.0.1 --port 3080`，token 写在 `/var/mobile/Library/dsh/.web-url` |
| 代理 | `auth-proxy.mjs` 监听 3081：自动换 cookie、**覆盖 `?token=`**、**剥掉 Authorization/x-*-token 头**（引擎重启后 token 变化不影响客户端） |
| tweak MCP | 8090（`get_screen_info`/`ocr_screen`/`tap_screen`/`launch_app`/`run_command`…），从 Android 用 `node /tmp/mcp2.mjs <tool> '<json>'` 调 |
| 引擎重启 | `sudo /var/jb/bin/sh /var/mobile/Library/dsh/boot-start.sh`；重启后记得把 `.web-url` 更新成新 token（`start-engine.sh` 里可从日志抓） |

## 九、已知坑（血泪）

- `killall -9 node` 会连引擎一起杀掉（代理和引擎都是 node）→ 杀进程前先看 args
- `killall cfprefsd` 会破坏 `/var/jb/bin/sh` 符号链接 → SSH/命令通道全废；修复靠 Dopamine「重启用户空间」
- iOS 偏好是 cfprefsd 缓存的，直接写 plist 常被覆盖；要生效得 kill Runner + killall cfprefsd 再启动（且不一定成功）
- 合成触摸（IOHID）打不进 Flutter 的某些 `Stack/Positioned` 底栏；无障碍 `tap_element` 返回 tapped 但不触发 onPressed → 这类按钮**只能真手指点**
- TrollStore 同版本覆盖会误报 `Parse Error 301`；改版本号能过，但后来连改版本也失效 → 那是 TrollStore 自身状态脏了
