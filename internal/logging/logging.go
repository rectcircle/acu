// Package logging configures persistent structured diagnostics for both processes.
package logging

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"syscall"
)

const maxBytes = 5 * 1024 * 1024

// Init writes JSON lines to ~/Library/Logs/ACU/acu.log. A shared lock keeps
// Controller and Guardian writes and rotation serialized. Three backups bound
// disk use to approximately 20 MiB. Failure leaves stderr logging available.
func Init(role string) (func(), error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return func() {}, err
	}
	dir := filepath.Join(home, "Library", "Logs", "ACU")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return func() {}, err
	}
	lock, err := os.OpenFile(filepath.Join(dir, ".lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return func() {}, err
	}
	writer := &rotatingWriter{path: filepath.Join(dir, "acu.log"), lock: lock}
	slog.SetDefault(slog.New(slog.NewJSONHandler(io.MultiWriter(os.Stderr, writer), nil)).With("role", role, "pid", os.Getpid()))
	return func() { _ = lock.Close() }, nil
}

type rotatingWriter struct {
	mu   sync.Mutex
	path string
	lock *os.File
}

func (w *rotatingWriter) Write(p []byte) (n int, writeErr error) {
	defer func() {
		if writeErr != nil {
			fmt.Fprintf(os.Stderr, "ACU ERROR: persistent log write failed: %v\n", writeErr)
		}
	}()
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := syscall.Flock(int(w.lock.Fd()), syscall.LOCK_EX); err != nil {
		return 0, err
	}
	defer syscall.Flock(int(w.lock.Fd()), syscall.LOCK_UN)
	if info, err := os.Stat(w.path); err == nil && info.Size()+int64(len(p)) > maxBytes {
		if err := os.Remove(w.path + ".3"); err != nil && !os.IsNotExist(err) {
			return 0, err
		}
		for i := 2; i >= 0; i-- {
			src := w.path
			if i > 0 {
				src = fmt.Sprintf("%s.%d", w.path, i)
			}
			if err := os.Rename(src, fmt.Sprintf("%s.%d", w.path, i+1)); err != nil && !os.IsNotExist(err) {
				return 0, err
			}
		}
	}
	file, err := os.OpenFile(w.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return 0, err
	}
	defer file.Close()
	return file.Write(p)
}
