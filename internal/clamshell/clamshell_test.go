package clamshell

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Execute a copy with all privileged and power-management dependencies replaced.
// These tests never invoke sudo, real pmset, or write system directories.
func fixture(t *testing.T, original string) (func(string, ...string) error, string) {
	t.Helper()
	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	if err := os.Mkdir(state, 0700); err != nil {
		t.Fatal(err)
	}
	power := filepath.Join(dir, "power")
	os.WriteFile(power, []byte(original), 0600)
	mock := filepath.Join(dir, "pmset")
	body := "#!/bin/sh\nif [ \"$1\" = -g ]; then printf 'SleepDisabled %s\\n' \"$(/bin/cat " + quote(power) + ")\"; else printf %s \"$3\" > " + quote(power) + "; fi\n"
	os.WriteFile(mock, []byte(body), 0700)
	id := filepath.Join(dir, "id")
	os.WriteFile(id, []byte("#!/bin/sh\necho 0\n"), 0700)
	lock := filepath.Join(dir, "shlock")
	os.WriteFile(lock, []byte("#!/bin/sh\nexit 0\n"), 0700)
	script := strings.NewReplacer("/var/db/acu-clamshell", state, "/usr/bin/pmset", mock, "/usr/bin/id", id, "/usr/bin/shlock", lock).Replace(wrapper)
	path := filepath.Join(dir, "wrapper")
	os.WriteFile(path, []byte(script), 0700)
	return func(uid string, args ...string) error {
		cmd := exec.Command("/bin/sh", append([]string{path}, args...)...)
		cmd.Env = []string{"SUDO_UID=" + uid}
		return cmd.Run()
	}, dir
}
func TestWrapperPreservesOriginalAcrossRepeatedEnable(t *testing.T) {
	for _, original := range []string{"0", "1"} {
		t.Run(original, func(t *testing.T) {
			run, dir := fixture(t, original)
			for _, action := range []string{"on", "on", "off", "off"} {
				if err := run("501", action); err != nil {
					t.Fatalf("%s: %v", action, err)
				}
			}
			got, _ := os.ReadFile(filepath.Join(dir, "power"))
			if string(got) != original {
				t.Fatalf("restored %q, want %q", got, original)
			}
			if _, err := os.Stat(filepath.Join(dir, "state/session")); !os.IsNotExist(err) {
				t.Fatal("session not cleared")
			}
		})
	}
}
func TestWrapperRejectsOtherUsersAndExtraArguments(t *testing.T) {
	run, dir := fixture(t, "0")
	if err := run("501", "on"); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		uid  string
		args []string
	}{{"502", []string{"off"}}, {"501", []string{"on", "extra"}}, {"501", []string{"status"}}, {"", []string{"off"}}} {
		if run(tc.uid, tc.args...) == nil {
			t.Fatalf("accepted %#v", tc)
		}
	}
	got, _ := os.ReadFile(filepath.Join(dir, "power"))
	if string(got) != "1" {
		t.Fatal("unauthorized call changed power")
	}
	if err := run("501", "off"); err != nil {
		t.Fatal(err)
	}
}
func TestWrapperFailsClosedOnUnreadablePowerState(t *testing.T) {
	run, dir := fixture(t, "unknown")
	if run("501", "on") == nil {
		t.Fatal("accepted invalid original state")
	}
	if _, err := os.Stat(filepath.Join(dir, "state/session")); !os.IsNotExist(err) {
		t.Fatal("saved invalid state")
	}
}

func TestWrapperKeepsRecoveryRecordWhenRestoreFails(t *testing.T) {
	run, dir := fixture(t, "0")
	if err := run("501", "on"); err != nil {
		t.Fatal(err)
	}
	mock := "#!/bin/sh\nif [ \"$1\" = -g ]; then echo 'SleepDisabled 1'; else exit 1; fi\n"
	if err := os.WriteFile(filepath.Join(dir, "pmset"), []byte(mock), 0700); err != nil {
		t.Fatal(err)
	}
	if run("501", "off") == nil {
		t.Fatal("reported restoration success")
	}
	data, err := os.ReadFile(filepath.Join(dir, "state/session"))
	if err != nil || string(data) != "501 0\n" {
		t.Fatalf("lost original state: %q, %v", data, err)
	}
}

func TestTouchIDPAMDetection(t *testing.T) {
	for _, tc := range []struct {
		main, local string
		want        bool
	}{
		{"auth include sudo_local", "auth sufficient pam_tid.so", true},
		{"auth include sudo_local", "#auth sufficient pam_tid.so", false},
		{"#auth include sudo_local", "auth sufficient pam_tid.so", false},
		{"auth sufficient /usr/lib/pam/pam_tid.so", "", true},
		{"auth required pam_opendirectory.so", "auth sufficient pam_tid.so", false},
	} {
		if got := pamTouchIDEnabled(tc.main, tc.local); got != tc.want {
			t.Errorf("%q / %q: %v", tc.main, tc.local, got)
		}
	}
}
func TestAuthorizationRouting(t *testing.T) {
	for _, tc := range []struct {
		name                         string
		touch, authFail, installFail bool
		want                         string
		fail                         bool
	}{
		{"biometric", true, false, false, "/usr/bin/sudo,/usr/bin/sudo,/usr/bin/sudo", false},
		{"fallback", true, true, false, "/usr/bin/sudo,/usr/bin/sudo,/usr/bin/osascript", false},
		{"unconfigured", false, false, false, "/usr/bin/osascript", false},
		{"no installer retry", true, false, true, "/usr/bin/sudo,/usr/bin/sudo,/usr/bin/sudo", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls []string
			command := func(name string, args ...string) error {
				calls = append(calls, name)
				if name == "/usr/bin/sudo" && args[0] == "-S" && tc.authFail {
					return os.ErrPermission
				}
				if name == "/usr/bin/sudo" && args[0] == "-n" && tc.installFail {
					return os.ErrPermission
				}
				return nil
			}
			err := authorizeWith("fixed installer", tc.touch, command)
			if (err != nil) != tc.fail || strings.Join(calls, ",") != tc.want {
				t.Fatalf("calls %v, error %v", calls, err)
			}
		})
	}
}

func TestAuthorizationRequiresRuleDespiteCachedSudo(t *testing.T) {
	calls := 0
	cachedSudo := func(name string, args ...string) error { calls++; return nil }
	if authorizedWith(false, []byte(wrapper), cachedSudo) {
		t.Fatal("removed rule treated as authorized with cached sudo credentials")
	}
	if calls != 0 {
		t.Fatal("queried sudo despite missing installation")
	}
	// Simulate a fresh installation in the same process, without restarting ACU.
	if !authorizedWith(true, []byte(wrapper), cachedSudo) {
		t.Fatal("fresh installation not recognized")
	}
	if authorizedWith(false, []byte(wrapper), cachedSudo) {
		t.Fatal("second removal not recognized")
	}
}
func TestAuthorizationQueriesIgnoreCachedCredentials(t *testing.T) {
	calls := 0
	command := func(name string, args ...string) error {
		calls++
		if name != "/usr/bin/sudo" || len(args) != 6 || args[0] != "-n" || args[1] != "-k" || args[2] != "-l" {
			t.Fatalf("unexpected query: %s %v", name, args)
		}
		return nil
	}
	if !authorizedWith(true, []byte(wrapper), command) || calls != 2 {
		t.Fatal("expected both exact command checks")
	}
}

// Model sudo's timestamp semantics: -k combined with -v authenticates without
// caching, so a following -n installer would fail with "a password is required".
func TestTouchIDValidationCachesCredentialForInstaller(t *testing.T) {
	cached := true
	installed := false
	var calls []string
	command := func(name string, args ...string) error {
		calls = append(calls, strings.Join(args, " "))
		if name != "/usr/bin/sudo" {
			t.Fatal("unexpected password fallback")
			return os.ErrPermission
		}
		if len(args) == 1 && args[0] == "-k" {
			cached = false
			return nil
		}
		if args[0] == "-S" {
			if cached {
				t.Fatal("authentication did not reset old credentials")
			}
			cached = true
			for _, arg := range args {
				if arg == "-k" {
					cached = false
				}
			}
			return nil
		}
		if args[0] == "-n" {
			if !cached {
				return os.ErrPermission
			}
			installed = true
			return nil
		}
		return os.ErrPermission
	}
	if err := authorizeWith("installer", true, command); err != nil || !installed {
		t.Fatalf("installer did not receive authenticated credential: %v; calls=%v", err, calls)
	}
}
