//go:build windows

package executor

import (
	"os"
	"syscall"
)

// Windows has no portable SIGTERM equivalent. Fail closed by terminating the
// direct child immediately; process-tree cancellation is unavailable here.
func killGroup(pid int, _ syscall.Signal) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Kill()
}
