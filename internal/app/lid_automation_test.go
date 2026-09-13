package app

import (
	"testing"
	"time"
)

func TestLidAutomationProtectsAfterDebounceAndAuthenticatesOnOpen(t *testing.T) {
	automation := newLidAutomation(true, 45)
	start := time.Unix(100, 0)

	if action := automation.observe(start, 40, false, true, false); action != lidActionNone {
		t.Fatalf("unexpected initial action: %v", action)
	}
	if action := automation.observe(
		start.Add(lidStableDelay-time.Millisecond),
		40,
		false,
		true,
		false,
	); action != lidActionNone {
		t.Fatalf("triggered before debounce elapsed: %v", action)
	}
	if action := automation.observe(
		start.Add(lidStableDelay),
		40,
		false,
		true,
		false,
	); action != lidActionProtect {
		t.Fatalf("expected protection action, got %v", action)
	}
	if action := automation.observe(
		start.Add(2*time.Second),
		51,
		false,
		false,
		true,
	); action != lidActionAuthenticate {
		t.Fatalf("expected authentication action, got %v", action)
	}
	if action := automation.observe(
		start.Add(3*time.Second),
		51,
		false,
		false,
		true,
	); action != lidActionNone {
		t.Fatalf("authentication repeated without another close: %v", action)
	}
}

func TestLidAutomationSuppressesClosedClamshellWithExternalDisplay(t *testing.T) {
	automation := newLidAutomation(true, 45)
	start := time.Unix(200, 0)

	if action := automation.observe(start, 1, true, true, false); action != lidActionNone {
		t.Fatalf("unexpected closed-clamshell action: %v", action)
	}
	if action := automation.observe(
		start.Add(2*time.Second),
		1,
		true,
		true,
		false,
	); action != lidActionNone {
		t.Fatalf("closed clamshell triggered protection: %v", action)
	}
	if action := automation.observe(
		start.Add(3*time.Second),
		20,
		false,
		true,
		false,
	); action != lidActionNone {
		t.Fatalf("opening a suppressed clamshell triggered protection: %v", action)
	}
	if action := automation.observe(
		start.Add(4*time.Second),
		55,
		false,
		true,
		false,
	); action != lidActionNone {
		t.Fatalf("fully reopening should only re-arm: %v", action)
	}
}

func TestLidAutomationDoesNotTriggerWhileLidIsStillMovingClosed(t *testing.T) {
	automation := newLidAutomation(true, 45)
	start := time.Unix(250, 0)

	for index, angle := range []float64{40, 30, 20} {
		action := automation.observe(
			start.Add(time.Duration(index)*lidStableDelay),
			angle,
			false,
			true,
			false,
		)
		if action != lidActionNone {
			t.Fatalf("moving lid triggered protection at %.0f degrees", angle)
		}
	}
	if action := automation.observe(
		start.Add(3*lidStableDelay),
		1,
		true,
		true,
		false,
	); action != lidActionNone {
		t.Fatalf("completed external-display clamshell triggered protection: %v", action)
	}
}

func TestLidAutomationDoesNotOwnExistingManualProtection(t *testing.T) {
	automation := newLidAutomation(true, 45)
	start := time.Unix(300, 0)

	automation.observe(start, 30, false, false, true)
	if action := automation.observe(
		start.Add(lidStableDelay),
		30,
		false,
		false,
		true,
	); action != lidActionNone {
		t.Fatalf("manual protection was replaced: %v", action)
	}
	if action := automation.observe(
		start.Add(2*time.Second),
		55,
		false,
		false,
		true,
	); action != lidActionNone {
		t.Fatalf("manual protection caused automatic authentication: %v", action)
	}
}

func TestLidAutomationRequiresReopenBeforeRetrigger(t *testing.T) {
	automation := newLidAutomation(true, 45)
	start := time.Unix(400, 0)

	automation.observe(start, 40, false, true, false)
	if action := automation.observe(
		start.Add(lidStableDelay),
		40,
		false,
		true,
		false,
	); action != lidActionProtect {
		t.Fatalf("expected first protection action, got %v", action)
	}
	automation.protectionFailed()
	if action := automation.observe(
		start.Add(3*time.Second),
		40,
		false,
		true,
		false,
	); action != lidActionNone {
		t.Fatalf("protection retried without reopening: %v", action)
	}

	automation.observe(start.Add(4*time.Second), 55, false, true, false)
	automation.observe(start.Add(5*time.Second), 40, false, true, false)
	if action := automation.observe(
		start.Add(5*time.Second+lidStableDelay),
		40,
		false,
		true,
		false,
	); action != lidActionProtect {
		t.Fatalf("expected protection after reopen, got %v", action)
	}
}

func TestLidAutomationSuppressesLockedSessionUntilFullyReopened(t *testing.T) {
	automation := newLidAutomation(true, 45)
	start := time.Unix(500, 0)

	automation.observe(start, 30, false, true, false)
	automation.suppressUntilReopened()

	if action := automation.observe(
		start.Add(3*time.Second),
		30,
		false,
		true,
		false,
	); action != lidActionNone {
		t.Fatalf("locked close candidate triggered protection: %v", action)
	}
	if action := automation.observe(
		start.Add(4*time.Second),
		49,
		false,
		true,
		false,
	); action != lidActionNone {
		t.Fatalf("partial reopen re-armed protection: %v", action)
	}
	if action := automation.observe(
		start.Add(5*time.Second),
		50,
		false,
		true,
		false,
	); action != lidActionNone {
		t.Fatalf("full reopen should only re-arm: %v", action)
	}

	automation.observe(start.Add(6*time.Second), 40, false, true, false)
	if action := automation.observe(
		start.Add(6*time.Second+lidStableDelay),
		40,
		false,
		true,
		false,
	); action != lidActionProtect {
		t.Fatalf("expected protection after a new close cycle, got %v", action)
	}
}
