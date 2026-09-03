//go:build windows

package main

import (
	"errors"
	"os"
)

// isCredentialWriteUnavailable reports whether durable credential state is
// simply not writable here, in which case the bridge degrades to the read-only
// path and disables rotation rather than refusing to start.
//
// The lock error matters as much as the permission error, exactly as it does on
// unix. lockCredentialFile opens the lock with no sharing, so a peer bridge
// holding it past credentialLockWait surfaces ERROR_SHARING_VIOLATION — and
// syscall.Errno.Is maps only ERROR_ACCESS_DENIED/EACCES/EPERM onto
// os.ErrPermission, so without the explicit case the documented several-clients
// setup killed startup and every request on Windows while unix degraded.
func isCredentialWriteUnavailable(err error) bool {
	return errors.Is(err, os.ErrPermission) || errors.Is(err, errorSharingViolation)
}
