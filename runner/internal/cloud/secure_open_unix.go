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
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_NOCTTY, 0)
}

// openSecureLocalFileForAppend applies the same final-path and non-regular-file
// defenses to a durable append. It deliberately omits O_CREATE: journal
// creation and replacement go through fsutil.ReplaceFile instead.
func openSecureLocalFileForAppend(path string) (*os.File, error) {
	return os.OpenFile(
		path,
		os.O_WRONLY|os.O_APPEND|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_NOCTTY,
		0,
	)
}

func localFileOwnerTrusted(info os.FileInfo, allowRootInspection bool) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	// Root legitimately runs offline doctor/installer checks over the service
	// user's state. A live daemon and every writer accept only their own file.
	return allowRootInspection && os.Geteuid() == 0 || stat.Uid == uint32(os.Geteuid())
}
