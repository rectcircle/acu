package app

import (
	"math"
	"time"
)

const (
	lidPollInterval       = 250 * time.Millisecond
	lidStableDelay        = 2 * time.Second
	lidOpenHysteresis     = 5.0
	lidFullyClosedMaximum = 2.0
	lidMovementThreshold  = 0.5
)

type lidAction int

const (
	lidActionNone lidAction = iota
	lidActionProtect
	lidActionAuthenticate
)

type lidAutomation struct {
	enabled           bool
	threshold         float64
	belowSince        time.Time
	armed             bool
	suppressUntilOpen bool
	protectionOwned   bool
	authRequested     bool
	lastAngle         float64
	angleKnown        bool
}

func newLidAutomation(enabled bool, threshold float64) *lidAutomation {
	automation := &lidAutomation{}
	automation.configure(enabled, threshold)
	return automation
}

func (a *lidAutomation) configure(enabled bool, threshold float64) {
	a.enabled = enabled
	a.threshold = threshold
	a.belowSince = time.Time{}
	a.armed = enabled
	a.suppressUntilOpen = false
	a.angleKnown = false
	if !enabled {
		a.protectionOwned = false
		a.authRequested = false
	}
}

func (a *lidAutomation) observe(
	now time.Time,
	angle float64,
	hasExternalDisplay bool,
	canProtect bool,
	protectionActive bool,
) lidAction {
	if !a.enabled {
		return lidActionNone
	}
	angleChanged := !a.angleKnown ||
		math.Abs(angle-a.lastAngle) >= lidMovementThreshold
	a.lastAngle = angle
	a.angleKnown = true

	if angle >= a.threshold+lidOpenHysteresis {
		a.belowSince = time.Time{}
		a.armed = true
		a.suppressUntilOpen = false
		if a.protectionOwned && protectionActive && !a.authRequested {
			a.authRequested = true
			return lidActionAuthenticate
		}
		return lidActionNone
	}
	if angle >= a.threshold {
		a.belowSince = time.Time{}
		return lidActionNone
	}

	a.authRequested = false
	if angle <= lidFullyClosedMaximum && hasExternalDisplay {
		a.belowSince = time.Time{}
		a.armed = false
		a.suppressUntilOpen = true
		return lidActionNone
	}
	if a.suppressUntilOpen || !a.armed {
		return lidActionNone
	}
	if angleChanged || a.belowSince.IsZero() {
		a.belowSince = now
		return lidActionNone
	}
	if now.Sub(a.belowSince) < lidStableDelay {
		return lidActionNone
	}

	a.belowSince = time.Time{}
	a.armed = false
	if !canProtect {
		return lidActionNone
	}
	a.protectionOwned = true
	return lidActionProtect
}

func (a *lidAutomation) suppressUntilReopened() {
	a.belowSince = time.Time{}
	a.armed = false
	a.suppressUntilOpen = true
	a.authRequested = false
}

func (a *lidAutomation) protectionFailed() {
	a.protectionOwned = false
	a.authRequested = false
}

func (a *lidAutomation) protectionStopped() {
	a.protectionOwned = false
	a.authRequested = false
}
