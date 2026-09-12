//go:build !windows

package packtest

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

// containCommand puts the command in its own process group and makes the
// deadline signal that whole group, following the same Setpgid + kill(-pgid)
// shape runner/internal/executor uses for action cancellation. Without it
// os/exec's default cancellation kills the direct child only, so a case whose
// argv is `/bin/sh -c '<pipeline>'` leaves the pipeline's own children running
// against the disposable fixture the case is about to tear down.
//
// The group is the command's alone — Setpgid makes the child the group leader,
// so the negative pid reaches its descendants and nothing else. The trade-off
// is that the command no longer shares the harness's group, so a terminal
// Ctrl-C reaches the harness but not a compose call it is blocked on; the
// deadline is what reclaims that, which is the point of this file.
func containCommand(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		// The leader may already be reaped when the deadline lands. os/exec
		// treats a Cancel error as the command's error unless it is
		// ErrProcessDone, and "there was nothing left to kill" is not a
		// harness failure.
		if err := killCommandGroup(command); err != nil {
			if errors.Is(err, syscall.ESRCH) {
				return os.ErrProcessDone
			}
			return err
		}
		return nil
	}
}

// stopCommandGroup removes what is left of a failed command's group, for the
// paths os/exec's own cancellation never reaches: a deadline that landed after
// the leader was reaped, and a drain the WaitDelay had to cut short. A group
// with no members left is the normal case and reports nothing.
func stopCommandGroup(command *exec.Cmd) {
	_ = killCommandGroup(command)
}

func killCommandGroup(command *exec.Cmd) error {
	if command.Process == nil {
		return nil
	}
	// Negative pid, so this is the command's own group and nothing else:
	// Setpgid made the child its own leader, so the group id is its pid.
	return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
}
