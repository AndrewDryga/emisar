//go:build !linux

package executor

import (
	"fmt"
	"os/exec"
	"runtime"
)

// An empty execution.user keeps the runner's own identity on every platform;
// only a named user needs the Linux credential switch.
func applyCredential(_ *exec.Cmd, username string) error {
	if username == "" {
		return nil
	}
	return fmt.Errorf("execution.user %q is unsupported on %s", username, runtime.GOOS)
}
