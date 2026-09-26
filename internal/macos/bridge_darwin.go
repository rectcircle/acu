//go:build darwin

package macos

/*
#cgo CFLAGS: -x objective-c -fblocks -fobjc-arc
#cgo LDFLAGS: -framework AppKit -framework ApplicationServices -framework Carbon -framework CoreGraphics -framework CoreFoundation -framework IOKit -framework LocalAuthentication -framework Security
#include <stdlib.h>
#include "bridge.h"
*/
import "C"

import (
	"errors"
	"time"
	"unsafe"
)

type MenuAction int

const (
	MenuEnable      MenuAction = C.ACU_MENU_ENABLE
	MenuTest        MenuAction = C.ACU_MENU_TEST
	MenuUnlock      MenuAction = C.ACU_MENU_UNLOCK
	MenuDiagnostics MenuAction = C.ACU_MENU_DIAGNOSTICS
	MenuQuit        MenuAction = C.ACU_MENU_QUIT
	MenuKeepAwake   MenuAction = C.ACU_MENU_KEEP_AWAKE
	MenuLidConfig   MenuAction = C.ACU_MENU_LID_CONFIGURATION
)

type PreflightFailures uint32

const (
	FailureAccessibility PreflightFailures = C.ACU_PREFLIGHT_ACCESSIBILITY
	FailureListenEvents  PreflightFailures = C.ACU_PREFLIGHT_LISTEN_EVENTS
	FailurePostEvents    PreflightFailures = C.ACU_PREFLIGHT_POST_EVENTS
	FailureAuth          PreflightFailures = C.ACU_PREFLIGHT_AUTH
	FailureDisplay       PreflightFailures = C.ACU_PREFLIGHT_DISPLAY
	FailureSessionLocked PreflightFailures = C.ACU_PREFLIGHT_SESSION_LOCKED
)

var (
	menuEvents       = make(chan MenuAction, 8)
	guardianEnter    = make(chan struct{}, 1)
	tapDegraded      = make(chan struct{}, 1)
	physicalActivity = make(chan struct{}, 1)
	lidAngleChanged  = make(chan struct{}, 1)
)

//export acuMenuAction
func acuMenuAction(action C.int) {
	select {
	case menuEvents <- MenuAction(action):
	default:
	}
}

//export acuGuardianEnter
func acuGuardianEnter() {
	select {
	case guardianEnter <- struct{}{}:
	default:
	}
}

//export acuTapDegraded
func acuTapDegraded() {
	select {
	case tapDegraded <- struct{}{}:
	default:
	}
}

//export acuPhysicalActivity
func acuPhysicalActivity() {
	select {
	case physicalActivity <- struct{}{}:
	default:
	}
}

//export acuLidAngleChanged
func acuLidAngleChanged() {
	select {
	case lidAngleChanged <- struct{}{}:
	default:
	}
}

func InitMenu() error {
	if C.acu_init_menu() == 0 {
		return errors.New("menu initialization failed")
	}
	return nil
}

func MenuEvents() <-chan MenuAction {
	return menuEvents
}

func GuardianEnterEvents() <-chan struct{} {
	return guardianEnter
}

func TapDegradedEvents() <-chan struct{} {
	return tapDegraded
}

func PhysicalActivityEvents() <-chan struct{} {
	return physicalActivity
}

func LidAngleChangedEvents() <-chan struct{} {
	return lidAngleChanged
}

func RunApp() {
	C.acu_run_app()
}

func StopApp() {
	C.acu_stop_app()
}

func SetMenuState(state string) {
	value := C.CString(state)
	defer C.free(unsafe.Pointer(value))
	C.acu_set_menu_state(value)
}

func SetKeepAwakeActive(active bool) {
	var value C.int
	if active {
		value = 1
	}
	C.acu_set_keep_awake_active(value)
}

func ShowAlert(title, message string, confirm bool) bool {
	cTitle := C.CString(title)
	cMessage := C.CString(message)
	defer C.free(unsafe.Pointer(cTitle))
	defer C.free(unsafe.Pointer(cMessage))

	var needsConfirm C.int
	if confirm {
		needsConfirm = 1
	}
	return C.acu_show_alert(cTitle, cMessage, needsConfirm) != 0
}

func ShowPreflightAlert(
	title, message string,
	failures PreflightFailures,
) {
	cTitle := C.CString(title)
	cMessage := C.CString(message)
	defer C.free(unsafe.Pointer(cTitle))
	defer C.free(unsafe.Pointer(cMessage))

	C.acu_show_preflight_alert(
		cTitle,
		cMessage,
		C.uint32_t(failures),
	)
}

func Preflight(requestPermissions bool) PreflightFailures {
	var request C.int
	if requestPermissions {
		request = 1
	}
	return PreflightFailures(C.acu_preflight(request))
}

func PreflightKeepAwake(requestPermissions bool) PreflightFailures {
	var request C.int
	if requestPermissions {
		request = 1
	}
	return PreflightFailures(C.acu_preflight_keep_awake(request))
}

func ManagedPolicyDetected() bool {
	return C.acu_managed_policy_status() != 0
}

func SessionLocked() bool {
	return C.acu_session_locked() != 0
}

type LidAutomationConfig struct {
	Enabled        bool
	ThresholdAngle float64
}

func CurrentLidAutomationConfig() LidAutomationConfig {
	return LidAutomationConfig{
		Enabled:        C.acu_lid_automation_enabled() != 0,
		ThresholdAngle: float64(C.acu_lid_angle_threshold()),
	}
}

func ReadLidAngle() (float64, bool) {
	var angle C.double
	if C.acu_read_lid_angle(&angle) == 0 {
		return 0, false
	}
	return float64(angle), true
}

func HasExternalDisplay() bool {
	return C.acu_has_external_display() != 0
}

func StartInputGuard(marker uint64) error {
	if C.acu_start_input_guard(C.uint64_t(marker)) == 0 {
		return errors.New("event tap unavailable")
	}
	return nil
}

func StopInputGuard() {
	C.acu_stop_input_guard()
}

func SetInputAuthenticationMode(enabled bool) {
	var value C.int
	if enabled {
		value = 1
	}
	C.acu_set_input_authentication_mode(value)
}

func ShowShields() error {
	if C.acu_show_shields() == 0 {
		return errors.New("no displays available")
	}
	return nil
}

func HideShields() {
	C.acu_hide_shields()
}

func SetShieldAuthenticationMode(enabled bool) {
	var value C.int
	if enabled {
		value = 1
	}
	C.acu_set_shield_authentication_mode(value)
}

func SetShieldCountdown(seconds int) {
	C.acu_set_shield_countdown(C.int(seconds))
}

func ShowInputGuardFailure() {
	C.acu_show_input_guard_failure()
}

func IdleDuration() time.Duration {
	seconds := float64(C.acu_idle_seconds())
	return time.Duration(seconds * float64(time.Second))
}

func NudgeCursor(distance float64, restoreDelay time.Duration, marker uint64) error {
	delayMS := restoreDelay.Milliseconds()
	if C.acu_nudge_cursor(
		C.double(distance),
		C.int(delayMS),
		C.uint64_t(marker),
	) == 0 {
		return errors.New("cursor nudge failed")
	}
	return nil
}

func Authenticate() (bool, error) {
	result := C.acu_authenticate()
	if result < 0 {
		return false, errors.New("device owner authentication unavailable")
	}
	return result > 0, nil
}

func SavePowerSettings() bool {
	return C.acu_save_power_settings() != 0
}

func RestorePowerSettings() bool {
	return C.acu_restore_power_settings() != 0
}

// KeepAwakePersisted 返回防锁屏是否被用户持久化开启（跨进程重启保存）。
func KeepAwakePersisted() bool {
	return C.acu_keep_awake_persisted() != 0
}
