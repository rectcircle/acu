package guardian

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"time"

	"github.com/rectcircle/acu/internal/config"
	"github.com/rectcircle/acu/internal/ipc"
	"github.com/rectcircle/acu/internal/macos"
)

const (
	messageHello            = "hello"
	messageRequestAuth      = "request_auth"
	messageStop             = "stop"
	messageState            = "state"
	messageFatal            = "fatal"
	messageActivity         = "activity"
	modeProtection          = "protection"
	modeKeepAwake           = "keep_awake"
	testTimeoutSeconds      = 30
	idleTimeout             = 15 * time.Second
	restoreAttempts         = 3
	restoreRetryDelay       = 100 * time.Millisecond
	sessionLockPollInterval = 30 * time.Second
)

type command int

const (
	commandAuthenticate command = iota + 1
	commandStop
	commandActivity
)

func Run(conn *ipc.Conn, cfg config.Config) (runErr error) {
	defer func() {
		if runErr != nil {
			slog.Error("guardian failed", "error", runErr)
		}
	}()
	slog.Info("guardian starting")
	if err := cfg.Validate(); err != nil {
		return err
	}
	hello, err := conn.Read()
	if err != nil {
		return fmt.Errorf("read guardian handshake: %w", err)
	}
	mode, err := validateHello(hello)
	if err != nil {
		return err
	}
	if mode == modeKeepAwake {
		return runKeepAwake(conn, cfg)
	}

	machine := NewStateMachine(StateArming)
	marker, err := randomMarker()
	if err != nil {
		return fmt.Errorf("create event marker: %w", err)
	}

	if err := macos.StartInputGuard(marker); err != nil {
		_ = machine.Transition(StateFailed)
		_ = conn.Write(ipc.Message{Type: messageFatal, Code: "event_tap_unavailable"})
		return err
	}
	if err := macos.ShowShields(); err != nil {
		macos.StopInputGuard()
		_ = machine.Transition(StateFailed)
		_ = conn.Write(ipc.Message{Type: messageFatal, Code: "no_displays"})
		return err
	}

	var cleanupOnce sync.Once
	cleanup := func() {
		cleanupOnce.Do(func() {
			slog.Info("protection cleanup started")
			for attempt := 0; attempt < restoreAttempts; attempt++ {
				if macos.RestorePowerSettings() {
					break
				}
				slog.Warn("brightness restoration failed", "attempt", attempt+1)
				if attempt+1 == restoreAttempts {
					slog.Error("brightness restoration retries exhausted")
				}
				if attempt+1 < restoreAttempts {
					time.Sleep(restoreRetryDelay)
				}
			}
			macos.StopInputGuard()
			macos.HideShields()
			slog.Info("protection cleanup completed")
		})
	}
	defer cleanup()

	if err := machine.Transition(StateProtected); err != nil {
		return err
	}
	writeState(conn, StateProtected)

	if hello.TimeoutSeconds == testTimeoutSeconds {
		go func() {
			remaining := testTimeoutSeconds
			macos.SetShieldCountdown(remaining)
			countdown := time.NewTicker(time.Second)
			defer countdown.Stop()
			for remaining > 0 {
				<-countdown.C
				remaining--
				macos.SetShieldCountdown(remaining)
			}
			if err := machine.TransitionTestTimeout(); err != nil {
				return
			}
			writeState(conn, StateDisarming)
			cleanup()
			_ = machine.Transition(StateDisabled)
			writeState(conn, StateDisabled)
			macos.StopApp()
		}()
	}

	commands := make(chan command, 1)
	go readCommands(conn, commands)

	ticker := time.NewTicker(cfg.PollInterval)
	defer ticker.Stop()
	lockTicker := time.NewTicker(sessionLockPollInterval)
	defer lockTicker.Stop()
	go func() {
		commandChannel := (<-chan command)(commands)
		failures := 0
		lastActivity := time.Now()
		powerSaved := false
		systemLocked := false
		type authenticationResult struct {
			authenticated bool
			err           error
		}
		authResults := make(chan authenticationResult, 1)
		previous := StateProtected
		// 省电恢复：有物理操作 → 立即恢复显示器亮度。
		// 事件经 channel 投递至本 goroutine 后串行恢复。DDC 读写含等待和重试，
		// 多屏或设备无响应时可能延迟后续事件；失败时保留恢复记录。
		restoreIfActive := func(reason string) {
			if powerSaved {
				powerSaved = !macos.RestorePowerSettings()
				if powerSaved {
					slog.Warn("display brightness restore failed", "reason", reason)
				} else {
					slog.Info("display brightness restored", "reason", reason)
				}
			}
		}
		disarmForSystemLock := func() bool {
			state := machine.State()
			if state != StateProtected && state != StateDegraded &&
				state != StateAuthenticating {
				return false
			}
			if err := machine.TransitionSystemLock(); err != nil {
				slog.Error("system lock teardown rejected", "error", err)
				return false
			}
			writeState(conn, StateDisarming)
			ticker.Stop()
			cleanup()
			_ = machine.Transition(StateDisabled)
			writeState(conn, StateDisabled)
			macos.StopApp()
			return true
		}
		for {
			select {
			case <-macos.GuardianEnterEvents():
				enqueueAuthenticate(commands)
			case <-macos.PhysicalActivityEvents():
				lastActivity = time.Now()
				restoreIfActive("physical_input")
			case <-macos.LidAngleChangedEvents():
				lastActivity = time.Now()
				restoreIfActive("lid_angle")
			case <-macos.PowerReconfigureEvents():
				// Display connect/disconnect: restore first, the next
				// idle cycle re-reads fresh values before re-dimming.
				lastActivity = time.Now()
				restoreIfActive("display_reconfiguration")
			case next, ok := <-commandChannel:
				if !ok {
					commandChannel = nil
					continue
				}
				if next == commandActivity {
					lastActivity = time.Now()
					restoreIfActive("controller_activity")
					continue
				}
				if next != commandAuthenticate {
					continue
				}
				lastActivity = time.Now()
				restoreIfActive("authentication")
				state := machine.State()
				if state != StateProtected && state != StateDegraded {
					continue
				}
				previous = state
				if err := machine.Transition(StateAuthenticating); err != nil {
					continue
				}
				writeState(conn, StateAuthenticating)
				macos.SetInputAuthenticationMode(true)
				macos.SetShieldAuthenticationMode(true)

				slog.Info("authentication started")
				go func() {
					authenticated, err := macos.Authenticate()
					authResults <- authenticationResult{authenticated, err}
				}()
			case result := <-authResults:
				if machine.State() != StateAuthenticating {
					continue
				}
				slog.Info("authentication completed", "authenticated", result.authenticated)
				if result.err != nil {
					slog.Warn("authentication failed", "error", result.err)
				}
				if result.err == nil && result.authenticated {
					_ = machine.Transition(StateDisarming)
					writeState(conn, StateDisarming)
					ticker.Stop()
					cleanup()
					_ = machine.Transition(StateDisabled)
					writeState(conn, StateDisabled)
					macos.StopApp()
					return
				}

				macos.SetInputAuthenticationMode(false)
				macos.SetShieldAuthenticationMode(false)
				if previous == StateDegraded {
					_ = machine.Transition(StateDegraded)
					writeState(conn, StateDegraded)
				} else {
					_ = machine.Transition(StateProtected)
					writeState(conn, StateProtected)
				}
			case <-macos.TapDegradedEvents():
				slog.Warn("input guard degraded")
				if machine.State() == StateProtected {
					_ = machine.Transition(StateDegraded)
					writeState(conn, StateDegraded)
					macos.ShowInputGuardFailure()
				}
			case source := <-macos.SessionLockEvents():
				slog.Info("system session event received", "source", source)
				// Distributed notifications provide the fast path. Remember the
				// state to suppress cursor nudges while teardown is starting.
				systemLocked = true
				if disarmForSystemLock() {
					return
				}
			case <-lockTicker.C:
				if machine.State() != StateProtected &&
					machine.State() != StateDegraded &&
					machine.State() != StateAuthenticating {
					continue
				}
				locked := macos.SessionLocked()
				slog.Info("system lock fallback checked", "locked", locked)
				if !locked {
					continue
				}
				systemLocked = true
				if disarmForSystemLock() {
					return
				}
			case <-ticker.C:
				// 省电：15 秒无物理操作 → 硬件亮度调到 0，Gamma 输出缩放至 20%。
				// 重检状态：测试模式超时 goroutine 可能在状态检查后、保存前执行 cleanup
				// 并调暗屏幕，重检缩窄竞态窗口（残余窗口由 C 侧 mutex 保护快照原子性）
				if machine.State() == StateProtected &&
					!powerSaved &&
					time.Since(lastActivity) >= idleTimeout {
					powerSaved = macos.SavePowerSettings()
					if powerSaved {
						slog.Info("displays dimmed")
					} else {
						slog.Warn("display dimming unavailable")
					}
					if machine.State() != StateProtected {
						powerSaved = !macos.RestorePowerSettings()
					}
				}

				// 防锁屏：45 秒无系统活动 → nudge（nudge 事件带 marker，不计为操作）
				if machine.State() != StateProtected ||
					systemLocked ||
					macos.IdleDuration() < cfg.IdleBeforeNudge {
					continue
				}
				if err := macos.NudgeCursor(
					cfg.NudgeDistance,
					cfg.RestoreDelay,
					marker,
				); err != nil {
					slog.Warn("cursor activity failed", "error", err)
					failures++
					if failures >= cfg.FailureThreshold {
						_ = machine.Transition(StateDegraded)
						writeState(conn, StateDegraded)
					}
					continue
				} else {
					slog.Info("keep-awake cursor nudge posted", "displays_dimmed", powerSaved)
				}
				failures = 0
			}
		}
	}()

	macos.RunApp()
	return nil
}

func runKeepAwake(conn *ipc.Conn, cfg config.Config) error {
	marker, err := randomMarker()
	if err != nil {
		return fmt.Errorf("create event marker: %w", err)
	}

	machine := NewStateMachine(StateArming)
	if err := machine.Transition(StateAwake); err != nil {
		return err
	}
	writeState(conn, machine.State())
	commands := make(chan command, 1)
	go readCommands(conn, commands)

	ticker := time.NewTicker(cfg.PollInterval)
	defer ticker.Stop()
	go func() {
		failures := 0
		for {
			select {
			case next, ok := <-commands:
				if !ok || next == commandStop {
					_ = machine.Transition(StateDisarming)
					writeState(conn, machine.State())
					_ = machine.Transition(StateDisabled)
					writeState(conn, StateDisabled)
					macos.StopApp()
					return
				}
			case <-ticker.C:
				if macos.SessionLocked() ||
					macos.IdleDuration() < cfg.IdleBeforeNudge {
					continue
				}
				if err := macos.NudgeCursor(
					cfg.NudgeDistance,
					cfg.RestoreDelay,
					marker,
				); err != nil {
					slog.Warn("cursor activity failed", "error", err)
					failures++
					if failures >= cfg.FailureThreshold &&
						machine.State() != StateDegraded {
						_ = machine.Transition(StateDegraded)
						writeState(conn, machine.State())
					}
					continue
				}
				failures = 0
				if machine.State() == StateDegraded {
					_ = machine.Transition(StateAwake)
					writeState(conn, machine.State())
				}
			}
		}
	}()

	macos.RunApp()
	return nil
}

func validateHello(hello ipc.Message) (string, error) {
	if hello.Type != messageHello || hello.Token == "" {
		return "", errors.New("invalid guardian handshake")
	}
	mode := hello.Mode
	if mode == "" {
		mode = modeProtection
	}
	if mode != modeProtection && mode != modeKeepAwake {
		return "", errors.New("invalid guardian mode")
	}
	if hello.TimeoutSeconds != 0 && hello.TimeoutSeconds != testTimeoutSeconds {
		return "", errors.New("invalid guardian test timeout")
	}
	if mode == modeKeepAwake && hello.TimeoutSeconds != 0 {
		return "", errors.New("keep-awake mode does not support a timeout")
	}
	return mode, nil
}

func readCommands(conn *ipc.Conn, commands chan<- command) {
	defer enqueueCommand(commands, commandStop)
	for {
		message, err := conn.Read()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				slog.Error("guardian IPC read failed", "error", err)
			}
			if errors.Is(err, io.EOF) {
				return
			}
			return
		}
		if message.Type == messageRequestAuth {
			enqueueAuthenticate(commands)
		} else if message.Type == messageStop {
			enqueueCommand(commands, commandStop)
		} else if message.Type == messageActivity {
			enqueueCommand(commands, commandActivity)
		}
	}
}

func enqueueAuthenticate(commands chan<- command) {
	enqueueCommand(commands, commandAuthenticate)
}

func enqueueCommand(commands chan<- command, next command) {
	select {
	case commands <- next:
	default:
	}
}

func writeState(conn *ipc.Conn, state State) {
	if err := conn.Write(ipc.Message{Type: messageState, State: string(state)}); err != nil {
		slog.Error("guardian state delivery failed", "state", state, "error", err)
	}
}

func randomMarker() (uint64, error) {
	var data [8]byte
	if _, err := rand.Read(data[:]); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint64(data[:]), nil
}
