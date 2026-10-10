package app

import "time"

const (
	bluetoothPresencePollInterval  = 3 * time.Second
	bluetoothPresenceLostGrace     = 3 * time.Second
	bluetoothPresenceReturnStable  = 5 * time.Second
	bluetoothPresenceRetryInterval = 20 * time.Second
)

type bluetoothPresenceAction int

const (
	bluetoothPresenceNoAction bluetoothPresenceAction = iota
	bluetoothPresenceProtect
	bluetoothPresenceConnect
)

type bluetoothPresenceAutomation struct {
	enabled              bool
	armed                bool
	waitingForConnection bool
	lostSince            time.Time
	connectedSince       time.Time
	lastConnectTry       time.Time
}

func newBluetoothPresenceAutomation(enabled bool) *bluetoothPresenceAutomation {
	return &bluetoothPresenceAutomation{
		enabled:              enabled,
		waitingForConnection: enabled,
	}
}

func (a *bluetoothPresenceAutomation) configure(enabled bool) {
	*a = bluetoothPresenceAutomation{
		enabled:              enabled,
		waitingForConnection: enabled,
	}
}

// observe treats unknown hardware/device state as inconclusive. The controller
// only passes known connected/disconnected states to this method.
func (a *bluetoothPresenceAutomation) observe(
	now time.Time,
	connected bool,
	protectionActive bool,
) bluetoothPresenceAction {
	if !a.enabled {
		return bluetoothPresenceNoAction
	}

	if !connected {
		a.connectedSince = time.Time{}
		if a.armed {
			if a.lostSince.IsZero() {
				a.lostSince = now
				return bluetoothPresenceNoAction
			}
			if now.Sub(a.lostSince) >= bluetoothPresenceLostGrace {
				a.armed = false
				a.waitingForConnection = true
				a.lostSince = time.Time{}
				return bluetoothPresenceProtect
			}
		}
		if a.waitingForConnection && !protectionActive &&
			(a.lastConnectTry.IsZero() ||
				now.Sub(a.lastConnectTry) >= bluetoothPresenceRetryInterval) {
			a.lastConnectTry = now
			return bluetoothPresenceConnect
		}
		return bluetoothPresenceNoAction
	}

	a.lostSince = time.Time{}
	if a.armed {
		return bluetoothPresenceNoAction
	}
	if protectionActive && a.waitingForConnection {
		a.connectedSince = time.Time{}
		return bluetoothPresenceNoAction
	}
	if a.connectedSince.IsZero() {
		a.connectedSince = now
		return bluetoothPresenceNoAction
	}
	if now.Sub(a.connectedSince) < bluetoothPresenceReturnStable {
		return bluetoothPresenceNoAction
	}
	a.armed = true
	a.waitingForConnection = false
	a.lastConnectTry = time.Time{}
	return bluetoothPresenceNoAction
}

func (a *bluetoothPresenceAutomation) observeUnknown() {
	a.lostSince = time.Time{}
	a.connectedSince = time.Time{}
}

func (a *bluetoothPresenceAutomation) status(
	connected, available, protectionActive bool,
) string {
	if !a.enabled {
		return "disabled"
	}
	if !available {
		return "unavailable"
	}
	if a.waitingForConnection && protectionActive {
		return "waiting_for_return"
	}
	if a.waitingForConnection {
		return "waiting_for_connection"
	}
	if a.armed && connected {
		return "armed"
	}
	return "waiting_for_connection"
}
