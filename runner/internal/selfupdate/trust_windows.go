//go:build windows

package selfupdate

import (
	"errors"
	"io/fs"
)

func effectiveUID() int { return -1 }

func requireRootOwnedPath(_ string, _ fs.FileInfo) error {
	return errors.New("self-update is supported only on Linux and macOS")
}
