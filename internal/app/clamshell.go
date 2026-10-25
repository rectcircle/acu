package app

import (
	"errors"
	"fmt"
	"github.com/rectcircle/acu/internal/clamshell"
	"github.com/rectcircle/acu/internal/ipc"
	"github.com/rectcircle/acu/internal/macos"
)

func (c *Controller) clamshellError(err error) {
	macos.ShowAlert(text("clamshell.error"), err.Error(), false)
}
func (c *Controller) stopClamshell() bool {
	if !c.clamshellActive && !c.clamshellRecoveryPending {
		return true
	}
	if err := clamshell.Set(false); err != nil {
		c.clamshellError(err)
		return false
	}
	c.clamshellActive = false
	c.clamshellStarting = false
	c.clamshellRecoveryPending = false
	if c.clamshellOwnedAwake {
		c.keepAwakeRequested = false
	}
	macos.SetClamshellActive(false)
	return true
}
func (c *Controller) toggleClamshell() {
	if c.clamshellActive || c.clamshellRecoveryPending {
		if !c.stopClamshell() {
			return
		}
		macos.SetClamshellPersisted(false)
		if c.clamshellOwnedAwake {
			c.keepAwakeRequested = false
			if c.child != nil && c.child.mode == guardianModeKeepAwake {
				if err := c.child.conn.Write(ipc.Message{Type: "stop"}); err != nil {
					c.clamshellError(err)
				}
			}
		}
		c.clamshellOwnedAwake = false
		return
	}
	c.startClamshell(true)
}

var errClamshellCancelled = errors.New("clamshell enable cancelled")
var errClamshellAuthorizationMissing = errors.New("clamshell authorization missing")

// Automatic restoration never installs authorization or presents consent UI.
func prepareClamshell(manual bool, authorized func() bool, setup func() error, consent func() bool) error {
	if !authorized() {
		if !manual {
			return errClamshellAuthorizationMissing
		}
		if err := setup(); err != nil {
			return err
		}
	}
	if manual && !consent() {
		return errClamshellCancelled
	}
	return nil
}

func (c *Controller) startClamshell(manual bool) {
	err := prepareClamshell(manual, clamshell.Authorized, func() error {
		if !macos.ShowConfirmation(text("clamshell.setup.title"), text("clamshell.setup.message"), text("clamshell.setup.confirm")) {
			return errClamshellCancelled
		}
		return clamshell.Install()
	}, func() bool {
		return macos.ShowConfirmation(text("clamshell.title"), text("clamshell.enable.message"), text("clamshell.enable.confirm"))
	})
	if err != nil {
		if errors.Is(err, errClamshellAuthorizationMissing) {
			err = fmt.Errorf("%s", text("clamshell.reauthorize"))
		}
		if !errors.Is(err, errClamshellCancelled) {
			c.clamshellError(err)
		}
		return
	}
	if failures := macos.PreflightKeepAwake(manual); failures != 0 {
		macos.ShowPreflightAlert(text("clamshell.error"), preflightMessage(failures), failures)
		return
	}
	if err := clamshell.Set(true); err != nil {
		// A failed write may still have changed the global setting. Keep recovery visible.
		if clamshell.Pending() {
			c.clamshellRecoveryPending = true
		}
		c.clamshellError(err)
		return
	}
	c.clamshellRecoveryPending = true
	if c.child == nil {
		child, err := startGuardian(c.childEvents, guardianModeKeepAwake, 0)
		if err != nil {
			c.stopClamshell()
			c.clamshellError(err)
			return
		}
		c.child = child
		c.clamshellStarting = true
	}
	c.clamshellActive = true
	c.clamshellRecoveryPending = false
	if !c.clamshellStarting {
		macos.SetClamshellActive(true)
		macos.SetClamshellPersisted(true)
	}
	c.clamshellOwnedAwake = !c.keepAwakeRequested
	c.keepAwakeRequested = true
}
func (c *Controller) removeClamshell() {
	if !macos.ShowAlert(text("menu.clamshell.remove"), text("clamshell.remove_confirm"), true) {
		return
	}
	if c.clamshellActive || c.clamshellRecoveryPending {
		c.toggleClamshell()
		if c.clamshellActive || c.clamshellRecoveryPending {
			return
		}
	}
	if !clamshell.Authorized() {
		c.clamshellError(fmt.Errorf("%s", text("clamshell.reauthorize")))
		return
	}
	if err := clamshell.Remove(); err != nil {
		c.clamshellError(err)
		return
	}
	macos.SetClamshellPersisted(false)
}
