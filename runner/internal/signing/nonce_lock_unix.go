//go:build darwin || dragonfly || freebsd || illumos || linux || netbsd || openbsd

package signing

import (
	"fmt"
	"os"
	"syscall"
)

type nonceJournalLock struct {
	file *os.File
}

func acquireNonceJournalLock(path string) (*nonceJournalLock, error) {
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
		return nil, fmt.Errorf("another runner process owns the journal: %w", err)
	}
	return &nonceJournalLock{file: file}, nil
}

func (l *nonceJournalLock) Close() error {
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
