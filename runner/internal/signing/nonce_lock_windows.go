//go:build windows

package signing

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

type nonceJournalLock struct {
	file       *os.File
	overlapped syscall.Overlapped
}

func acquireNonceJournalLock(path string) (*nonceJournalLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	lock := &nonceJournalLock{file: file}
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
		return nil, fmt.Errorf("another runner process owns the journal: %w", callErr)
	}
	return lock, nil
}

func (l *nonceJournalLock) Close() error {
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
