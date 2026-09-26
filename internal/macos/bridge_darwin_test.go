//go:build darwin

package macos

import "testing"

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
