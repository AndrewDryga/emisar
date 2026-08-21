//go:build windows

package installtest

import "os/exec"

func configureWithoutControllingTerminal(*exec.Cmd) {}
