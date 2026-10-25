// Package clamshell manages a narrowly scoped, explicitly installed sudo rule.
package clamshell

import (
	"context"
	_ "embed"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

//go:embed power.sh
var wrapper string

const helper = "/Library/PrivilegedHelperTools/acu-clamshell-v1"

func run(name string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}
func Set(on bool) error {
	action := "off"
	if on {
		action = "on"
	}
	return run("/usr/bin/sudo", "-n", "-k", "--", helper, action)
}
func rulePath() string {
	return "/etc/sudoers.d/acu-clamshell-" + strconv.Itoa(os.Getuid())
}

func authorizedWith(ruleExists bool, installed []byte, command func(string, ...string) error) bool {
	// sudo -l can succeed for an administrator even after our rule is removed.
	// Require our actual installation, independently of sudo's authentication cache.
	if !ruleExists || string(installed) != wrapper {
		return false
	}
	return command("/usr/bin/sudo", "-n", "-k", "-l", "--", helper, "on") == nil &&
		command("/usr/bin/sudo", "-n", "-k", "-l", "--", helper, "off") == nil
}
func Authorized() bool {
	info, err := os.Lstat(rulePath())
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 {
		return false
	}
	installed, err := os.ReadFile(helper)
	return err == nil && authorizedWith(true, installed, run)
}

func Pending() bool {
	data, err := os.ReadFile("/var/db/acu-clamshell/session")
	fields := strings.Fields(string(data))
	return err == nil && len(fields) == 2 && fields[0] == strconv.Itoa(os.Getuid())
}
func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }

// pamTouchIDEnabled only reads the existing sudo PAM stack; ACU never changes it.
func pamTouchIDEnabled(main, local string) bool {
	hasTouchID := func(config string) bool {
		for _, line := range strings.Split(config, "\n") {
			fields := strings.Fields(strings.SplitN(line, "#", 2)[0])
			if len(fields) >= 3 && fields[0] == "auth" &&
				(fields[1] == "sufficient" || fields[1] == "required") &&
				(fields[2] == "pam_tid.so" || fields[2] == "/usr/lib/pam/pam_tid.so") {
				return true
			}
		}
		return false
	}
	if hasTouchID(main) {
		return true
	}
	for _, line := range strings.Split(main, "\n") {
		fields := strings.Fields(strings.SplitN(line, "#", 2)[0])
		if len(fields) == 3 && fields[0] == "auth" && fields[1] == "include" && fields[2] == "sudo_local" {
			return hasTouchID(local)
		}
	}
	return false
}
func authorizeWith(script string, touchID bool, command func(string, ...string) error) error {
	if touchID {
		// An empty stdin permits PAM's biometric UI but supplies no password.
		// Reset this session first, then validate without -k so the authenticated
		// credential is available to the immediately following installer command.
		// Combining -k with -v explicitly suppresses writing the timestamp.
		// Never execute the installer twice on a command failure.
		if err := command("/usr/bin/sudo", "-k"); err == nil {
			if err := command("/usr/bin/sudo", "-S", "-p", "", "-v"); err == nil {
				return command("/usr/bin/sudo", "-n", "--", "/bin/sh", "-c", script)
			}
		}
	}
	source := "do shell script " + strconv.Quote(script) + " with administrator privileges"
	return command("/usr/bin/osascript", "-e", source)
}
func authorize(script string) error {
	main, _ := os.ReadFile("/etc/pam.d/sudo")
	local, _ := os.ReadFile("/etc/pam.d/sudo_local")
	command := func(name string, args ...string) error {
		// Authentication may wait for the user. A nil stdin is /dev/null; no password
		// is read, stored, or passed by ACU. Only system-owned authentication UI asks.
		out, err := exec.Command(name, args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("administrator authorization: %w: %s", err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	return authorizeWith(script, pamTouchIDEnabled(string(main), string(local)), command)
}

func Install() error {
	u, err := user.Current()
	if err != nil {
		return err
	}
	if !regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_.-]*$`).MatchString(u.Username) {
		return fmt.Errorf("unsupported account name")
	}
	rule := fmt.Sprintf("%s ALL=(root) NOPASSWD: %s on, %s off\n", u.Username, helper, helper)
	rulePath := rulePath()
	script := `set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
/usr/sbin/visudo -c >/dev/null
work=$(/usr/bin/mktemp -d /private/tmp/acu-auth.XXXXXX)
trap '/bin/rm -rf "$work"' EXIT
`
	script += "printf %s " + quote(base64.StdEncoding.EncodeToString([]byte(wrapper))) + " | /usr/bin/base64 -D > \"$work/helper\"\n"
	script += "printf %s " + quote(rule) + " > \"$work/rule\"\n/usr/sbin/visudo -cf \"$work/rule\"\n"
	// Never silently replace another installation or follow a symlink.
	script += "if [ -e " + helper + " ] || [ -L " + helper + " ]; then\n[ ! -L " + helper + " ] && /usr/bin/cmp -s \"$work/helper\" " + helper + " || exit 1\nfi\n"
	script += "[ ! -L " + rulePath + " ]\n"
	script += "if [ -e " + rulePath + " ]; then /bin/cp -p " + rulePath + " \"$work/old-rule\"; fi\n"
	script += `/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /var/db/acu-clamshell /etc/sudoers.d
`
	script += "/usr/bin/install -o root -g wheel -m 755 \"$work/helper\" " + helper + "\n"
	script += "/usr/bin/install -o root -g wheel -m 440 \"$work/rule\" " + rulePath + "\n"
	script += "if ! /usr/sbin/visudo -c; then if [ -f \"$work/old-rule\" ]; then /bin/cp -p \"$work/old-rule\" " + rulePath + "; else /bin/rm -f " + rulePath + "; fi; exit 1; fi\n"
	if err := authorize(script); err != nil {
		return err
	}
	if !Authorized() {
		return fmt.Errorf("installed permission could not be verified")
	}
	return nil
}
func Remove() error {
	if err := Set(false); err != nil {
		return err
	}
	// Keep the inert shared helper for other users; remove this account's rule only.
	return authorize("set -eu\n/bin/rm -f " + rulePath() + "\n/usr/sbin/visudo -c")
}
