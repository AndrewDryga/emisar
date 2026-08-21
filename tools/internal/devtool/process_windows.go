//go:build windows

package devtool

import (
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
)

func lockFile(*os.File, bool) error {
	return fmt.Errorf("Portal and serve locks are not supported on Windows")
}

func unlockFile(*os.File) error { return nil }

func configureDetachedProcess(*exec.Cmd) {}

func configureProcessGroup(*exec.Cmd) {}

func stopProcessGroup(command *exec.Cmd, _ bool) error {
	return command.Process.Kill()
}

func stopProcessID(pid int) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Kill()
}

func currentUserLockID() string {
	digest := sha256.Sum256([]byte(os.Getenv("USERNAME")))
	return fmt.Sprintf("%x", digest[:8])
}
