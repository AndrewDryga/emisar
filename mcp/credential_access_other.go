//go:build !windows

package main

import (
	"fmt"
	"os"
)

func secureCredentialDirectoryAccess(path string) (*os.File, error) {
	return os.Open(path)
}

func validateCredentialTempFileAccess(*os.File) error {
	return nil
}

func validateCredentialFileAccess(_ string, info os.FileInfo) error {
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("permissions are %04o, want owner-only", info.Mode().Perm())
	}
	return nil
}

func validateCredentialDirectoryAccess(_ string, info os.FileInfo) error {
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("permissions are %04o, want owner-only", info.Mode().Perm())
	}
	return nil
}
