//go:build windows

package packtest

import "os/exec"

// containCommand is deliberately a no-op on Windows: there is no process group
// to signal through syscall.Kill, so a timed-out command's descendants are not
// contained and os/exec's default cancellation — killing the direct child
// only — stands. execute's WaitDelay still bounds the return there, so the
// deadline holds; what is missing is the containment, not the timeout.
func containCommand(*exec.Cmd) {}

// stopCommandGroup is a no-op for the same reason, on the deadline path and on
// the cut-short drain alike. Neither file is exercised on Windows: the process
// tests are !windows, so this side is compile-checked and bounded-return only
// until someone runs the harness there.
func stopCommandGroup(*exec.Cmd) {}
