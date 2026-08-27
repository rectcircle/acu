package app

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	"github.com/rectcircle/acu-helper/internal/ipc"
	"github.com/rectcircle/acu-helper/internal/macos"
)

type guardianMode string

const (
	guardianModeProtection guardianMode = "protection"
	guardianModeKeepAwake  guardianMode = "keep_awake"
)

type guardianProcess struct {
	command       *exec.Cmd
	conn          *ipc.Conn
	fatalReported bool
	testMode      bool
	mode          guardianMode
}

type childEvent struct {
	child   *guardianProcess
	message ipc.Message
	err     error
	exited  bool
}

type Controller struct {
	child                    *guardianProcess
	childEvents              chan childEvent
	quitWhenDisabled         bool
	pendingProtection        bool
	pendingProtectionTimeout int
}

func Run() error {
	if err := macos.InitMenu(); err != nil {
		return err
	}
	controller := &Controller{childEvents: make(chan childEvent, 16)}
	go controller.loop()
	macos.RunApp()
	return nil
}

func (c *Controller) loop() {
	for {
		select {
		case action := <-macos.MenuEvents():
			switch action {
			case macos.MenuEnable:
				c.enable(0)
			case macos.MenuKeepAwake:
				c.toggleKeepAwake()
			case macos.MenuTest:
				c.enable(15)
			case macos.MenuUnlock:
				c.requestAuthentication()
			case macos.MenuDiagnostics:
				c.showDiagnostics()
			case macos.MenuQuit:
				c.quit()
			}
		case event := <-c.childEvents:
			c.handleChildEvent(event)
		}
	}
}

func (c *Controller) enable(timeoutSeconds int) {
	if c.child != nil {
		if c.child.mode == guardianModeKeepAwake {
			c.upgradeToProtection(timeoutSeconds)
		}
		return
	}
	macos.SetMenuState("正在预检")

	if failures := macos.Preflight(true); failures != 0 {
		macos.SetMenuState("启动失败")
		macos.ShowAlert(
			"无法开启模拟锁屏",
			preflightMessage(failures),
			false,
		)
		return
	}
	c.startProtection(timeoutSeconds)
}

func (c *Controller) upgradeToProtection(timeoutSeconds int) {
	if c.pendingProtection {
		return
	}
	macos.SetMenuState("正在预检模拟锁屏")
	if failures := macos.Preflight(true); failures != 0 {
		macos.SetMenuState("仅防锁屏运行中")
		macos.ShowAlert(
			"无法开启模拟锁屏",
			preflightMessage(failures),
			false,
		)
		return
	}

	c.pendingProtection = true
	c.pendingProtectionTimeout = timeoutSeconds
	macos.SetMenuState("正在切换到模拟锁屏")
	if err := c.child.conn.Write(ipc.Message{Type: "stop"}); err != nil {
		c.pendingProtection = false
		c.pendingProtectionTimeout = 0
		macos.SetMenuState("仅防锁屏运行中")
		macos.ShowAlert("无法切换到模拟锁屏", err.Error(), false)
	}
}

func (c *Controller) startProtection(timeoutSeconds int) {
	child, err := startGuardian(
		c.childEvents,
		guardianModeProtection,
		timeoutSeconds,
	)
	if err != nil {
		macos.SetMenuState("启动失败")
		macos.ShowAlert("Guardian 启动失败", err.Error(), false)
		return
	}
	c.child = child
	if timeoutSeconds > 0 {
		macos.SetMenuState("正在启动 15 秒测试")
	} else {
		macos.SetMenuState("正在启动")
	}
}

func (c *Controller) toggleKeepAwake() {
	if c.child != nil {
		if c.child.mode != guardianModeKeepAwake {
			macos.ShowAlert(
				"无法开启防锁屏",
				"模拟锁屏正在运行，请先完成身份认证并解除保护。",
				false,
			)
			return
		}
		if c.pendingProtection {
			return
		}
		macos.SetMenuState("正在停止防锁屏")
		if err := c.child.conn.Write(ipc.Message{Type: "stop"}); err != nil {
			macos.SetMenuState("停止防锁屏失败")
		}
		return
	}

	macos.SetMenuState("正在预检防锁屏")
	if failures := macos.PreflightKeepAwake(true); failures != 0 {
		macos.SetMenuState("启动失败")
		macos.ShowAlert(
			"无法开启防锁屏",
			preflightMessage(failures),
			false,
		)
		return
	}

	child, err := startGuardian(
		c.childEvents,
		guardianModeKeepAwake,
		0,
	)
	if err != nil {
		macos.SetMenuState("启动失败")
		macos.ShowAlert("防锁屏进程启动失败", err.Error(), false)
		return
	}
	c.child = child
	macos.SetMenuState("正在启动防锁屏")
}

func (c *Controller) requestAuthentication() {
	if c.child == nil || c.child.mode != guardianModeProtection {
		return
	}
	_ = c.child.conn.Write(ipc.Message{Type: "request_auth"})
}

func (c *Controller) quit() {
	if c.child == nil {
		macos.StopApp()
		return
	}
	c.quitWhenDisabled = true
	c.pendingProtection = false
	c.pendingProtectionTimeout = 0
	if c.child.mode == guardianModeKeepAwake {
		macos.SetMenuState("正在停止防锁屏并退出")
		_ = c.child.conn.Write(ipc.Message{Type: "stop"})
		return
	}
	macos.SetMenuState("等待认证后退出")
	c.requestAuthentication()
}

func (c *Controller) showDiagnostics() {
	failures := macos.Preflight(false)
	policy := policyDescription()
	message := fmt.Sprintf("技术预检：%s\n企业策略：%s",
		preflightSummary(failures), policy)
	macos.ShowAlert("ACU Helper 诊断", message, false)
}

func (c *Controller) handleChildEvent(event childEvent) {
	if event.child != c.child {
		return
	}
	if event.exited {
		c.child = nil
		if event.child.mode == guardianModeKeepAwake {
			macos.SetKeepAwakeActive(false)
		}
		if event.err == nil && c.startPendingProtection() {
			return
		}
		if event.err != nil && !event.child.fatalReported {
			c.pendingProtection = false
			c.pendingProtectionTimeout = 0
			title := "保护已失效"
			message := "Guardian 已退出，应用层保护不再生效。"
			if event.child.mode == guardianModeKeepAwake {
				title = "防锁屏已失效"
				message = "防锁屏进程已异常退出。"
			}
			macos.SetMenuState(title)
			macos.ShowAlert(
				title,
				message,
				false,
			)
		}
		return
	}
	if event.err != nil {
		return
	}

	switch event.message.Type {
	case "state":
		if event.message.State == "awake" {
			macos.SetKeepAwakeActive(true)
			macos.SetMenuState("仅防锁屏运行中")
		} else if event.message.State == "degraded" &&
			event.child.mode == guardianModeKeepAwake {
			macos.SetMenuState("防锁屏异常")
		} else if event.message.State == "disarming" &&
			event.child.mode == guardianModeKeepAwake {
			macos.SetMenuState("正在停止防锁屏")
		} else if event.message.State == "protected" && event.child.testMode {
			macos.SetMenuState("测试保护中（15 秒自动退出）")
		} else {
			macos.SetMenuState(displayState(event.message.State))
		}
		if event.message.State == "disabled" {
			if event.child.mode == guardianModeKeepAwake {
				macos.SetKeepAwakeActive(false)
			}
			event.child.conn.Close()
			c.child = nil
			if c.quitWhenDisabled {
				macos.StopApp()
				return
			}
			c.startPendingProtection()
		}
	case "fatal":
		event.child.fatalReported = true
		macos.SetMenuState("启动失败")
		macos.ShowAlert(
			"Guardian 启动失败",
			"错误码："+event.message.Code,
			false,
		)
	}
}

func (c *Controller) startPendingProtection() bool {
	if !c.pendingProtection {
		return false
	}
	timeoutSeconds := c.pendingProtectionTimeout
	c.pendingProtection = false
	c.pendingProtectionTimeout = 0
	c.startProtection(timeoutSeconds)
	return true
}

func startGuardian(
	events chan<- childEvent,
	mode guardianMode,
	timeoutSeconds int,
) (*guardianProcess, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	controllerRead, guardianWrite, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	guardianRead, controllerWrite, err := os.Pipe()
	if err != nil {
		controllerRead.Close()
		guardianWrite.Close()
		return nil, err
	}

	command := exec.Command(executable, "guardian")
	command.ExtraFiles = []*os.File{guardianRead, guardianWrite}
	command.Stderr = os.Stderr
	if err := command.Start(); err != nil {
		controllerRead.Close()
		guardianWrite.Close()
		guardianRead.Close()
		controllerWrite.Close()
		return nil, err
	}
	guardianRead.Close()
	guardianWrite.Close()

	conn := ipc.New(
		controllerRead,
		controllerWrite,
		controllerRead,
		controllerWrite,
	)
	child := &guardianProcess{
		command:  command,
		conn:     conn,
		testMode: timeoutSeconds > 0,
		mode:     mode,
	}
	token, err := randomToken()
	if err != nil {
		conn.Close()
		_ = command.Process.Kill()
		return nil, err
	}
	if err := conn.Write(ipc.Message{
		Type:           "hello",
		Token:          token,
		Mode:           string(mode),
		TimeoutSeconds: timeoutSeconds,
	}); err != nil {
		conn.Close()
		_ = command.Process.Kill()
		return nil, err
	}

	go readGuardian(child, events)
	return child, nil
}

func readGuardian(child *guardianProcess, events chan<- childEvent) {
	var readErr error
	for {
		message, err := child.conn.Read()
		if err != nil {
			if err != io.EOF {
				readErr = err
			}
			break
		}
		events <- childEvent{child: child, message: message}
	}
	waitErr := child.command.Wait()
	if waitErr == nil {
		waitErr = readErr
	}
	events <- childEvent{child: child, err: waitErr, exited: true}
}

func randomToken() (string, error) {
	var data [32]byte
	if _, err := rand.Read(data[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(data[:]), nil
}

func policyDescription() string {
	switch policyStatus() {
	case "managed":
		return "检测到托管锁屏策略（不阻断功能）"
	case "enrolled":
		return "设备已纳管，未识别到具体锁屏策略"
	case "unknown":
		return "检测失败"
	default:
		return "未发现相关托管策略"
	}
}

func policyStatus() string {
	if macos.ManagedPolicyDetected() {
		return "managed"
	}
	output, err := exec.Command(
		"/usr/bin/profiles", "status", "-type", "enrollment",
	).CombinedOutput()
	if err != nil {
		return "unknown"
	}
	text := strings.ToLower(string(output))
	if strings.Contains(text, "mdm enrollment: yes") ||
		strings.Contains(text, "enrolled via dep: yes") {
		return "enrolled"
	}
	return "allowed"
}

func preflightMessage(failures macos.PreflightFailures) string {
	return "请处理以下问题后重试：\n" + preflightSummary(failures)
}

func preflightSummary(failures macos.PreflightFailures) string {
	if failures == 0 {
		return "全部通过"
	}
	var problems []string
	if failures&macos.FailureAccessibility != 0 {
		problems = append(problems, "未授予辅助功能权限")
	}
	if failures&macos.FailureListenEvents != 0 {
		problems = append(problems, "无法监听输入事件")
	}
	if failures&macos.FailurePostEvents != 0 {
		problems = append(problems, "无法投递合成事件")
	}
	if failures&macos.FailureAuth != 0 {
		problems = append(problems, "设备所有者认证不可用")
	}
	if failures&macos.FailureDisplay != 0 {
		problems = append(problems, "没有可用显示器")
	}
	if failures&macos.FailureSessionLocked != 0 {
		problems = append(problems, "当前系统会话已锁定")
	}
	return strings.Join(problems, "\n")
}

func displayState(state string) string {
	switch state {
	case "protected":
		return "模拟锁屏保护中"
	case "awake":
		return "仅防锁屏运行中"
	case "authenticating":
		return "正在进行身份认证"
	case "disarming":
		return "正在解除保护"
	case "degraded":
		return "保护降级"
	case "failed":
		return "启动失败"
	default:
		return "未启用"
	}
}
