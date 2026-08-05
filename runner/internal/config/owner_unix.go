//go:build !windows

package config

import (
	"fmt"
	"io/fs"
	"os"
	"syscall"
)

// checkConfigOwner accepts a config owned by root (root wrote it) or by the
// identity actually running — and refuses anything else, because a third party
// who owns this file chooses the packs the runner loads.
func checkConfigOwner(info fs.FileInfo, path string) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return nil
	}
	owner := stat.Uid
	if owner == 0 || owner == uint32(os.Geteuid()) {
		return nil
	}
	return fmt.Errorf(
		"config: %s is owned by uid %d, which is neither root nor this process (uid %d)",
		path, owner, os.Geteuid())
}
