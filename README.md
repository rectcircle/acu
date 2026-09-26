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

界面支持简体中文和英文，并跟随 macOS 的首选语言；修改语言后需要重新启动 ACU。

## Homebrew 安装

```sh
brew tap rectcircle/acu https://github.com/rectcircle/acu
brew install --cask --no-quarantine rectcircle/acu/acu
```

升级到最新版本：

```sh
brew upgrade --cask rectcircle/acu/acu
```

当前发布包使用 ad-hoc 签名，未经 Apple 公证。`--no-quarantine` 仅跳过该安装包的
Gatekeeper 首次运行检查，不会全局关闭 Gatekeeper，也不会自动授予辅助功能等权限。
Cask 固定版本和 SHA-256，但仍应仅在信任本仓库及其发布产物时使用该参数。

如果不信任预编译产物，请勿使用 `--no-quarantine`。可以先让代码 Agent 审查源码，
重点检查 `Casks/acu.rb`、`internal/macos` 和 `scripts/build-app.sh`，然后从固定标签
本地编译：

```sh
git clone https://github.com/rectcircle/acu.git
cd acu
git checkout v0.1.1
go test ./...
./scripts/build-app.sh
open "build/ACU.app"
```

本地编译会重新生成可执行文件并进行 ad-hoc 签名，通常不会带有下载文件的 quarantine。

## 构建

要求 macOS 15 或更高版本、Go 1.22 或更高版本以及 Xcode Command Line Tools。

```sh
./scripts/build-app.sh
open "build/ACU.app"
```

生成同时支持 Apple Silicon 和 Intel Mac 的发布包：

```sh
./scripts/package-release.sh 0.1.1
```

推送 `v0.1.1` 格式的标签后，GitHub Actions 会自动测试、构建
`ACU.tar.gz` 并创建 Release。Release Notes 来自 `CHANGELOG.md` 中对应版本的双语
章节；缺少该版本时发布会失败。发布成功后，流水线会使用实际产物的 SHA-256 更新
Homebrew Cask。

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
