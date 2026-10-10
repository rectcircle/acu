package app

import (
	"testing"
	"time"
)

func TestBluetoothPresenceArmsAfterStableConnection(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	automation := newBluetoothPresenceAutomation(true)

	if action := automation.observe(start, true, false); action != bluetoothPresenceNoAction {
		t.Fatalf("initial connection action = %v", action)
	}
	if action := automation.observe(
		start.Add(bluetoothPresenceReturnStable-time.Second), true, false,
	); action != bluetoothPresenceNoAction {
		t.Fatalf("unstable connection action = %v", action)
	}
	if action := automation.observe(
		start.Add(bluetoothPresenceReturnStable), true, false,
	); action != bluetoothPresenceNoAction || !automation.armed {
		t.Fatalf("stable connection did not arm: action=%v armed=%v", action, automation.armed)
	}
}

func TestBluetoothPresenceConnectsWhenFirstEnabledWhileDisconnected(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	automation := newBluetoothPresenceAutomation(false)
	automation.configure(true)

	if action := automation.observe(start, false, false); action != bluetoothPresenceConnect {
		t.Fatalf("initial disconnected action = %v, want connect", action)
	}
	if action := automation.observe(
		start.Add(bluetoothPresenceRetryInterval-time.Second), false, false,
	); action != bluetoothPresenceNoAction {
		t.Fatalf("retry occurred too early: %v", action)
	}
	if action := automation.observe(
		start.Add(bluetoothPresenceRetryInterval), false, false,
	); action != bluetoothPresenceConnect {
		t.Fatalf("retry action = %v, want connect", action)
	}

	connectedAt := start.Add(bluetoothPresenceRetryInterval + time.Second)
	automation.observe(connectedAt, true, false)
	if action := automation.observe(
		connectedAt.Add(bluetoothPresenceReturnStable), true, false,
	); action != bluetoothPresenceNoAction || !automation.armed || automation.waitingForConnection {
		t.Fatalf("initial connection did not arm: action=%v state=%+v", action, automation)
	}
}

func TestBluetoothPresenceProtectsAfterDebouncedDisconnect(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	automation := &bluetoothPresenceAutomation{enabled: true, armed: true}

	if action := automation.observe(start, false, false); action != bluetoothPresenceNoAction {
		t.Fatalf("first disconnect action = %v", action)
	}
	if action := automation.observe(
		start.Add(bluetoothPresenceLostGrace-time.Second), false, false,
	); action != bluetoothPresenceNoAction {
		t.Fatalf("disconnect before grace action = %v", action)
	}
	if action := automation.observe(
		start.Add(bluetoothPresenceLostGrace), false, false,
	); action != bluetoothPresenceProtect {
		t.Fatalf("disconnect at grace action = %v, want protect", action)
	}
	if automation.armed || !automation.waitingForConnection {
		t.Fatalf("state after protection: armed=%v waiting=%v", automation.armed, automation.waitingForConnection)
	}
}

func TestBluetoothPresenceCancelsDisconnectGraceWhenConnectionReturns(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	automation := &bluetoothPresenceAutomation{enabled: true, armed: true}

	automation.observe(start, false, false)
	if action := automation.observe(start.Add(2*time.Second), true, false); action != bluetoothPresenceNoAction {
		t.Fatalf("reconnection action = %v", action)
	}
	if action := automation.observe(start.Add(bluetoothPresenceLostGrace), false, false); action != bluetoothPresenceNoAction {
		t.Fatalf("old disconnect grace was not canceled: %v", action)
	}
	if action := automation.observe(start.Add(bluetoothPresenceLostGrace+bluetoothPresenceLostGrace), false, false); action != bluetoothPresenceProtect {
		t.Fatalf("continued disconnect action = %v, want protect", action)
	}
}

func TestBluetoothPresenceReconnectsOnlyAfterUnlock(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	automation := &bluetoothPresenceAutomation{
		enabled:              true,
		waitingForConnection: true,
	}

	if action := automation.observe(start, false, true); action != bluetoothPresenceNoAction {
		t.Fatalf("connect attempted while protected: %v", action)
	}
	if action := automation.observe(start.Add(time.Second), false, false); action != bluetoothPresenceConnect {
		t.Fatalf("first post-unlock action = %v, want connect", action)
	}
	if action := automation.observe(
		start.Add(time.Second+bluetoothPresenceRetryInterval-time.Second), false, false,
	); action != bluetoothPresenceNoAction {
		t.Fatalf("retry occurred too early: %v", action)
	}
	if action := automation.observe(
		start.Add(time.Second+bluetoothPresenceRetryInterval), false, false,
	); action != bluetoothPresenceConnect {
		t.Fatalf("retry action = %v, want connect", action)
	}
	connectedAt := start.Add(2 * time.Minute)
	if action := automation.observe(connectedAt, true, false); action != bluetoothPresenceNoAction {
		t.Fatalf("connection action = %v", action)
	}
	if action := automation.observe(
		connectedAt.Add(bluetoothPresenceReturnStable), true, false,
	); action != bluetoothPresenceNoAction || !automation.armed || automation.waitingForConnection {
		t.Fatalf("returned connection did not rearm: action=%v armed=%v waiting=%v", action, automation.armed, automation.waitingForConnection)
	}
}

func TestBluetoothPresenceWaitsForUnlockBeforeRearming(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	automation := &bluetoothPresenceAutomation{enabled: true, armed: true}
	automation.observe(start, false, false)
	if action := automation.observe(
		start.Add(bluetoothPresenceLostGrace), false, true,
	); action != bluetoothPresenceProtect {
		t.Fatalf("disconnect action = %v, want protect", action)
	}
	if action := automation.observe(start.Add(20*time.Second), true, true); action != bluetoothPresenceNoAction {
		t.Fatalf("connected while protected action = %v", action)
	}
	if automation.armed {
		t.Fatal("automation rearmed while protection was active")
	}
	if action := automation.observe(start.Add(30*time.Second), true, false); action != bluetoothPresenceNoAction {
		t.Fatalf("unlock observation action = %v", action)
	}
	if action := automation.observe(
		start.Add(30*time.Second+bluetoothPresenceReturnStable), true, false,
	); action != bluetoothPresenceNoAction || !automation.armed {
		t.Fatalf("automation did not rearm after unlock: action=%v armed=%v", action, automation.armed)
	}
}

func TestBluetoothPresenceUnknownStateDoesNotTrigger(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	automation := &bluetoothPresenceAutomation{enabled: true, armed: true}
	automation.observe(start, false, false)
	automation.observeUnknown()

	if action := automation.observe(
		start.Add(bluetoothPresenceLostGrace+time.Second), false, false,
	); action != bluetoothPresenceNoAction {
		t.Fatalf("unknown device state triggered action: %v", action)
	}
}

func TestBluetoothPresenceDisableClearsArmedState(t *testing.T) {
	automation := &bluetoothPresenceAutomation{
		enabled:              true,
		armed:                true,
		waitingForConnection: true,
	}
	automation.configure(false)

	if automation.armed || automation.waitingForConnection || automation.enabled {
		t.Fatalf("disable did not clear state: %+v", automation)
	}
}
