//go:build windows

package fsutil

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

const (
	lockfileExclusiveLock   = 0x00000002
	lockfileFailImmediately = 0x00000001
)

var (
	kernel32UnlockFileEx = syscall.NewLazyDLL("kernel32.dll").NewProc("UnlockFileEx")
	kernel32LockFileEx   = syscall.NewLazyDLL("kernel32.dll").NewProc("LockFileEx")
)

// FileLock is an exclusive, process-owned lock held until Close.
type FileLock struct {
	file       *os.File
	overlapped syscall.Overlapped
}

// AcquireFileLock acquires a non-blocking exclusive lock on path.
func AcquireFileLock(path string) (*FileLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	lock := &FileLock{file: file}
	result, _, callErr := kernel32LockFileEx.Call(
		file.Fd(),
		lockfileExclusiveLock|lockfileFailImmediately,
		0,
		1,
		0,
		uintptr(unsafe.Pointer(&lock.overlapped)),
	)
	if result == 0 {
		_ = file.Close()
		return nil, fmt.Errorf("file lock is already held: %w", callErr)
	}
	return lock, nil
}

// Close releases the lock.
func (l *FileLock) Close() error {
	if l == nil || l.file == nil {
		return nil
	}
	result, _, callErr := kernel32UnlockFileEx.Call(
		l.file.Fd(),
		0,
		1,
		0,
		uintptr(unsafe.Pointer(&l.overlapped)),
	)
	closeErr := l.file.Close()
	l.file = nil
	if result == 0 {
		return callErr
	}
	return closeErr
}
