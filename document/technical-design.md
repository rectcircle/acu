# ACU Helper 技术方案

## 1. 方案概述

本文描述一个独立的 macOS 菜单栏工具，使用 Go 实现主体逻辑，通过 cgo 调用少量
Objective-C/macOS 原生 API。需求见 [requirements.md](requirements.md)。

核心方案：

```text
Menu Controller
  └─ 启动 Guardian 子进程
       ├─ Idle Keeper：空闲时轻微移动并恢复鼠标
       └─ 模拟锁屏模式
            ├─ Quartz Event Tap：过滤物理输入、放行可信合成输入
            ├─ AppKit Shield Windows：覆盖全部显示器
            └─ LocalAuthentication：密码或 Touch ID 认证后解除
```

该方案不修改系统锁屏时间，不执行 `pmset`，不安装系统扩展，也不接入目标自动化客户端。
它利用
运行期合成活动延后自动锁屏，并用应用层遮罩替代离开期间的可见桌面。

## 2. 技术选型

### 2.1 Go

Go 负责：

- 状态机；
- 定时调度；
- controller/guardian 生命周期；
- IPC；
- 配置和日志；
- 策略判断；
- 单元测试。

建议 Go 版本：1.23 或项目创建时可用的稳定版本。

### 2.2 Objective-C bridge

原生 bridge 负责：

- AppKit 菜单栏和保护窗口；
- Quartz Event Tap；
- CGEvent 鼠标移动；
- LocalAuthentication；
- 会话锁定状态；
- IOKit HID 铰链角度和外接显示器状态；
- managed preference 检测。

不建议 MVP 使用 `robotgo`：

- 依赖面较大；
- 本需求只需要少量 macOS API；
- 输入来源标记、Event Tap 和窗口层级仍需要原生代码；
- 直接使用 Quartz 更容易控制事件字段和失败语义。

### 2.3 双进程

同一个可执行文件支持两种模式：

```text
acu-helper                 # menu controller
acu-helper guardian        # protection guardian
```

采用双进程而不是单进程的原因：

- 菜单栏 UI 故障不应立即移除保护层；
- Guardian 可以独立监听物理 Enter 并完成系统认证；
- controller 退出或 IPC 断开后，Guardian 仍可保持遮罩并让用户认证退出；
- 业务边界清晰，便于以后替换 controller UI。

Guardian 不应依赖 controller 才能解除保护。

## 3. 架构

### 3.1 组件

#### Controller

- 创建菜单栏图标。
- 展示状态和权限诊断。
- 启停不带遮罩和输入拦截的“仅阻止系统锁屏”模式。
- 注册并持久化“开启保护”全局快捷键；保护态下重复触发由 Controller 幂等忽略。
- 在“权限诊断”中展示企业策略检测结果，不在开启流程中弹窗或阻断功能。
- 生成本次保护会话 ID 和随机 token。
- 启动 Guardian。
- 监听 Guardian 状态。
- “解除保护”菜单只请求 Guardian 打开原生认证，不可直接关闭遮罩。

#### Guardian

- 是保护状态的 canonical owner。
- 创建并维护所有显示器的 Shield Window。
- 创建 Event Tap。
- 维护活动时间和 Idle Keeper。
- 调用 LocalAuthentication。
- 认证成功后按固定顺序清理并退出。
- 在 `keep_awake` 模式下只维护 Idle Keeper，Controller 断开或收到停止请求时直接退出。

#### Native Bridge

建议按能力拆分，不暴露通用的“执行任意 Objective-C”接口：

```text
native_menu.*
native_shield.*
native_eventtap.*
native_activity.*
native_auth.*
native_session.*
native_policy.*
```

#### Policy Probe

- 检查当前图形会话。
- 使用 `CFPreferencesAppValueIsForced` 检查受管理的 screensaver/loginwindow key。
- 可使用 `/usr/bin/profiles status -type enrollment` 判断设备是否注册管理，仅作提示。
- 明确发现活动模拟会延后的强制自动锁屏策略时返回 `managed_policy_detected` 和
  `managed_lock_policy_detected`，由 Controller 在权限诊断中展示。
- 仅确认设备已纳管或策略检测失败时分别返回 `managed_unconfirmed` 或
  `probe_failed`，由 Controller 在权限诊断中展示。
- Policy Probe 的所有结果都不得触发开启确认弹窗或阻断开启流程。

### 3.2 进程通信

MVP 使用匿名 pipe 或 `socketpair`，协议为有大小上限的 NDJSON：

```json
{"type":"hello","token":"...","mode":"protection"}
{"type":"state","state":"protected"}
{"type":"request_auth"}
{"type":"stop"}
{"type":"fatal","code":"event_tap_unavailable"}
```

约束：

- 单条消息最大 16 KiB。
- token 通过继承的 pipe 首次握手传递，不放在命令行。
- 只接受父子进程连接。
- 消息不包含按键内容、密码、窗口文本和截图。
- `protection` 模式下 controller EOF 不解除保护。
- `keep_awake` 模式下 controller EOF 直接停止，避免留下孤立进程。

## 4. 状态机

```text
Disabled
   │ enable
   ▼
Arming ── preflight failed ──► Failed ──► Disabled
   │ ready
   ▼
Protected
   │ physical Enter / menu request
   ▼
Authenticating
   ├─ cancel/failure ─────────► Protected
   └─ success
        ▼
Disarming ────────────────────► Disabled

Protected/Authenticating
   └─ event tap or keeper failure ──► Degraded

Arming ── keep_awake ready ──► Awake
Awake ── keeper failure ──► Degraded ── recovered ──► Awake
Awake/Degraded ── stop/controller EOF ──► Disarming ──► Disabled
```

状态规则：

- `enable`、`request_auth`、`disable_after_auth` 均幂等。
- 只有 Guardian 能从 `Authenticating` 转移到 `Disarming`。
- controller 不能发送无认证的 `force_disable`。
- `Degraded` 保留遮罩，允许物理 Enter 打开认证。
- 启动失败必须在展示遮罩前回滚已创建资源。

## 5. 开启流程

```text
用户选择“开启模拟锁屏”
  → Controller: 检查系统会话
  → Controller: 检查 Accessibility / Event Tap / LocalAuthentication
  → Controller: 启动 Guardian
  → Guardian: 创建 Event Tap，验证能过滤和投递事件
  → Guardian: 创建所有显示器的 Shield Window
  → Guardian: 启动 Idle Keeper
  → Guardian: 回报 protected
```

顺序要求：

1. Event Tap 必须先就绪。
2. 保护窗口随后展示。
3. Idle Keeper 最后启动。
4. 任何步骤失败都不得上报 `protected`。

这样避免先遮罩、后发现没有输入拦截而使用户无法正常解除。

首次验收可从菜单启动 15 秒测试模式。Controller 仅在 Guardian 启动握手中传递固定超时；
Guardian 使用独立计时器，每秒更新全部 Shield Window 中的剩余时间，并在超时后停止 Event
Tap、关闭全部 Shield Window 并退出。该计时不依赖 Controller 或认证回调，确保认证面板
异常时仍能恢复。正式保护会话不传递超时，仍只能在原生认证成功后正常解除。

## 6. 防自动锁屏

### 6.1 参考实现

Automatic Mouse Mover 的主要策略是：

1. 每 60 秒汇总系统活动。
2. 发现活动时不做任何事。
3. 没有活动且系统未睡眠时，将鼠标移动约 10 像素。
4. 下次向反方向移动，避免指针持续漂移。

ACU Helper 保留“只在空闲时移动”的原则，但使用更小位移，并立即恢复原位置。

参考源码：

- <https://github.com/prashantgupta24/automatic-mouse-mover>
- <https://github.com/prashantgupta24/automatic-mouse-mover/blob/master/pkg/mousemover/mouseMover.go>

### 6.2 调度算法

默认参数：

```text
pollInterval         = 5s
idleBeforeNudge      = 45s
recentActivityGuard  = 5s
nudgeDistance        = 1px
restoreDelay         = 10ms
failureThreshold     = 3
```

每次检查：

```text
if state != Protected:
    skip
if auth dialog active:
    skip
if session locked / switched / display asleep:
    skip
if any physical or synthetic UI event occurred within recentActivityGuard:
    skip
if HID idle time < idleBeforeNudge:
    skip
nudge cursor by 1px within current display bounds
restore original point after 10ms
verify event post succeeded
```

移动方向按当前位置选择：

- 右侧有空间时使用 `x + 1`；
- 否则使用 `x - 1`；
- 多显示器负坐标必须使用全局 Quartz 坐标处理；
- 恢复点始终使用移动前读取的坐标。

### 6.3 原生 API

- `CGEventSourceSecondsSinceLastEventType`
- `CGEventCreateMouseEvent`
- `CGEventSetIntegerValueField`
- `CGEventPost`
- `CGEventGetLocation`

Helper 自己产生的事件写入固定随机 `kCGEventSourceUserData` 标记，使 Event Tap 能识别并
放行，且不将其误判为用户解除请求。

MVP 不使用 `caffeinate` 或永久 IOPM Assertion：

- 它们不能提供模拟锁屏；
- 显示器 assertion 与企业策略边界更难解释；
- 鼠标活动路径更接近参考实现。

如果实机验证发现合成鼠标事件不能稳定延后某个 macOS 版本的自动锁屏，应把该版本标记
为不支持，而不是静默增加系统级绕过。

### 6.4 仅防锁屏模式

Guardian 握手模式为 `keep_awake` 时，不创建 Event Tap、Shield Window 或认证上下文，只
运行本节的 Idle Keeper。该模式不形成隐私保护边界，用户可通过菜单直接停止。连续 nudge
失败时进入 `degraded`，后续成功时自动恢复到 `awake`。

从该模式开启模拟锁屏时，Controller 先在 Idle Keeper 继续运行的情况下执行完整保护预检。
预检失败则保持 `keep_awake`；预检成功后记录待启动的保护模式，向当前 Guardian 发送
`stop`，收到 `disabled` 后再启动 `protection` Guardian。两个 Guardian 不并行运行。

### 6.5 半合盖自动保护

Controller 每 250 ms 通过 Native Bridge 读取一次内置铰链角度传感器。Bridge 使用
IOKit HID 匹配 Apple `VendorID=0x05ac`、`ProductID=0x8104`、
`UsagePage=0x0020`、`Usage=0x008a`，读取 feature report `1`，不执行外部命令。
如果 report `1` 不可用则尝试 report `0`；传感器发现或读取失败时不产生状态转换。

自动化状态机与 Guardian 保护状态机分离，规则如下：

```text
angle < threshold 且稳定停留 2s（角度变化时重新计时）
  └─ 当前无保护或仅防锁屏运行中 -> 开启完整模拟锁屏

angle >= threshold + 5° 且保护由半合盖触发
  └─ 发送 request_auth -> Guardian 打开 LocalAuthentication

angle <= 2° 且存在在线外接显示器
  └─ 抑制当前开合周期，直到重新展开后再 armed

system session locked
  └─ 取消当前候选，直到重新完全展开后再 armed
```

`protectionOwned` 只在半合盖状态机实际请求保护时设置。手动菜单、快捷键和测试模式启动的
保护不会在展开时自动认证。认证取消后保持保护；必须再次低于阈值并重新展开才会再次自动
发起认证。

菜单配置使用 `NSUserDefaults` 持久化，未保存开关配置时默认开启，用户关闭后持久化
该选择；阈值默认 `45°`，可选
`30°/45°/60°`。诊断面板显示当前原始角度，便于确认机型支持情况。该 HID report 的
设备标识和数据布局属于机型相关约定，需要在系统升级和新硬件上回归。

## 7. 模拟锁屏保护层

### 7.1 Window 配置

每个 `NSScreen` 创建一个无边框 Window：

```text
styleMask          = borderless + nonactivatingPanel
level              = CGShieldingWindowLevel()
collectionBehavior = canJoinAllSpaces + fullScreenAuxiliary
opaque             = true
background         = solid dark color
hidesOnDeactivate  = false
sharingType        = none
```

正常保护态：

- Window 不成为 key/main window。
- `ignoresMouseEvents = true`，让可信自动化客户端的合成事件命中底层目标应用。
- 物理鼠标由 Event Tap 消费。

认证态：

- Window 临时设置为接收鼠标，以吞掉认证面板之外的物理点击。
- LocalAuthentication 面板由系统显示在更高层。
- 认证结束后恢复正常保护态或关闭窗口。

### 7.2 多显示器

- 监听 `NSApplicationDidChangeScreenParametersNotification`。
- 先创建一整套新窗口并全部成功展示，再销毁旧窗口。
- 新显示器创建失败时进入 `Degraded`，不得只保护部分显示器却显示正常状态。

### 7.3 截图兼容

目标是让自动化客户端在保护态下继续执行其授权操作：

- 使用 `sharingType = .none` 尽可能排除 Shield Window。
- Shield Window 不附着到目标应用。
- 不改变目标窗口层级、位置或焦点。

具体采集和交互链路由目标客户端负责，ACU Helper 不依赖或记录其内部实现。兼容性必须
通过目标客户端的公开用户操作进行黑盒验证。

## 8. 输入过滤

### 8.1 Event Tap

使用：

```text
CGEventTapCreate(
    kCGHIDEventTap,
    kCGHeadInsertEventTap,
    kCGEventTapOptionDefault,
    eventMask,
    callback,
    context
)
```

监听：

- key down/up；
- flags changed；
- mouse down/up/move/drag；
- scroll wheel；
- tap disabled diagnostics。

Event Tap 回调只做常量时间判断，不调用 Go 网络、文件或阻塞 API。

### 8.2 来源分类

事件分为：

```text
HelperSynthetic
TrustedClientSynthetic
Physical
Unknown
```

判定输入：

- `kCGEventSourceUserData`
- `kCGEventSourceUnixProcessID`
- `kCGEventSourceStateID`
- 本机配置的可信代码签名 Team ID

默认策略：

| 来源 | 普通保护态 | 认证态 |
|---|---|---|
| HelperSynthetic | 放行 | 放行 |
| TrustedClientSynthetic | 放行 | 暂停 |
| Physical Enter keyDown | 消费并发起认证 | 消费重复请求 |
| 其他 Physical | 消费 | 定向投递给 LocalAuthentication UI |
| Unknown | 消费 | 消费 |

认证态不得直接放行原始物理事件。Native Bridge 缓存
`com.apple.LocalAuthentication.UIAgent` 的 PID，消费原事件后使用 `CGEventPostToPid`
定向投递；未找到认证进程时采用安全默认并消费事件。鼠标移动可保留，以便用户定位认证
面板，点击和键盘事件不得落入底层应用。

可信自动化客户端发现策略：

1. 用户通过通用配置脚本选择已签名的自动化客户端。
2. 脚本只把代码签名 Team ID 写入本机偏好设置，不写入仓库或应用二进制。
3. Guardian 从 `NSRunningApplication` 枚举进程并校验其代码签名 Team ID。
4. 只缓存当前运行实例的 PID，不通过进程名称、Bundle ID 前缀或安装路径直接信任。

诊断信息可记录事件种类和分类结果，但禁止记录具体键值、客户端标识或签名信息。

### 8.3 Enter 语义

- 仅物理 `Return` 或数字键盘 `Enter` 的 keyDown 可发起认证。
- synthetic Enter 不得打开认证。
- key repeat 不得重复创建认证请求。
- Enter 事件不传递给底层应用。

## 9. 身份认证

### 9.1 API

Objective-C bridge 使用：

```objective-c
LAContext *context = [LAContext new];
[context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
         localizedReason:@"解除 ACU Helper 模拟锁屏"
                   reply:...];
```

选择 `LAPolicyDeviceOwnerAuthentication`，而不是只允许生物识别的
`LAPolicyDeviceOwnerAuthenticationWithBiometrics`，以支持：

- Touch ID；
- macOS 系统密码回退；
- 系统策略决定的其他设备所有者认证方式。

### 9.2 安全约束

- 应用不创建密码输入框。
- 应用不接收密码字符串。
- 回调只返回 success、cancelled 和稳定错误码。
- 每次认证使用新的 `LAContext`。
- 同一时间最多一个认证请求。
- `biometryLockout` 时由系统密码回退处理。
- 认证成功后立即使本保护 session 的随机 token 失效。

### 9.3 解除顺序

```text
认证成功
  → 停止 Idle Keeper
  → 禁止新的合成 nudge
  → 停止 Event Tap
  → 关闭全部 Shield Window
  → 清除 session 内存状态
  → 通知 Controller
  → Guardian 退出
```

认证失败时不执行上述任何清理。

## 10. 系统状态与策略

### 10.1 会话状态

使用 `CGSessionCopyCurrentDictionary` 读取 `CGSSessionScreenIsLocked`：

- 启动时若已锁定，拒绝开启。
- 运行时若检测到系统已经锁定，停止鼠标 nudge。
- 工具不尝试自动解锁系统。

### 10.2 Managed Preference

使用 `CFPreferencesAppValueIsForced` 检查：

```text
domain: com.apple.screensaver
keys: idleTime, askForPassword, askForPasswordDelay

domain: com.apple.loginwindow
keys: DisableScreenLockImmediate
```

具体 key 需要在目标 macOS/MDM 样本上验证。原则：

- 必须结合 domain、key 和 value 判断策略语义，以展示准确的诊断结果。
- 可信证据表明组织强制要求空闲后进入屏保或锁屏，且 Idle Keeper 的合成活动会延后该
  行为时，返回 `managed_policy_detected`。
- “设备已管理”本身返回 `managed_unconfirmed`。
- 查询 API 不可用、读取失败或结果无法可靠解释时返回 `probe_failed`。
- 未发现相关托管策略时返回 `allowed`。
- 以上结果仅在“权限诊断”中展示，不得弹出确认框、禁用菜单项或使开启流程失败。
- 不修改任何 managed preference。

策略判定矩阵：

| 判定 | 证据 | 开启行为 |
| --- | --- | --- |
| `managed_policy_detected` | 明确存在会被活动模拟延后的托管自动锁屏策略 | 仅诊断展示 |
| `managed_unconfirmed` | 仅确认设备已纳管，未发现具体锁屏策略 | 仅诊断展示 |
| `probe_failed` | 检测失败或结果不可可靠解释 | 仅诊断展示 |
| `allowed` | 未发现相关托管策略 | 继续其他预检 |

开启流程不执行 Policy Probe；用户主动打开“权限诊断”时才查询并展示上述结果。

## 11. 权限

### 11.1 Accessibility

用途：

- 创建可过滤的 Event Tap；
- 投递合成鼠标事件；
- 识别和放行已配置自动化客户端的输入。

API：

- `AXIsProcessTrustedWithOptions`
- `CGPreflightListenEventAccess`
- `CGRequestListenEventAccess`
- `CGPreflightPostEventAccess`
- `CGRequestPostEventAccess`

### 11.2 不需要的权限

MVP 不应申请：

- Screen Recording；
- Full Disk Access；
- Contacts/Calendar；
- Network Extension；
- System Extension；
- 管理员权限。

## 12. Go 接口草案

```go
type State string

const (
	StateDisabled       State = "disabled"
	StateArming         State = "arming"
	StateAwake          State = "awake"
	StateProtected      State = "protected"
	StateAuthenticating State = "authenticating"
	StateDisarming      State = "disarming"
	StateDegraded       State = "degraded"
	StateFailed         State = "failed"
)

type NativeShield interface {
	ShowAllDisplays(copy ShieldCopy) error
	SetAuthenticationMode(enabled bool) error
	HideAll() error
}

type InputGuard interface {
	Start(policy InputPolicy) error
	UpdateTrustedProcesses(processes []TrustedProcess) error
	Stop() error
}

type Authenticator interface {
	CanAuthenticate() error
	Authenticate(reason string) (AuthResult, error)
}

type ActivityKeeper interface {
	Start(context.Context) error
	Stop()
	Status() KeeperStatus
}

type PolicyProbe interface {
	Evaluate(context.Context) PolicyDecision
}

type PolicyDisposition string

const (
	PolicyAllowed          PolicyDisposition = "allowed"
	PolicyManagedDetected  PolicyDisposition = "managed_policy_detected"
	PolicyManagedUnknown   PolicyDisposition = "managed_unconfirmed"
	PolicyProbeFailed      PolicyDisposition = "probe_failed"
)

type PolicyDecision struct {
	Disposition PolicyDisposition
	ReasonCode  string
}
```

所有 native 返回值必须转换为稳定错误码，例如：

```text
accessibility_denied
event_tap_unavailable
post_event_denied
local_auth_unavailable
no_displays
session_already_locked
trusted_runtime_unverified
```

企业策略检测不是运行错误，使用独立的诊断原因码，例如
`managed_lock_policy_detected`、`managed_enrollment_detected` 和 `policy_probe_failed`。

## 13. 目录结构

```text
acu-helper/
  cmd/
    acu-helper/
      main.go
  internal/
    app/
      controller.go
    guardian/
      guardian.go
      state.go
    activity/
      keeper.go
      scheduler.go
    auth/
      service.go
    input/
      classifier.go
      trusted_process.go
    policy/
      probe.go
    ipc/
      protocol.go
      pipe.go
    config/
      config.go
    log/
      log.go
    macos/
      bridge.go
      bridge.h
      bridge.m
      bridge_darwin.go
  resources/
    Info.plist
    Assets.xcassets/
  scripts/
    build-app.sh
    sign-app.sh
  document/
    README.md
    requirements.md
    technical-design.md
  go.mod
```

原生 bridge 后续可按文件拆分，但对 Go 保持窄接口。

## 14. 构建与分发

### 14.1 App Bundle

`Info.plist` 至少包含：

```text
CFBundleIdentifier
CFBundleExecutable
CFBundleName
CFBundleVersion
CFBundleShortVersionString
LSUIElement = true
LSMinimumSystemVersion = 13.0
```

构建：

```text
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 go build
CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 go build
lipo -create ...
```

cgo 链接：

```text
-framework AppKit
-framework ApplicationServices
-framework Carbon
-framework CoreGraphics
-framework CoreFoundation
-framework IOKit
-framework LocalAuthentication
-framework Security
```

### 14.2 签名

个人开发可先 ad-hoc 签名。稳定分发应使用 Developer ID、Hardened Runtime 和 notarization。
每次更新签名 identity 后都要回归 Accessibility 权限迁移行为。

## 15. 并发与资源释放

- AppKit API 只在主线程调用；Go `main` 使用 `runtime.LockOSThread()`。
- Event Tap 在独立 CFRunLoop 线程运行。
- Event Tap callback 不跨 cgo 执行长耗时 Go 逻辑。
- 状态转换由单个 Guardian event loop 串行处理。
- Timer 使用 `time.Ticker` 或单次 `time.Timer`，退出时全部停止。
- LocalAuthentication callback 只投递状态事件，不直接销毁窗口。
- 每个 native handle 都有明确 owner 和幂等 `Close`。

## 16. 故障处理

| 故障 | 行为 |
|---|---|
| Guardian 启动失败 | 不显示遮罩，回到 disabled |
| Event Tap 创建失败 | 不进入保护态 |
| Event Tap 临时禁用 | 立即 re-enable，记录一次诊断 |
| Event Tap 持续失败 | 保留遮罩，进入 degraded，在遮罩上方弹出故障提示并允许发起认证 |
| 鼠标 nudge 连续失败 | 进入 degraded；模拟锁屏模式保留遮罩，仅防锁屏模式继续重试 |
| 屏幕重建失败 | 保留旧遮罩，进入 degraded |
| Controller 崩溃 | Guardian standalone 运行，Enter 仍可认证 |
| Guardian 崩溃 | 保护丢失；Controller 显示高优先级错误，不自动假装仍受保护 |
| 系统实际锁屏 | 停止 nudge，不尝试解锁 |
| LocalAuthentication 取消 | 返回 protected |

## 17. 测试方案

### 17.1 Go 单元测试

- 状态转换和非法转换。
- `protection`、`keep_awake` 握手模式及超时约束。
- Idle Keeper 调度边界。
- nudge 失败计数和 degraded 转换。
- IPC 大小限制、坏消息和 EOF。
- controller EOF 后 Guardian 保持策略。
- policy decision 合并。
- trusted PID 启动时间和 PID 复用检测。
- 半合盖防抖、展开迟滞、手动保护隔离和闭盖外接屏抑制。

### 17.2 Native 测试

- 多显示器窗口创建/销毁。
- Event Tap 来源字段采样。
- helper 自身 userData 标记。
- LocalAuthentication success/cancel/lockout。
- `CFPreferencesAppValueIsForced` fixture。
- 锁屏状态识别。
- 铰链传感器发现、报告读取和外接显示器识别。

### 17.3 E2E

至少覆盖：

1. Intel/Apple Silicon。
2. macOS 13、14、15，以及开发时最新版本。
3. 单屏、双屏、显示器热插拔。
4. 普通窗口、全屏 App、多个 Space。
5. 已配置自动化客户端的核心采集与交互操作。
6. 物理鼠标、键盘、触控板。
7. Touch ID 和密码回退。
8. controller kill、Event Tap disable、权限撤销。
9. 系统锁屏时间设置为 1 分钟的长时间运行。
10. 各 managed preference 结果不会触发开启弹窗或阻断 Guardian 启动。
11. 权限诊断可展示设备纳管和策略检测失败状态。
12. 认证面板打开时，物理输入和自动化客户端合成输入不会写入底层应用。
13. 全局快捷键默认值、预设切换、持久化、关闭和保护态幂等行为。
14. 半合盖触发、展开认证、快速开合防抖和完全合盖外接显示器抑制。

## 18. 实施阶段

### Phase 1：原生能力 PoC

- Event Tap 分类物理输入与可信客户端合成事件。
- 1 像素 nudge 能稳定延后锁屏。
- Shield Window 不影响目标窗口截图。
- LocalAuthentication 能在遮罩上完成认证。

四项任何一项失败，都应先调整方案，不进入完整开发。

### Phase 2：MVP

- controller/guardian 双进程。
- 菜单栏、状态机、保护层、输入隔离、Idle Keeper、认证退出。
- 基础日志和权限诊断。
- arm64 `.app`。

### Phase 3：稳定性

- Universal Binary。
- 多显示器和 Space 完整回归。
- Developer ID 签名和 notarization。
- managed preference 策略矩阵。
- 故障注入与长稳测试。

## 19. 关键决策

1. 使用原生 LocalAuthentication，不自行处理系统密码。
2. 使用应用层遮罩，不伪装成真正的 macOS 锁屏。
3. 使用 Event Tap 区分物理输入和可信自动化客户端合成输入。
4. 使用轻微鼠标活动，不永久修改系统电源/锁屏设置。
5. 使用双进程，让 Guardian 在 controller 故障后仍可认证退出。
6. 企业策略检测只用于权限诊断，不弹窗、不阻断功能；不修改或规避 MDM 配置。
7. 半合盖仅自动开启模拟保护，展开仅自动发起系统认证，不绕过认证。
