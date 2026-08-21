//go:build !windows

package installtest

import (
	"os/exec"
	"syscall"
)

func configureWithoutControllingTerminal(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}
