package app

import (
	"strings"
	"testing"

	"github.com/rectcircle/acu-helper/internal/macos"
)

func TestPreflightSummaryPrioritizesAccessibility(t *testing.T) {
	failures := macos.FailureAccessibility |
		macos.FailureListenEvents |
		macos.FailurePostEvents

	summary := preflightSummary(failures)

	if summary != "未授予辅助功能权限" {
		t.Fatalf("unexpected summary: %q", summary)
	}
}

func TestPreflightSummaryReportsIndependentListenFailure(t *testing.T) {
	summary := preflightSummary(macos.FailureListenEvents)

	if !strings.Contains(summary, "无法监听输入事件") {
		t.Fatalf("unexpected summary: %q", summary)
	}
}
