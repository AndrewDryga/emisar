//go:build !windows

package cloud

import (
	"os"
	"syscall"
)

// openSecureLocalFile opens a runner-owned file for reading with the guards
// every such read needs. O_NOFOLLOW refuses a symlink at the final path, and
// O_NONBLOCK keeps a hostile FIFO from hanging the reader inside open(2) —
// without it the block happens before any fstat can reject the file as
// non-regular, so the caller never gets to apply its own checks. Callers still
// stat the handle themselves: the permission and regular-file policy differs
// per file, and only the open flags are shared.
func openSecureLocalFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
}
