//go:build !linux

package executor

import (
	"log/slog"
	"os/exec"
	"syscall"
)

// applyProcAttr is a no-op on non-Linux. Pdeathsig is Linux-specific —
// children may become orphans if the runner dies on macOS/BSD. Production
// targets Linux; this stub exists so dev builds on other OSes compile.
func applyProcAttr(_ *exec.Cmd) {}

// killGroup falls back to signalling the direct child only. Without
// Setpgid on this platform, signalling the negative pid would behave
// differently (typically EPERM).
func killGroup(pid int, sig syscall.Signal) error {
	return syscall.Kill(pid, sig)
}

// applyCredential is a soft no-op on non-Linux. The runner runs as
// whatever uid started it. We log a warning so a dev catches the
// effective-no-op early; in CI/production this code path doesn't
// execute (runner ships only Linux binaries).
func applyCredential(_ *exec.Cmd, username string) error {
	slog.Warn("executor.user.ignored",
		"reason", "setuid drop is Linux-only; this build is not Linux",
		"requested_user", username,
	)
	return nil
}
