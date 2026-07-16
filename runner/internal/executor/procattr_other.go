//go:build !linux

package executor

import (
	"fmt"
	"os/exec"
	"runtime"
)

// applyProcAttr is a no-op on non-Linux because Pdeathsig and process-group
// signaling use Linux-specific process attributes.
func applyProcAttr(_ *exec.Cmd) {}

func applyCredential(_ *exec.Cmd, username string) error {
	return fmt.Errorf("execution.user %q is unsupported on %s", username, runtime.GOOS)
}
