//go:build !windows

package selfupdate

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
)

func effectiveUID() int { return os.Geteuid() }

func requireRootOwnedPath(path string, info fs.FileInfo) error {
	if err := rootOwnedAndNotWritable(path, info, false); err != nil {
		return err
	}
	for directory := filepath.Dir(path); ; directory = filepath.Dir(directory) {
		info, err := os.Lstat(directory)
		if err != nil {
			return fmt.Errorf("inspect trusted path %s: %w", directory, err)
		}
		if err := rootOwnedAndNotWritable(directory, info, true); err != nil {
			return err
		}
		if directory == string(filepath.Separator) {
			break
		}
	}
	return nil
}

func rootOwnedAndNotWritable(path string, info fs.FileInfo, allowSticky bool) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 {
		return fmt.Errorf("%s is not root-owned", path)
	}
	if info.Mode().Perm()&0o022 != 0 {
		if allowSticky && info.Mode()&os.ModeSticky != 0 {
			return nil
		}
		return fmt.Errorf("%s is writable by group or other users", path)
	}
	return nil
}
