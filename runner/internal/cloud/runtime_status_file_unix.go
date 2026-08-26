//go:build !windows

package cloud

import (
	"os"
	"syscall"
)

// openRuntimeStatusFile refuses symlinks at the final path. O_NONBLOCK keeps a
// hostile FIFO from hanging the privileged status reader before fstat rejects
// it as non-regular.
func openRuntimeStatusFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
}
