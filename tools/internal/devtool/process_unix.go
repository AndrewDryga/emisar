//go:build !windows

package devtool

import (
	"os"
	"os/exec"
	"strconv"
	"syscall"
)

func lockFile(file *os.File, nonBlocking bool) error {
	operation := syscall.LOCK_EX
	if nonBlocking {
		operation |= syscall.LOCK_NB
	}
	return syscall.Flock(int(file.Fd()), operation)
}

func unlockFile(file *os.File) error {
	return syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
}

func configureDetachedProcess(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

func configureProcessGroup(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func stopProcessGroup(command *exec.Cmd, force bool) error {
	signal := syscall.SIGTERM
	if force {
		signal = syscall.SIGKILL
	}
	return syscall.Kill(-command.Process.Pid, signal)
}

func stopProcessID(pid int) error {
	return syscall.Kill(pid, syscall.SIGTERM)
}

func currentUserLockID() string {
	return strconv.Itoa(os.Getuid())
}
