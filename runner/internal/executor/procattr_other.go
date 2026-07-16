//go:build !linux && !darwin

package executor

import "os/exec"

// applyProcAttr is a no-op on platforms without process-group containment.
func applyProcAttr(_ *exec.Cmd) {}
