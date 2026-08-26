//go:build !windows

package main

import (
	"fmt"
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
	pid, held, err := probeRunnerLockOwner(dataDir)
	if err != nil || !held {
		return false
	}
	return syscall.Kill(pid, syscall.SIGHUP) == nil
}

// probeRunnerLockOwner returns the PID recorded by a currently held runner
// lock. The flock is the liveness proof; an unlocked record is stale even when
// its PID happens to have been reused by another process.
func probeRunnerLockOwner(dataDir string) (pid int, held bool, err error) {
	lockPath := runnerLockPath(dataDir)
	held, err = fsutil.ProbeFileLock(lockPath)
	if os.IsNotExist(err) {
		return 0, false, nil
	}
	if err != nil || !held {
		return 0, held, err
	}
	raw, err := os.ReadFile(lockPath)
	if err != nil {
		return 0, true, err
	}
	pid, err = strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 {
		return 0, true, fmt.Errorf("runner lock has an invalid PID record")
	}
	return pid, true, nil
}
