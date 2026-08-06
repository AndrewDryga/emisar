//go:build darwin || dragonfly || freebsd || linux || netbsd || openbsd || solaris

package main

import (
	"errors"
	"os"
	"syscall"
)

// isCredentialWriteUnavailable reports whether durable credential state is
// simply not writable here, in which case the bridge degrades to the read-only
// path and disables rotation rather than refusing to start.
//
// The lock errors matter as much as the write errors. A corporate home
// directory on NFS, SMB, or 9p answers flock with ENOLCK or EOPNOTSUPP; those
// were classified as unexpected failures, so `emisar-mcp` died at startup with
// "lock credential state: no locks available" and no way to opt out. Contention
// that outlasts credentialLockWait lands here too — a peer bridge holds the
// lock, so this process reads and does not propose a successor.
func isCredentialWriteUnavailable(err error) bool {
	return errors.Is(err, os.ErrPermission) ||
		errors.Is(err, syscall.EROFS) ||
		errors.Is(err, syscall.ENOLCK) ||
		errors.Is(err, syscall.EOPNOTSUPP) ||
		errors.Is(err, syscall.ENOSYS) ||
		errors.Is(err, syscall.EWOULDBLOCK)
}
