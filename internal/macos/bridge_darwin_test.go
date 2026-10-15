//go:build darwin

package macos

import (
	"bufio"
	"context"
	"fmt"
	"math"
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestKeepAwakePersistenceRoundTrip(t *testing.T) {
	original := KeepAwakePersisted()
	t.Cleanup(func() {
		SetKeepAwakePersisted(original)
	})

	SetKeepAwakePersisted(!original)
	if got := KeepAwakePersisted(); got == original {
		t.Fatalf("persisted keep-awake = %v, want %v", got, !original)
	}
}

// This touches real recovery records and therefore belongs to manual smoke tests.
func TestRestorePersistedPowerSettingsWithoutState(t *testing.T) {
	if os.Getenv("ACU_SMOKE") != "1" {
		t.Skip("set ACU_SMOKE=1 to access persisted display recovery state")
	}
	if !RestorePersistedPowerSettings() {
		t.Fatal("restore with no persisted dimmed state should succeed")
	}
}

// TestSaveRestorePowerSettingsSmoke dims every display for 2 seconds and
// restores it. Manual only: set ACU_SMOKE=1.
func TestSaveRestorePowerSettingsSmoke(t *testing.T) {
	if os.Getenv("ACU_SMOKE") != "1" {
		t.Skip("set ACU_SMOKE=1 to dim and restore displays")
	}
	if !SavePowerSettings() {
		t.Fatal("save power settings failed")
	}
	time.Sleep(2 * time.Second)
	if !RestorePowerSettings() {
		t.Fatal("restore power settings failed")
	}
	if !RestorePersistedPowerSettings() {
		t.Fatal("persisted state should be empty after restore")
	}
}

// TestSaveRestoreExternalPowerSettingsSmoke dims only external displays for
// 2 seconds and restores them; the built-in display stays lit. Manual only:
// set ACU_SMOKE=1.
func TestSaveRestoreExternalPowerSettingsSmoke(t *testing.T) {
	if os.Getenv("ACU_SMOKE") != "1" {
		t.Skip("set ACU_SMOKE=1 to dim and restore external displays")
	}
	if !SaveExternalPowerSettings() {
		t.Fatal("save external power settings failed")
	}
	time.Sleep(2 * time.Second)
	if !RestorePowerSettings() {
		t.Fatal("restore power settings failed")
	}
	if !RestorePersistedPowerSettings() {
		t.Fatal("persisted state should be empty after restore")
	}
}

// TestDDCDimRestoreDemo sets an external display to a visible brightness,
// dims hardware to 0 and gamma to 20% for 2 seconds, then restores. Manual only: set ACU_SMOKE=1.
func TestDDCDimRestoreDemo(t *testing.T) {
	if os.Getenv("ACU_SMOKE") != "1" {
		t.Skip("set ACU_SMOKE=1 to run the DDC dim/restore demo")
	}
	var external []uint32
	for _, id := range OnlineDisplayIDs() {
		if !DisplayIsBuiltin(id) {
			external = append(external, id)
		}
	}
	if len(external) == 0 {
		t.Skip("no external display connected")
	}
	for _, id := range external {
		original, maximum, ok := DDCProbe(id)
		if !ok {
			t.Errorf("display 0x%x: DDC read unavailable", id)
			continue
		}
		t.Cleanup(func() {
			RestorePowerSettings()
			if !DDCSetBrightness(id, original) {
				t.Errorf("display 0x%x: restore original brightness %d failed", id, original)
			}
		})
		target := maximum / 2
		if !DDCSetBrightness(id, target) {
			t.Fatalf("display 0x%x: set brightness %d failed", id, target)
		}
		time.Sleep(1 * time.Second)
		cur, _, ok := DDCProbe(id)
		t.Logf("display 0x%x: set %d, probe %d", id, target, cur)
		if !ok || cur != target {
			t.Fatalf("display 0x%x: brightness write not honored: want %d, got %d (ok=%v)", id, target, cur, ok)
		}
		gammaBefore, gammaOK := GammaWhiteLevel(id)
		if !gammaOK {
			t.Fatal("cannot read original gamma")
		}
		t.Cleanup(func() { RestorePowerSettings() })
		if !SaveExternalPowerSettings() {
			t.Fatalf("display 0x%x: save external power settings failed", id)
		}
		cur, _, ok = DDCProbe(id)
		if !ok || cur != uint16(0) {
			t.Fatalf("display 0x%x: hardware dim failed: got %d (ok=%v)", id, cur, ok)
		}
		gammaDimmed, ok := GammaWhiteLevel(id)
		if !ok || math.Abs(float64(gammaDimmed-gammaBefore*0.20)) > 0.01 {
			t.Fatalf("gamma dim: before=%f after=%f ok=%v", gammaBefore, gammaDimmed, ok)
		}
		t.Logf("display 0x%x: gamma white level %f -> %f", id, gammaBefore, gammaDimmed)
		time.Sleep(2 * time.Second)
		if !RestorePowerSettings() {
			t.Fatalf("display 0x%x: restore power settings failed", id)
		}
		gammaRestored, gammaOK := GammaWhiteLevel(id)
		if !gammaOK || math.Abs(float64(gammaRestored-gammaBefore)) > 0.01 {
			t.Fatalf("gamma restore: before=%f after=%f", gammaBefore, gammaRestored)
		}
		cur, _, ok = DDCProbe(id)
		t.Logf("display 0x%x: after restore %d", id, cur)
		if !ok || cur != target {
			t.Errorf("display 0x%x: restore mismatch: want %d, got %d (ok=%v)", id, target, cur, ok)
		}
	}
}

func TestDDCChecksum(t *testing.T) {
	cases := []struct {
		name string
		base uint8
		data []byte
		want uint8
	}{
		{"empty", 0x6e, nil, 0x6e},
		// Read command packet [0x82, len=1, 0x83] with base 0x6e.
		{"read packet", 0x6e, []byte{0x82, 0x01, 0x83}, 0x6e},
		// Write command packet [0x84, len=3, 0x83, msb, lsb] with base
		// 0x6e ^ 0x51 = 0x3f.
		{"write packet", 0x3f, []byte{0x84, 0x03, 0x83, 0x00, 0x00}, 0x3b},
		// Real reply captured on Apple Silicon: checksum 0x37.
		{"reply", 0x50, []byte{
			0x6e, 0x88, 0x02, 0x01, 0x83, 0x01, 0xff, 0xff, 0x00, 0x00,
		}, 0x37},
	}
	for _, c := range cases {
		if got := DDCChecksum(c.base, c.data); got != c.want {
			t.Errorf("%s: checksum = 0x%02x, want 0x%02x", c.name, got, c.want)
		}
	}
}

// TestDDCProbeExternal reads brightness over DDC without changing it.
// Manual only: set ACU_SMOKE=1 with an external display connected.
func TestDDCProbeExternal(t *testing.T) {
	if os.Getenv("ACU_SMOKE") != "1" {
		t.Skip("set ACU_SMOKE=1 to probe external displays over DDC")
	}
	var external []uint32
	for _, id := range OnlineDisplayIDs() {
		if !DisplayIsBuiltin(id) {
			external = append(external, id)
		}
	}
	if len(external) == 0 {
		t.Skip("no external display connected")
	}
	probed := 0
	for _, id := range external {
		current, maximum, ok := DDCProbe(id)
		if !ok {
			t.Logf("display 0x%x: DDC read unavailable", id)
			continue
		}
		probed++
		t.Logf("display 0x%x: current=%d max=%d", id, current, maximum)
		if maximum == 0 {
			t.Errorf("display 0x%x: max = 0", id)
		}
		if current > maximum {
			t.Errorf("display 0x%x: current %d > max %d", id, current, maximum)
		}
	}
	if probed == 0 {
		t.Log("no external display answered DDC read")
	}
}

// The helper exits without restoring its in-memory table. A second process
// must recover the original hardware brightness using the persisted snapshot.
func TestDDCProcessRecoverySmoke(t *testing.T) {
	if os.Getenv("ACU_SMOKE") != "1" {
		t.Skip("set ACU_SMOKE=1")
	}
	switch os.Getenv("ACU_DDC_RECOVERY_HELPER") {
	case "dim":
		if !SaveExternalPowerSettings() {
			os.Exit(2)
		}
		fmt.Println("dimmed")
		time.Sleep(30 * time.Second)
		os.Exit(4) // Parent must kill this process before its restore path.
	case "restore":
		if !RestorePersistedPowerSettings() {
			os.Exit(3)
		}
		os.Exit(0)
	}
	var id uint32
	var original uint16
	for _, display := range OnlineDisplayIDs() {
		if DisplayIsBuiltin(display) {
			continue
		}
		if cur, _, ok := DDCProbe(display); ok {
			id, original = display, cur
			break
		}
	}
	if id == 0 {
		t.Skip("no DDC external display")
	}
	if original <= uint16(0) {
		t.Skip("brightness already at or below dim target; cannot verify recovery")
	}
	t.Cleanup(func() {
		RestorePersistedPowerSettings()
		if !DDCSetBrightness(id, original) {
			t.Error("cleanup brightness restore failed")
		}
	})
	run := func(mode string) {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestDDCProcessRecoverySmoke$")
		cmd.Env = append(os.Environ(), "ACU_DDC_RECOVERY_HELPER="+mode)
		if mode == "dim" {
			stdout, err := cmd.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			scanner := bufio.NewScanner(stdout)
			ready := scanner.Scan() && scanner.Text() == "dimmed"
			killErr := cmd.Process.Kill()
			_ = cmd.Wait()
			if !ready || killErr != nil {
				t.Fatalf("dim helper readiness=%v kill=%v", ready, killErr)
			}
			return
		}
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s helper: %v: %s", mode, err, out)
		}
	}
	gammaBefore, gammaOK := GammaWhiteLevel(id)
	if !gammaOK {
		t.Fatal("cannot read original gamma")
	}
	run("dim")
	// WindowServer can automatically reset a dead client's gamma tables.
	// Either the dimmed curve or the original is valid before recovery.
	gammaAfterExit, gammaOK := GammaWhiteLevel(id)
	if !gammaOK || (math.Abs(float64(gammaAfterExit-gammaBefore*0.20)) > 0.01 &&
		math.Abs(float64(gammaAfterExit-gammaBefore)) > 0.01) {
		t.Fatalf("unexpected gamma after process exit: %f", gammaAfterExit)
	}
	t.Logf("gamma after process exit: %f", gammaAfterExit)
	if cur, _, ok := DDCProbe(id); !ok || cur != uint16(0) {
		t.Fatalf("after process exit: brightness=%d ok=%v", cur, ok)
	}
	run("restore")
	if gamma, ok := GammaWhiteLevel(id); !ok || math.Abs(float64(gamma-gammaBefore)) > 0.01 {
		t.Fatalf("gamma after process recovery: %f want %f", gamma, gammaBefore)
	}
	if cur, _, ok := DDCProbe(id); !ok || cur != original {
		t.Fatalf("recovery: brightness=%d want=%d ok=%v", cur, original, ok)
	}
	t.Logf("display 0x%x: persisted recovery %d -> %d -> %d", id, original, uint16(0), original)
}

// Manual hardware regression: do not move the physical mouse during this test.
func TestNudgeDoesNotSignalPhysicalActivitySmoke(t *testing.T) {
	if os.Getenv("ACU_SMOKE") != "1" {
		t.Skip("set ACU_SMOKE=1")
	}
	const marker uint64 = 0x4143554e55444745
	if err := StartInputGuard(marker); err != nil {
		t.Fatal(err)
	}
	defer StopInputGuard()
	for {
		select {
		case <-PhysicalActivityEvents():
			continue
		default:
		}
		break
	}
	if err := NudgeCursor(1, 10*time.Millisecond, marker); err != nil {
		t.Fatal(err)
	}
	select {
	case <-PhysicalActivityEvents():
		t.Fatal("physical activity observed during marked nudge; rerun without touching input devices")
	case <-time.After(150 * time.Millisecond):
	}
}
