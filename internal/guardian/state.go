package guardian

import (
	"errors"
	"fmt"
	"log/slog"
	"sync"
)

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

var ErrInvalidTransition = errors.New("invalid state transition")

type StateMachine struct {
	mu    sync.RWMutex
	state State
}

func NewStateMachine(initial State) *StateMachine {
	return &StateMachine{state: initial}
}

func (m *StateMachine) State() State {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.state
}

func (m *StateMachine) Transition(next State) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.state == next {
		return nil
	}
	if !canTransition(m.state, next) {
		slog.Warn("state transition rejected", "from", m.state, "to", next)
		return fmt.Errorf("%w: %s -> %s", ErrInvalidTransition, m.state, next)
	}
	slog.Info("guardian state changed", "from", m.state, "to", next)
	m.state = next
	return nil
}

// TransitionSystemLock permits teardown without ACU authentication because macOS
// has already taken responsibility for protecting the session.
func (m *StateMachine) TransitionSystemLock() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	switch m.state {
	case StateProtected, StateAuthenticating, StateDegraded:
		slog.Info("guardian system lock teardown", "from", m.state)
		m.state = StateDisarming
		return nil
	default:
		return fmt.Errorf("%w: system lock from %s", ErrInvalidTransition, m.state)
	}
}

func (m *StateMachine) TransitionTestTimeout() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	switch m.state {
	case StateProtected, StateAuthenticating, StateDegraded:
		m.state = StateDisarming
		return nil
	default:
		return fmt.Errorf(
			"%w: test timeout from %s",
			ErrInvalidTransition,
			m.state,
		)
	}
}

func canTransition(current, next State) bool {
	switch current {
	case StateDisabled:
		return next == StateArming
	case StateArming:
		return next == StateAwake || next == StateProtected ||
			next == StateFailed || next == StateDisabled
	case StateAwake:
		return next == StateDisarming || next == StateDegraded
	case StateProtected:
		return next == StateAuthenticating || next == StateDegraded
	case StateAuthenticating:
		return next == StateProtected || next == StateDisarming || next == StateDegraded
	case StateDegraded:
		return next == StateAwake || next == StateAuthenticating ||
			next == StateDisarming
	case StateDisarming:
		return next == StateDisabled || next == StateDegraded
	case StateFailed:
		return next == StateDisabled || next == StateArming
	default:
		return false
	}
}
