//go:build windows

package main

import (
	"errors"
	"syscall"
	"time"
)

const (
	credentialLockWait    = 5 * time.Second
	errorSharingViolation = syscall.Errno(32)
)

func lockCredentialFile(path string) (func(), error) {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(credentialLockWait)
	for {
		handle, err := syscall.CreateFile(
			name,
			syscall.GENERIC_READ|syscall.GENERIC_WRITE,
			0,
			nil,
			syscall.OPEN_ALWAYS,
			syscall.FILE_ATTRIBUTE_NORMAL,
			0,
		)
		if err == nil {
			return func() { _ = syscall.CloseHandle(handle) }, nil
		}
		if !errors.Is(err, errorSharingViolation) || time.Now().After(deadline) {
			return nil, err
		}
		time.Sleep(25 * time.Millisecond)
	}
}
