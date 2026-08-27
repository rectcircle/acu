# ACU Helper 文档

ACU Helper 是一个独立的 macOS 菜单栏工具，用于在 UI 自动化客户端无法跨系统锁屏继续
工作时提供：

- 空闲活动模拟，尽量避免 macOS 自动锁屏；
- 可独立运行空闲活动维护，不启用遮罩或输入拦截；
- 应用层模拟锁屏，遮挡桌面并过滤物理输入；
- macOS 原生密码或 Touch ID 认证后解除保护。

文档：

1. [需求文档](requirements.md)
2. [技术方案](technical-design.md)

关键边界：

- 仅支持 macOS，主体使用 Go。
- 不修改目标自动化客户端或 macOS 锁屏配置。
- 不采集或校验系统密码，身份认证完全交给 LocalAuthentication。
- 这是防窥和防误操作工具，不等价于 macOS 真锁屏。
- 企业策略检测只在“权限诊断”中展示，不弹窗、不阻断功能。

参考：

- [Automatic Mouse Mover](https://github.com/prashantgupta24/automatic-mouse-mover)
