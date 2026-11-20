//go:build windows

package infraops

import "os/exec"

func isolateTunnel(*exec.Cmd) {}

func killTunnel(command *exec.Cmd) error {
	return command.Process.Kill()
}
