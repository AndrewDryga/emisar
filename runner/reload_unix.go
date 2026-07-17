//go:build !windows

package main

import (
	"os"
	"strconv"
	"strings"
	"syscall"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

// notifyRunnerReload nudges a running connect daemon to re-read packs and
// re-advertise its catalog — SIGHUP, exactly what `systemctl reload emisar`
// sends. Best-effort by design: false means "couldn't signal a live daemon"
// (none running, a pre-record daemon, or an unprivileged CLI vs a root
// daemon), and the caller prints the manual reload hint instead.
//
// The PID comes from the record the daemon wrote into its held runner.lock;
// liveness is proven by the flock itself — the kernel releases it when the
// holder dies, so a briefly-acquirable lock means the record is stale and no
// signal is sent to a possibly-reused PID.
func notifyRunnerReload(cfg *config.Config) bool {
	if cfg == nil {
		loaded, err := loadConfig()
		if err != nil {
			return false
		}
		cfg = loaded
	}

	dataDir := strings.TrimSpace(cfg.Paths.DataDir)
	if dataDir == "" {
		return false
	}
	lockPath := runnerLockPath(dataDir)

	held, err := fsutil.ProbeFileLock(lockPath)
	if err != nil || !held {
		return false
	}

	raw, err := os.ReadFile(lockPath)
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 {
		return false
	}

	return syscall.Kill(pid, syscall.SIGHUP) == nil
}
