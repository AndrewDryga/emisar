//go:build !linux && !darwin

package executor

import "os/exec"

// applyProcAttr is a no-op on platforms without process-group containment.
func applyProcAttr(_ *exec.Cmd) {}

// startCommand has no no_new_privs equivalent on these platforms; Linux carries
// the privilege-escalation guard.
func startCommand(cmd *exec.Cmd) error {
	return cmd.Start()
}
