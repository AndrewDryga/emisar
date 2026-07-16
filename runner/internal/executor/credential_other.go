//go:build !linux

package executor

import (
	"fmt"
	"os/exec"
	"runtime"
)

func applyCredential(_ *exec.Cmd, username string) error {
	return fmt.Errorf("execution.user %q is unsupported on %s", username, runtime.GOOS)
}
