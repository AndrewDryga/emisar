//go:build !windows

package infraops

import (
	"os/exec"
	"syscall"
)

// isolateTunnel moves a tunnel child into its own process group. A Ctrl-C typed
// at the terminal reaches the foreground group only, so it interrupts psql's
// query rather than the SSH tunnel and proxy psql is connected through.
// Cancelling the command's context kills the whole group, so a helper the
// child started (gcloud's ssh and its IAP ProxyCommand) does not outlive it.
func isolateTunnel(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return killTunnel(command) }
}

func killTunnel(command *exec.Cmd) error {
	return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
}
