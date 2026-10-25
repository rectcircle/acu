package app

import (
	"errors"
	"reflect"
	"testing"
)

func TestClamshellManualAndAutomaticConsent(t *testing.T) {
	installFailure := errors.New("installation failed")
	for _, tc := range []struct {
		name                        string
		manual, authorized, consent bool
		setupErr                    error
		wantCalls                   []string
		wantErr                     error
	}{
		{"startup restores silently", false, true, false, nil, []string{"authorized"}, nil},
		{"startup never requests missing privilege", false, false, true, nil, []string{"authorized"}, errClamshellAuthorizationMissing},
		{"manual enable always reminds", true, true, true, nil, []string{"authorized", "consent"}, nil},
		{"manual cancel stops activation", true, true, false, nil, []string{"authorized", "consent"}, errClamshellCancelled},
		{"first install precedes reminder", true, false, true, nil, []string{"authorized", "setup", "consent"}, nil},
		{"install failure skips reminder", true, false, true, installFailure, []string{"authorized", "setup"}, installFailure},
		{"cancel setup skips reminder", true, false, true, errClamshellCancelled, []string{"authorized", "setup"}, errClamshellCancelled},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var calls []string
			err := prepareClamshell(tc.manual,
				func() bool { calls = append(calls, "authorized"); return tc.authorized },
				func() error { calls = append(calls, "setup"); return tc.setupErr },
				func() bool { calls = append(calls, "consent"); return tc.consent })
			if !errors.Is(err, tc.wantErr) || !reflect.DeepEqual(calls, tc.wantCalls) {
				t.Fatalf("calls=%v error=%v; want %v %v", calls, err, tc.wantCalls, tc.wantErr)
			}
		})
	}
}
