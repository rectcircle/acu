package logging

import (
	"bytes"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestConcurrentProcessesAndRotation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "acu.log")
	if err := os.WriteFile(path, bytes.Repeat([]byte("x"), maxBytes), 0600); err != nil {
		t.Fatal(err)
	}
	writers := make([]*rotatingWriter, 2)
	for i := range writers {
		lock, err := os.OpenFile(filepath.Join(dir, ".lock"), os.O_CREATE|os.O_RDWR, 0600)
		if err != nil {
			t.Fatal(err)
		}
		defer lock.Close()
		writers[i] = &rotatingWriter{path: path, lock: lock}
	}
	var wg sync.WaitGroup
	for _, writer := range writers {
		wg.Add(1)
		go func(w *rotatingWriter) {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				if _, err := w.Write([]byte("record\n")); err != nil {
					t.Error(err)
				}
			}
		}(writer)
	}
	wg.Wait()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, bytes.Repeat([]byte("record\n"), 200)) {
		t.Fatal("records lost or interleaved")
	}
	info, err := os.Stat(path + ".1")
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() != maxBytes {
		t.Fatal("rotation lost previous contents")
	}
	// Multiple rotations retain only three backups.
	for i := 0; i < 4; i++ {
		if _, err := writers[0].Write(bytes.Repeat([]byte("y"), maxBytes)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(path + ".3"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path + ".4"); !os.IsNotExist(err) {
		t.Fatal("unbounded backups")
	}
}
