//go:build windows

package packtest

import "os/exec"

// containCommand is deliberately a no-op on Windows: there is no process group
// to signal through syscall.Kill, so a timed-out command's descendants are not
// contained and os/exec's default cancellation — killing the direct child
// only — stands. execute's WaitDelay still bounds the return there, so the
// deadline holds; what is missing is the containment, not the timeout.
func containCommand(*exec.Cmd) {}

// stopCommandGroup is a no-op for the same reason.
func stopCommandGroup(*exec.Cmd) {}
