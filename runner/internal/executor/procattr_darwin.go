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

// startCommand has no no_new_privs equivalent to set here; Linux carries the
// privilege-escalation guard, and this platform is development-only.
func startCommand(cmd *exec.Cmd) error {
	return cmd.Start()
}

// ProtectProcess has nothing to hide here: there is no /proc, and this
// platform is development-only. Linux carries the non-dumpable guard.
func ProtectProcess() error {
	return nil
}

func killGroup(pid int, sig syscall.Signal) error {
	return syscall.Kill(-pid, sig)
}
