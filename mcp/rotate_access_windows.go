//go:build windows

package main

import (
	"errors"
	"os"
)

func isCredentialWriteUnavailable(err error) bool {
	return errors.Is(err, os.ErrPermission)
}
