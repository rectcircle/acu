package app

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/rectcircle/acu/internal/ipc"
	"github.com/rectcircle/acu/internal/macos"
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
	keepAwakeRequested       bool
	pendingProtection        bool
	pendingProtectionTimeout int
	lidAutomation            *lidAutomation
}

func Run() error {
	if err := macos.InitMenu(); err != nil {
		return err
	}
	lidConfig := macos.CurrentLidAutomationConfig()
	controller := &Controller{
		childEvents: make(chan childEvent, 16),
		lidAutomation: newLidAutomation(
			lidConfig.Enabled,
			lidConfig.ThresholdAngle,
		),
	}
	go controller.loop()
	// 进程重启后，若用户之前持久化开启了防锁屏，则自动恢复。
	// 退出应用只停止本次运行，不清除用户偏好。
	if macos.KeepAwakePersisted() {
		child, err := startGuardian(controller.childEvents, guardianModeKeepAwake, 0)
		if err != nil {
			fmt.Fprintln(os.Stderr, "acu: restore persisted keep-awake:", err)
			macos.SetMenuState(text("state.keep_awake_restore_failed"))
		} else {
			controller.child = child
			controller.keepAwakeRequested = true
		}
	}
	macos.RunApp()
	return nil
}

func (c *Controller) loop() {
	lidTicker := time.NewTicker(lidPollInterval)
	defer lidTicker.Stop()
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
			case macos.MenuDiagnostics:
				c.showDiagnostics()
			case macos.MenuLidConfig:
				config := macos.CurrentLidAutomationConfig()
				c.lidAutomation.configure(
					config.Enabled,
					config.ThresholdAngle,
				)
				if config.Enabled {
					c.checkLidAutomationPreflight()
				}
			case macos.MenuQuit:
				c.quit()
			}
		case event := <-c.childEvents:
			c.handleChildEvent(event)
		case now := <-lidTicker.C:
			c.pollLidAutomation(now)
		}
	}
}

func (c *Controller) pollLidAutomation(now time.Time) {
	if !c.lidAutomation.enabled {
		return
	}
	if macos.SessionLocked() {
		c.lidAutomation.suppressUntilReopened()
		return
	}
	angle, ok := macos.ReadLidAngle()
	if !ok {
		return
	}
	hasExternalDisplay :=
		angle <= lidFullyClosedMaximum && macos.HasExternalDisplay()
	canProtect := c.child == nil ||
		(c.child.mode == guardianModeKeepAwake && !c.pendingProtection)
	protectionActive :=
		c.child != nil && c.child.mode == guardianModeProtection

	// 盖子角度变化 → 通知 guardian 恢复显示器亮度。
	// nudge 是合成事件（带 marker），不会触发 event callback 中的
	// acuPhysicalActivity()，因此需要 controller 通过 IPC 转发。
	if protectionActive {
		angleMoved := !c.lidAutomation.angleKnown ||
			math.Abs(angle-c.lidAutomation.lastAngle) >= lidMovementThreshold
		if angleMoved {
			_ = c.child.conn.Write(ipc.Message{Type: "activity"})
		}
	}

	switch c.lidAutomation.observe(
		now,
		angle,
		hasExternalDisplay,
		canProtect,
		protectionActive,
	) {
	case lidActionProtect:
		c.enable(0)
		if c.child == nil && !c.pendingProtection {
			c.lidAutomation.protectionFailed()
		}
	case lidActionAuthenticate:
		c.requestAuthentication()
	}
}

func (c *Controller) checkLidAutomationPreflight() {
	if failures := macos.Preflight(true); failures != 0 {
		macos.ShowPreflightAlert(
			text("alert.lid_automation_not_ready.title"),
			preflightMessage(failures),
			failures,
		)
	}
}

func (c *Controller) enable(timeoutSeconds int) {
	if c.child != nil {
		if c.child.mode == guardianModeKeepAwake {
			c.upgradeToProtection(timeoutSeconds)
		}
		return
	}
	macos.SetMenuState(text("state.preflighting"))

	if failures := macos.Preflight(true); failures != 0 {
		macos.SetMenuState(text("state.start_failed"))
		macos.ShowPreflightAlert(
			text("alert.protection_enable_failed.title"),
			preflightMessage(failures),
			failures,
		)
		return
	}
	c.startProtection(timeoutSeconds)
}

func (c *Controller) upgradeToProtection(timeoutSeconds int) {
	if c.pendingProtection {
		return
	}
	macos.SetMenuState(text("state.preflighting_protection"))
	if failures := macos.Preflight(true); failures != 0 {
		macos.SetMenuState(text("state.keep_awake_active"))
		macos.ShowPreflightAlert(
			text("alert.protection_enable_failed.title"),
			preflightMessage(failures),
			failures,
		)
		return
	}

	c.pendingProtection = true
	c.pendingProtectionTimeout = timeoutSeconds
	macos.SetMenuState(text("state.switching_to_protection"))
	if err := c.child.conn.Write(ipc.Message{Type: "stop"}); err != nil {
		c.pendingProtection = false
		c.pendingProtectionTimeout = 0
		macos.SetMenuState(text("state.keep_awake_active"))
		macos.ShowAlert(
			text("alert.protection_switch_failed.title"),
			err.Error(),
			false,
		)
	}
}

func (c *Controller) startProtection(timeoutSeconds int) {
	child, err := startGuardian(
		c.childEvents,
		guardianModeProtection,
		timeoutSeconds,
	)
	if err != nil {
		macos.SetMenuState(text("state.start_failed"))
		macos.ShowAlert(
			text("alert.guardian_start_failed.title"),
			err.Error(),
			false,
		)
		c.restoreKeepAwakeIfRequested()
		return
	}
	c.child = child
	if timeoutSeconds > 0 {
		macos.SetMenuState(text("state.starting_test"))
	} else {
		macos.SetMenuState(text("state.starting"))
	}
}

func (c *Controller) toggleKeepAwake() {
	if c.child != nil {
		if c.child.mode != guardianModeKeepAwake {
			macos.ShowAlert(
				text("alert.keep_awake_enable_failed.title"),
				text("alert.protection_active.message"),
				false,
			)
			return
		}
		if c.pendingProtection {
			return
		}
		macos.SetMenuState(text("state.stopping_keep_awake"))
		if err := c.child.conn.Write(ipc.Message{Type: "stop"}); err != nil {
			macos.SetMenuState(text("state.stop_keep_awake_failed"))
		} else {
			c.keepAwakeRequested = false
			macos.SetKeepAwakePersisted(false)
		}
		return
	}

	macos.SetMenuState(text("state.preflighting_keep_awake"))
	if failures := macos.PreflightKeepAwake(true); failures != 0 {
		macos.SetMenuState(text("state.start_failed"))
		macos.ShowPreflightAlert(
			text("alert.keep_awake_enable_failed.title"),
			preflightMessage(failures),
			failures,
		)
		return
	}

	child, err := startGuardian(
		c.childEvents,
		guardianModeKeepAwake,
		0,
	)
	if err != nil {
		macos.SetMenuState(text("state.start_failed"))
		macos.ShowAlert(
			text("alert.keep_awake_process_start_failed.title"),
			err.Error(),
			false,
		)
		return
	}
	c.child = child
	c.keepAwakeRequested = true
	macos.SetKeepAwakePersisted(true)
	macos.SetMenuState(text("state.starting_keep_awake"))
}

func (c *Controller) requestAuthentication() {
	if c.child == nil || c.child.mode != guardianModeProtection {
		return
	}
	_ = c.child.conn.Write(ipc.Message{Type: "request_auth"})
}

func (c *Controller) quit() {
	c.keepAwakeRequested = false
	if c.child == nil {
		macos.StopApp()
		return
	}
	c.quitWhenDisabled = true
	c.pendingProtection = false
	c.pendingProtectionTimeout = 0
	if c.child.mode == guardianModeKeepAwake {
		macos.SetMenuState(text("state.stopping_keep_awake_and_quitting"))
		_ = c.child.conn.Write(ipc.Message{Type: "stop"})
		return
	}
	macos.SetMenuState(text("state.waiting_auth_to_quit"))
	c.requestAuthentication()
}

func (c *Controller) showDiagnostics() {
	failures := macos.Preflight(false)
	policy := policyDescription()
	message := fmt.Sprintf(
		text("diagnostics.format"),
		preflightSummary(failures),
		policy,
		lidSensorDescription(),
	)
	macos.ShowPreflightAlert(
		text("alert.diagnostics.title"),
		message,
		failures,
	)
}

func lidSensorDescription() string {
	angle, ok := macos.ReadLidAngle()
	if !ok {
		return text("diagnostics.unavailable")
	}
	return fmt.Sprintf("%.0f°", angle)
}

func (c *Controller) handleChildEvent(event childEvent) {
	if event.child != c.child {
		return
	}
	if event.exited {
		c.child = nil
		if event.child.mode == guardianModeProtection {
			c.lidAutomation.protectionStopped()
		}
		if event.child.mode == guardianModeKeepAwake {
			macos.SetKeepAwakeActive(false)
			if event.err != nil {
				c.keepAwakeRequested = false
			}
		}
		if event.err == nil && c.startPendingProtection() {
			return
		}
		if event.err != nil && !event.child.fatalReported {
			c.pendingProtection = false
			c.pendingProtectionTimeout = 0
			title := text("state.protection_lost")
			message := text("alert.protection_lost.message")
			if event.child.mode == guardianModeKeepAwake {
				title = text("state.keep_awake_lost")
				message = text("alert.keep_awake_lost.message")
			}
			macos.SetMenuState(title)
			macos.ShowAlert(
				title,
				message,
				false,
			)
		}
		if event.child.mode == guardianModeProtection {
			c.restoreKeepAwakeIfRequested()
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
			macos.SetMenuState(text("state.keep_awake_active"))
		} else if event.message.State == "degraded" &&
			event.child.mode == guardianModeKeepAwake {
			macos.SetMenuState(text("state.keep_awake_error"))
		} else if event.message.State == "disarming" &&
			event.child.mode == guardianModeKeepAwake {
			macos.SetMenuState(text("state.stopping_keep_awake"))
		} else if event.message.State == "protected" && event.child.testMode {
			macos.SetMenuState(text("state.test_active"))
		} else {
			macos.SetMenuState(displayState(event.message.State))
		}
		if event.message.State == "disabled" {
			if event.child.mode == guardianModeKeepAwake {
				macos.SetKeepAwakeActive(false)
			} else {
				c.lidAutomation.protectionStopped()
			}
			event.child.conn.Close()
			c.child = nil
			if c.quitWhenDisabled {
				macos.StopApp()
				return
			}
			if !c.startPendingProtection() &&
				event.child.mode == guardianModeProtection {
				c.restoreKeepAwakeIfRequested()
			}
		}
	case "fatal":
		event.child.fatalReported = true
		macos.SetMenuState(text("state.start_failed"))
		macos.ShowAlert(
			text("alert.guardian_start_failed.title"),
			fmt.Sprintf(text("alert.error_code.format"), event.message.Code),
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

func (c *Controller) restoreKeepAwakeIfRequested() {
	if !c.shouldRestoreKeepAwake() {
		return
	}
	child, err := startGuardian(
		c.childEvents,
		guardianModeKeepAwake,
		0,
	)
	if err != nil {
		c.keepAwakeRequested = false
		macos.SetMenuState(text("state.keep_awake_restore_failed"))
		macos.ShowAlert(
			text("alert.keep_awake_restore_failed.title"),
			err.Error(),
			false,
		)
		return
	}
	c.child = child
	macos.SetMenuState(text("state.restoring_keep_awake"))
}

func (c *Controller) shouldRestoreKeepAwake() bool {
	return c.keepAwakeRequested &&
		c.child == nil &&
		!c.quitWhenDisabled &&
		!c.pendingProtection
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
		return text("policy.managed")
	case "enrolled":
		return text("policy.enrolled")
	case "unknown":
		return text("policy.unknown")
	default:
		return text("policy.allowed")
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
	return fmt.Sprintf(
		text("preflight.retry.format"),
		preflightSummary(failures),
	)
}

func preflightSummary(failures macos.PreflightFailures) string {
	if failures == 0 {
		return text("preflight.all_passed")
	}
	var problems []string
	if failures&macos.FailureAccessibility != 0 {
		problems = append(problems, text("preflight.accessibility"))
	}
	if failures&macos.FailureListenEvents != 0 &&
		failures&macos.FailureAccessibility == 0 {
		problems = append(problems, text("preflight.listen_events"))
	}
	if failures&macos.FailurePostEvents != 0 &&
		failures&macos.FailureAccessibility == 0 {
		problems = append(problems, text("preflight.post_events"))
	}
	if failures&macos.FailureAuth != 0 {
		problems = append(problems, text("preflight.authentication"))
	}
	if failures&macos.FailureDisplay != 0 {
		problems = append(problems, text("preflight.display"))
	}
	if failures&macos.FailureSessionLocked != 0 {
		problems = append(problems, text("preflight.session_locked"))
	}
	return strings.Join(problems, "\n")
}

func displayState(state string) string {
	switch state {
	case "protected":
		return text("state.protected")
	case "awake":
		return text("state.keep_awake_active")
	case "authenticating":
		return text("state.authenticating")
	case "disarming":
		return text("state.disarming")
	case "degraded":
		return text("state.degraded")
	case "failed":
		return text("state.start_failed")
	default:
		return text("state.disabled")
	}
}

func text(key string) string {
	return macos.Localized(key)
}
