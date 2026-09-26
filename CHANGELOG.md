# Changelog / 更新日志

本文件记录 ACU 的重要变更。每个版本同时提供中文和英文说明。

This file records notable changes to ACU. Every release includes both Chinese
and English notes.

## [0.1.1] - 2026-09-26

> [!WARNING]
> Homebrew 安装后需要显式移除 ACU 的 quarantine，这会跳过该应用的 Gatekeeper
> 首次运行检查。仅在信任本仓库及其发布产物时执行；否则应先审查源码并在本地编译。
>
> The Homebrew flow requires explicitly removing quarantine from ACU after
> installation. This skips Gatekeeper's first-launch assessment for the app.
> Only do this if you trust this repository and its release artifacts;
> otherwise review and build the source locally.

### 中文

#### 修复

- 修复“仅阻止系统锁屏”设置未在应用重启后恢复的问题。

#### 变更

- Homebrew Cask 改为固定版本和 SHA-256，并明确安装后移除 quarantine 的风险。
- 发布流水线会在创建 Release 后，使用实际产物版本和 SHA-256 自动更新 Cask。
- README 增加由代码 Agent 审查源码后进行本地编译的替代安装流程。

### English

#### Fixed

- Fixed the "Prevent System Lock Only" setting not being restored after an app
  restart.

#### Changed

- Pinned the Homebrew Cask version and SHA-256 checksum, with an explicit
  warning about removing quarantine from the unnotarized build.
- The release workflow now updates the Cask with the released version and
  actual SHA-256 checksum after creating the GitHub Release.
- Added an alternative installation flow for reviewing the source with a code
  agent and building locally.

## [0.1.0] - 2026-09-26

> [!IMPORTANT]
> 此版本使用 ad-hoc 签名，未经 Apple 公证。macOS 可能阻止首次启动，需要用户在
> “系统设置 > 隐私与安全性”中手动选择“仍要打开”。
>
> This release is ad-hoc signed and is not notarized by Apple. macOS may block
> the first launch until the user chooses Open Anyway under System Settings >
> Privacy & Security.

### 中文

#### 新增

- 提供 macOS 菜单栏应用，以及独立的仅防系统锁屏和模拟锁屏保护模式。
- 空闲时通过轻微移动并恢复鼠标维持活动，并跨应用重启保存仅防锁屏设置。
- 使用全屏遮罩覆盖所有显示器，拦截物理输入，同时放行软件合成输入。
- 通过 Touch ID 或系统密码解除保护，并由独立 Guardian 进程维护保护状态。
- 支持半合盖自动保护、可配置触发角度、展开认证及保护期间的显示器省电。
- 支持当前系统图片或视频墙纸，并提供纯黑背景选项。
- 支持可配置的全局开启快捷键和登录后自动启动。
- 提供按住 `Option` 打开的权限诊断与 15 秒保护测试菜单。
- 界面支持简体中文和英文，并跟随 macOS 首选语言。
- 最低支持 macOS 15。
- 提供 Apple Silicon 与 Intel 通用构建、Homebrew Cask 和自动发布流水线。

### English

#### Added

- Added a macOS menu bar app with separate system-lock prevention and simulated
  lock screen protection modes.
- Added idle activity maintenance by briefly moving and restoring the pointer,
  with the lock-prevention preference preserved across app restarts.
- Added full-screen shields for every display that block physical input while
  allowing software-generated input.
- Added Touch ID or system password authentication, with protection maintained
  by an independent Guardian process.
- Added half-closed lid protection, configurable trigger angles, authentication
  on reopening, and display power saving while protected.
- Added current system image and video wallpaper support with a black
  background option.
- Added configurable global activation shortcuts and launch at login.
- Added permission diagnostics and a 15-second protection test, available by
  holding `Option` while opening the menu.
- Added Simplified Chinese and English interfaces that follow the preferred
  macOS language.
- Set the minimum supported operating system to macOS 15.
- Added universal Apple Silicon and Intel builds, a Homebrew Cask, and an
  automated release workflow.
