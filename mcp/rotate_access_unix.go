//go:build darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package main

import (
	"errors"
	"os"
	"syscall"
)

func isCredentialWriteUnavailable(err error) bool {
	return errors.Is(err, os.ErrPermission) || errors.Is(err, syscall.EROFS)
}
