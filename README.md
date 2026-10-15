# ACU

[English](README_EN.md) | [更新日志](CHANGELOG.md)

ACU（Automation / Agent Continuity Utility）是一个 macOS 菜单栏工具，在 UI 自动化
客户端运行期间提供应用层
模拟锁屏：

- 空闲时轻微移动并恢复鼠标，降低系统因空闲自动锁屏的概率；
- 可单独启用防锁屏活动维护，不显示遮罩或拦截输入；
- 使用全屏保护层遮挡全部显示器；
- 拦截物理输入，同时无需白名单地放行软件合成输入；
- 通过 macOS 原生 Touch ID 或系统密码认证解除保护。

它不是 macOS 真锁屏，不抵御进程终止、管理员权限或机器重启。
检测到 macOS 进入真实锁屏后，ACU 会自动解除模拟锁屏，避免系统解锁后仍被模拟遮罩拦住；ACU 不会尝试解锁 macOS。

界面支持简体中文和英文，并跟随 macOS 的首选语言；修改语言后需要重新启动 ACU。

## Homebrew 安装

```sh
brew tap rectcircle/acu https://github.com/rectcircle/acu
brew install --cask rectcircle/acu/acu
/usr/bin/xattr -dr com.apple.quarantine /Applications/ACU.app
```

升级到最新版本：

```sh
brew upgrade --cask rectcircle/acu/acu
/usr/bin/xattr -dr com.apple.quarantine /Applications/ACU.app
```

当前发布包使用 ad-hoc 签名，未经 Apple 公证。第二条命令显式调用 macOS 系统自带的
`/usr/bin/xattr`，递归移除 ACU 的 quarantine，绕过该应用的 Gatekeeper 首次运行
检查；它不会全局关闭 Gatekeeper，也不会自动授予辅助功能等权限。Cask 固定版本和
SHA-256，但仍应仅在信任本仓库及其发布产物时执行。

如果不信任预编译产物，请勿移除 quarantine。可以先让代码 Agent 审查源码，
重点检查 `Casks/acu.rb`、`internal/macos` 和 `scripts/build-app.sh`，然后从固定标签
本地编译：

```sh
git clone https://github.com/rectcircle/acu.git
cd acu
git checkout v0.1.3
go test ./...
./scripts/build-app.sh
open "build/ACU.app"
```

## 手动安装

从下一版本的 [GitHub Release](https://github.com/rectcircle/acu/releases) 下载
`ACU-<版本>-macos-universal.dmg`，双击打开后，将 `ACU.app` 拖到 `Applications` 快捷方式即可安装。
Release 也会同时提供同名 `.tar.gz` 归档。应用使用 ad-hoc 签名；磁盘映像本身未签名，
两者均未经 Apple 公证。若 macOS 阻止打开安装包或应用，请只在确认信任发布产物后，
按系统提示允许打开，或移除应用 quarantine：

```sh
/usr/bin/xattr -dr com.apple.quarantine /Applications/ACU.app
```

本地编译会重新生成可执行文件并进行 ad-hoc 签名，通常不会带有下载文件的 quarantine。

## 构建

要求 macOS 15 或更高版本、Go 1.22 或更高版本以及 Xcode Command Line Tools。

```sh
./scripts/build-app.sh
open "build/ACU.app"
```

生成同时支持 Apple Silicon 和 Intel Mac 的发布归档和拖拽安装 DMG：

```sh
./scripts/package-release.sh 0.1.3
```

推送 `v0.1.5` 格式的标签后，GitHub Actions 会自动测试、构建
`ACU-<版本>-macos-universal.tar.gz`、`ACU-<版本>-macos-universal.dmg` 及各自的 SHA-256 文件，并创建**草稿 Release**，此时不会公开发布或更新 Homebrew。
Release Notes 来自 `CHANGELOG.md` 中对应版本的双语章节；缺少该版本时构建会失败。

草稿生成后，先由用户下载并验证 `.dmg` 和归档。只有用户明确授权发布后，才打开
**Actions → Release → Run workflow**，选择 `main`，在 `version` 中输入对应标签（如
`v0.1.5`）。流水线会核对草稿中两个产物的 SHA-256，公开 Release，并更新 Homebrew Cask
（Cask 使用 `.tar.gz` 归档），不会重新构建。公开发布后的版本不会被 tag 构建任务覆盖；修复应使用新版本标签。
旧版本手动公开不会覆盖更新版本的 Cask，也不会被标记为最新 Release。
公开后，Homebrew 更新与夸克镜像分别执行；夸克仅在暂存文件全部回读校验通过后展示新版本。
首次配置、明确授权后的发布入口及失败补传见 [发布维护指南](document/releasing.md)。
GitHub 或 Homebrew 访问慢，可选择：[夸克网盘](https://pan.quark.cn/s/06f55e51fddb?pwd=rv8F)（提取码：`rv8F`，永久分享）。
网盘按版本分目录，提供 `.dmg`、`.tar.gz` 及各自的 `.sha256`，与 GitHub 原始文件一致。

首次启用时，需要在“系统设置 > 隐私与安全性 > 辅助功能”中授权 ACU。该权限
通常已覆盖模拟锁屏所需的事件监听和投递能力；仅当权限诊断仍提示无法监听输入事件时，
才需要额外授予输入监控权限。应用检测到授权后会提示立即重启；如果没有出现提示，请
手动退出并重新打开 ACU。

只需要阻止空闲自动锁屏时，选择菜单中的“仅阻止系统锁屏”。该模式不会显示模拟锁屏
遮罩、不会拦截物理输入，也不需要身份认证即可停止；再次点击该菜单项即可关闭。在该
模式运行时选择“开启模拟锁屏”或使用开启快捷键，会自动切换到完整模拟锁屏保护，并在
模拟锁屏解除后恢复“仅阻止系统锁屏”。

半合盖自动保护默认启用，可在菜单中关闭，并可选择 `30°`、`45°` 或 `60°` 触发角度
（默认 `45°`）。屏幕角度低于阈值并稳定停留 2 秒后进入模拟锁屏；重新
展开到阈值以上 `5°` 时自动打开 Touch ID/系统密码认证面板。完全合盖且有外接显示器
或合盖导致系统会话锁定时不会触发，重新完全展开前也不会补触发。该功能仅支持带兼容铰链角度传感器的
MacBook；可在“权限诊断”中查看实时角度或不可用状态。

“蓝牙离开自动模拟锁屏”可选择一个已配对设备作为探测设备。设备连接稳定后进入布防；
启用功能或更换探测设备后，如果设备未连接，ACU 会主动连接并每 20 秒重试。断连持续 3 秒后
开启模拟锁屏。认证解锁后，ACU 恢复连接尝试；连接稳定 5 秒后恢复布防。设备列表来自 macOS
当前已配对设备。布防期间通过蓝牙断开通知启动离开防抖，并在防抖期间检查是否恢复连接；通知
不可用时会继续轮询连接状态。
如果尚未布防或设备状态不可用，ACU 不会因断连触发保护。不同安卓机型对 macOS 发起的
底层蓝牙连接支持不同；如果连接无法恢复，菜单会显示等待状态，不会显示已布防。该功能
需 ACU 保持运行；Mac 蓝牙关闭、设备取消配对或连接状态不可用时不会判定为离开。

首次验收请按住 `Option` 点击菜单栏图标，再选择“测试模拟锁屏（15 秒自动退出）”。
“权限诊断”也位于这个隐藏菜单中。测试模式使用完整的保护层和
输入拦截，遮罩会显示剩余时间，并由 Guardian 在 15 秒后自动清理。正式保护模式下，按物理 Enter 打开
macOS 原生认证面板，认证成功后退出保护。

模拟锁屏背景默认跟随当前选择的系统墙纸，可在菜单“模拟锁屏背景”中切换为纯黑。
当前系统背景模式支持视频墙纸和普通图片墙纸（不支持生成式墙纸，遇到此类墙纸时回退
纯黑）。视频墙纸优先复用系统已下载的视频，本地没有时先显示首帧并在后台缓存；普通
图片直接使用原图。保护提示每 60 秒上下移动少量距离，降低静态文字长期停留在同一像素
位置的风险。

默认全局快捷键为 `Control+Option+Command+L`，仅用于开启模拟锁屏。可在菜单
“开启快捷键”中切换为其他预设或关闭；快捷键不能解除保护。

勾选菜单中的“登录后自动启动”后，ACU 会注册为当前用户的登录项。若该登录项曾在
系统设置中被禁用，菜单会提示需要系统批准，并打开“通用 > 登录项与扩展”供用户启用。

如果物理输入拦截无法恢复，遮罩上方会显示故障弹窗。可从弹窗发起原生身份认证并安全退出，
或保持遮罩等待后续处理。

## 开发检查

```sh
go test ./...
go vet ./...
```

产品需求和技术约束见 [document](document/README.md)。

## 产品落地页

产品页源码位于 `website/`，无需安装前端依赖。在仓库根目录运行：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

然后打开 <http://127.0.0.1:4173>。Netlify 配置与 `acu.rectcircle.cn` 的 Cloudflare
CNAME 橙云代理接入步骤见 [落地页部署说明](document/website-deployment.md)。

## 支持项目

如果 ACU 对你有帮助，欢迎自愿支持项目维护。赞助将用于开发、测试和基础设施费用；软件继续免费开源。

- [爱发电](https://afdian.com/a/rectcircle)

## 许可证

[MIT License](LICENSE)

## 日志

ACU 将 INFO、WARN、ERROR 级别的 JSON 日志写入 `~/Library/Logs/ACU/acu.log`。Controller、Guardian 和原生桥接共用日志，每条记录包含时间、级别、进程角色和 PID。单文件上限 5 MiB，保留 3 个备份。日志不记录认证凭据或 IPC token；排障时可用 `tail -f ~/Library/Logs/ACU/acu.log` 观察锁屏通知、状态转换和清理结果。
