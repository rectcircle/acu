package guardian

import (
	"testing"

	"github.com/rectcircle/acu-helper/internal/ipc"
)

func TestValidateHelloModes(t *testing.T) {
	tests := []struct {
		name    string
		hello   ipc.Message
		want    string
		wantErr bool
	}{
		{
			name:  "legacy protection",
			hello: ipc.Message{Type: messageHello, Token: "token"},
			want:  modeProtection,
		},
		{
			name: "protection test",
			hello: ipc.Message{
				Type:           messageHello,
				Token:          "token",
				Mode:           modeProtection,
				TimeoutSeconds: testTimeoutSeconds,
			},
			want: modeProtection,
		},
		{
			name: "keep awake",
			hello: ipc.Message{
				Type:  messageHello,
				Token: "token",
				Mode:  modeKeepAwake,
			},
			want: modeKeepAwake,
		},
		{
			name: "keep awake timeout",
			hello: ipc.Message{
				Type:           messageHello,
				Token:          "token",
				Mode:           modeKeepAwake,
				TimeoutSeconds: testTimeoutSeconds,
			},
			wantErr: true,
		},
		{
			name: "unknown mode",
			hello: ipc.Message{
				Type:  messageHello,
				Token: "token",
				Mode:  "unknown",
			},
			wantErr: true,
		},
		{
			name:    "missing token",
			hello:   ipc.Message{Type: messageHello, Mode: modeKeepAwake},
			wantErr: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := validateHello(test.hello)
			if test.wantErr {
				if err == nil {
					t.Fatal("expected validation error")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("got mode %q, want %q", got, test.want)
			}
		})
	}
}
