//go:build darwin || dragonfly || freebsd || illumos || linux || netbsd || openbsd

package fsutil

import (
	"fmt"
	"os"
	"syscall"
)

// FileLock is an exclusive, process-owned lock held until Close.
type FileLock struct {
	file *os.File
}

// AcquireFileLock acquires a non-blocking exclusive lock on path.
func AcquireFileLock(path string) (*FileLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("file lock is already held: %w", err)
	}
	return &FileLock{file: file}, nil
}

// Close releases the lock.
func (l *FileLock) Close() error {
	if l == nil || l.file == nil {
		return nil
	}
	unlockErr := syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	closeErr := l.file.Close()
	l.file = nil
	if unlockErr != nil {
		return unlockErr
	}
	return closeErr
}

// ProbeFileLock reports whether path's lock is currently held by some other
// process, WITHOUT creating the file (a probe must never plant a wrongly-owned
// lock file the real daemon later can't open). A missing file surfaces as
// `os.ErrNotExist`.
func ProbeFileLock(path string) (bool, error) {
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return false, err
	}
	defer func() { _ = file.Close() }()

	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return true, nil
	}

	_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	return false, nil
}
