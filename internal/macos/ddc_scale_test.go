//go:build darwin

package macos

import (
	"os"
	"testing"
	"time"
)

func TestDDCWriteScale(t *testing.T) {
	if os.Getenv("ACU_SMOKE") != "1" {
		t.Skip("set ACU_SMOKE=1")
	}
	var external []uint32
	for _, id := range OnlineDisplayIDs() {
		if !DisplayIsBuiltin(id) {
			external = append(external, id)
		}
	}
	for _, id := range external {
		for _, v := range []uint16{100, 50, 10, 1} {
			if !DDCSetBrightness(id, v) {
				t.Fatalf("set %d failed", v)
			}
			time.Sleep(300 * time.Millisecond)
			cur, max, ok := DDCProbe(id)
			t.Logf("display 0x%x: wrote %d -> probe cur=%d max=%d ok=%v", id, v, cur, max, ok)
		}
	}
}

func TestDMBrightness(t *testing.T) {
	if os.Getenv("ACU_SMOKE") != "1" {
		t.Skip("set ACU_SMOKE=1")
	}
	for _, id := range OnlineDisplayIDs() {
		supports := DMSupportsBrightness(id)
		cur, ok := DMGetBrightness(id)
		t.Logf("display 0x%x builtin=%v dm_support=%v dm_get=%.3f ok=%v",
			id, DisplayIsBuiltin(id), supports, cur, ok)
		if !supports {
			continue
		}
		if !DMSetBrightness(id, 0.5) {
			t.Fatalf("display 0x%x: DM set 0.5 failed", id)
		}
		time.Sleep(500 * time.Millisecond)
		cur, ok = DMGetBrightness(id)
		t.Logf("display 0x%x: after DM set 0.5 -> %.3f ok=%v", id, cur, ok)
	}
}
