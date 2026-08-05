//go:build windows

package config

import "io/fs"

// Windows has no uid to compare; the permission-bit check in Load carries the
// boundary there.
func checkConfigOwner(_ fs.FileInfo, _ string) error { return nil }
