//go:build !windows

package main

import (
	"fmt"
	"os"
	"syscall"
)

func secureCredentialDirectoryAccess(path string) (*os.File, error) {
	return os.Open(path)
}

func validateCredentialTempFileAccess(*os.File) error {
	return nil
}

// validateCredentialOwner refuses a credential file or directory owned by
// another user. Owner-only permission bits are not enough on their own: a
// 0600 file owned by a different uid (an NFS-planted emk- key, say) still lets
// that user read and control it, so the current process must own it.
func validateCredentialOwner(info os.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("cannot determine owning user")
	}
	if stat.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("owned by uid %d, want the current user %d", stat.Uid, os.Getuid())
	}
	return nil
}

func validateCredentialFileAccess(_ string, info os.FileInfo) error {
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("permissions are %04o, want owner-only", info.Mode().Perm())
	}
	return validateCredentialOwner(info)
}

func validateCredentialDirectoryAccess(_ string, info os.FileInfo) error {
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("permissions are %04o, want owner-only", info.Mode().Perm())
	}
	return validateCredentialOwner(info)
}
