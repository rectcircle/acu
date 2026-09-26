package app

import (
	"strings"
	"testing"

	"github.com/rectcircle/acu/internal/macos"
)

func TestPreflightSummaryPrioritizesAccessibility(t *testing.T) {
	failures := macos.FailureAccessibility |
		macos.FailureListenEvents |
		macos.FailurePostEvents

	summary := preflightSummary(failures)

	if summary != macos.Localized("preflight.accessibility") {
		t.Fatalf("unexpected summary: %q", summary)
	}
}

func TestPreflightSummaryReportsIndependentListenFailure(t *testing.T) {
	summary := preflightSummary(macos.FailureListenEvents)

	if !strings.Contains(
		summary,
		macos.Localized("preflight.listen_events"),
	) {
		t.Fatalf("unexpected summary: %q", summary)
	}
}

func TestShouldRestoreKeepAwakeAfterProtection(t *testing.T) {
	controller := &Controller{keepAwakeRequested: true}

	if !controller.shouldRestoreKeepAwake() {
		t.Fatal("keep-awake should resume after protection")
	}
}

func TestShouldNotRestoreKeepAwakeWithoutUserRequest(t *testing.T) {
	controller := &Controller{}

	if controller.shouldRestoreKeepAwake() {
		t.Fatal("keep-awake resumed without a user request")
	}
}

func TestShouldNotRestoreKeepAwakeWhileQuitting(t *testing.T) {
	controller := &Controller{
		keepAwakeRequested: true,
		quitWhenDisabled:   true,
	}

	if controller.shouldRestoreKeepAwake() {
		t.Fatal("keep-awake resumed while quitting")
	}
}

func TestShouldNotRestoreKeepAwakeDuringTransition(t *testing.T) {
	controller := &Controller{
		keepAwakeRequested: true,
		pendingProtection:  true,
	}

	if controller.shouldRestoreKeepAwake() {
		t.Fatal("keep-awake resumed before protection started")
	}
}
