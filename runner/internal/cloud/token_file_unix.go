//go:build !windows

package cloud

import (
	"os"
	"syscall"
)

func openTokenFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
}
