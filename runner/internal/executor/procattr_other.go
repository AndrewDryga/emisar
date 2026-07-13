//go:build !linux

package executor

import (
	"log/slog"
	"os/exec"
)

// applyProcAttr is a no-op on non-Linux. Pdeathsig is Linux-specific —
// children may become orphans if the runner dies. Production targets Linux;
// this stub keeps development builds explicit about the weaker guarantee.
func applyProcAttr(_ *exec.Cmd) {}

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
