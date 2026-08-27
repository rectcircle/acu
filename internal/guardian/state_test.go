package guardian

import (
	"errors"
	"testing"
)

func TestStateMachineProtectionLifecycle(t *testing.T) {
	machine := NewStateMachine(StateDisabled)
	for _, state := range []State{
		StateArming,
		StateProtected,
		StateAuthenticating,
		StateDisarming,
		StateDisabled,
	} {
		if err := machine.Transition(state); err != nil {
			t.Fatalf("transition to %s: %v", state, err)
		}
	}
}

func TestStateMachineRejectsUnauthenticatedDisarm(t *testing.T) {
	machine := NewStateMachine(StateProtected)
	err := machine.Transition(StateDisarming)
	if !errors.Is(err, ErrInvalidTransition) {
		t.Fatalf("expected invalid transition, got %v", err)
	}
	if got := machine.State(); got != StateProtected {
		t.Fatalf("state changed after rejected transition: %s", got)
	}
}

func TestStateMachineAllowsExplicitTestTimeout(t *testing.T) {
	machine := NewStateMachine(StateProtected)
	if err := machine.TransitionTestTimeout(); err != nil {
		t.Fatal(err)
	}
	if got := machine.State(); got != StateDisarming {
		t.Fatalf("got %s, want %s", got, StateDisarming)
	}
}

func TestStateMachineAllowsAuthenticationFromDegraded(t *testing.T) {
	machine := NewStateMachine(StateDegraded)
	if err := machine.Transition(StateAuthenticating); err != nil {
		t.Fatal(err)
	}
	if err := machine.Transition(StateDisarming); err != nil {
		t.Fatal(err)
	}
}

func TestStateMachineKeepAwakeLifecycle(t *testing.T) {
	machine := NewStateMachine(StateDisabled)
	for _, state := range []State{
		StateArming,
		StateAwake,
		StateDegraded,
		StateAwake,
		StateDisarming,
		StateDisabled,
	} {
		if err := machine.Transition(state); err != nil {
			t.Fatalf("transition to %s: %v", state, err)
		}
	}
}
