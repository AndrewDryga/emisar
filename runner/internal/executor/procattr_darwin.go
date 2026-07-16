//go:build darwin

package executor

import (
	"os/exec"
	"syscall"
)

// applyProcAttr gives each action its own process group so cancellation and
// timeout signals contain descendants spawned by scripts.
func applyProcAttr(cmd *exec.Cmd) {
	attr := cmd.SysProcAttr
	if attr == nil {
		attr = &syscall.SysProcAttr{}
	}
	attr.Setpgid = true
	cmd.SysProcAttr = attr
}

func killGroup(pid int, sig syscall.Signal) error {
	return syscall.Kill(-pid, sig)
}
