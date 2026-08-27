package guardian

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/rectcircle/acu-helper/internal/config"
	"github.com/rectcircle/acu-helper/internal/ipc"
	"github.com/rectcircle/acu-helper/internal/macos"
)

const (
	messageHello       = "hello"
	messageRequestAuth = "request_auth"
	messageStop        = "stop"
	messageState       = "state"
	messageFatal       = "fatal"
	modeProtection     = "protection"
	modeKeepAwake      = "keep_awake"
	testTimeoutSeconds = 15
)

type command int

const (
	commandAuthenticate command = iota + 1
	commandStop
)

func Run(conn *ipc.Conn, cfg config.Config) error {
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
			macos.StopInputGuard()
			macos.HideShields()
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
	go func() {
		commandChannel := (<-chan command)(commands)
		failures := 0
		for {
			select {
			case <-macos.GuardianEnterEvents():
				enqueueAuthenticate(commands)
			case next, ok := <-commandChannel:
				if !ok {
					commandChannel = nil
					continue
				}
				if next != commandAuthenticate {
					continue
				}
				state := machine.State()
				if state != StateProtected && state != StateDegraded {
					continue
				}
				previous := state
				if err := machine.Transition(StateAuthenticating); err != nil {
					continue
				}
				writeState(conn, StateAuthenticating)
				macos.SetInputAuthenticationMode(true)
				macos.SetShieldAuthenticationMode(true)

				authenticated, authErr := macos.Authenticate()
				if authErr == nil && authenticated {
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
				if machine.State() == StateProtected {
					_ = machine.Transition(StateDegraded)
					writeState(conn, StateDegraded)
					macos.ShowInputGuardFailure()
				}
			case <-ticker.C:
				if machine.State() != StateProtected ||
					macos.SessionLocked() ||
					macos.IdleDuration() < cfg.IdleBeforeNudge {
					continue
				}
				if err := macos.NudgeCursor(
					cfg.NudgeDistance,
					cfg.RestoreDelay,
					marker,
				); err != nil {
					failures++
					if failures >= cfg.FailureThreshold {
						_ = machine.Transition(StateDegraded)
						writeState(conn, StateDegraded)
					}
					continue
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
			if errors.Is(err, io.EOF) {
				return
			}
			return
		}
		if message.Type == messageRequestAuth {
			enqueueAuthenticate(commands)
		} else if message.Type == messageStop {
			enqueueCommand(commands, commandStop)
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
	_ = conn.Write(ipc.Message{Type: messageState, State: string(state)})
}

func randomMarker() (uint64, error) {
	var data [8]byte
	if _, err := rand.Read(data[:]); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint64(data[:]), nil
}
