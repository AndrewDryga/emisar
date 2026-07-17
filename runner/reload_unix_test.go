//go:build !windows

package main

import (
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

func reloadConfig(dataDir string) *config.Config {
	cfg := &config.Config{}
	cfg.Paths.DataDir = dataDir
	return cfg
}

func TestNotifyRunnerReload(t *testing.T) {
	t.Run("no data dir configured", func(t *testing.T) {
		if notifyRunnerReload(reloadConfig("")) {
			t.Error("expected false with no data dir")
		}
	})

	t.Run("no lock file (daemon never ran)", func(t *testing.T) {
		if notifyRunnerReload(reloadConfig(t.TempDir())) {
			t.Error("expected false with no lock file")
		}
	})

	t.Run("stale lock file (daemon gone) is never signaled", func(t *testing.T) {
		dir := t.TempDir()
		path := runnerLockPath(dir)
		if err := os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0o600); err != nil {
			t.Fatalf("write stale lock: %v", err)
		}

		if notifyRunnerReload(reloadConfig(dir)) {
			t.Error("expected false for an unheld (stale) lock — a reused PID must not be signaled")
		}
	})

	t.Run("held lock without a PID record falls back", func(t *testing.T) {
		dir := t.TempDir()
		lock, err := fsutil.AcquireFileLock(runnerLockPath(dir))
		if err != nil {
			t.Fatalf("acquire: %v", err)
		}
		defer func() { _ = lock.Close() }()

		if notifyRunnerReload(reloadConfig(dir)) {
			t.Error("expected false when the held lock carries no PID record")
		}
	})

	t.Run("held lock with a live PID gets SIGHUP", func(t *testing.T) {
		dir := t.TempDir()
		lock, err := fsutil.AcquireFileLock(runnerLockPath(dir))
		if err != nil {
			t.Fatalf("acquire: %v", err)
		}
		defer func() { _ = lock.Close() }()

		if err := lock.WriteRecord([]byte(strconv.Itoa(os.Getpid()))); err != nil {
			t.Fatalf("write record: %v", err)
		}

		// Capture the SIGHUP we are about to send ourselves — the test process
		// stands in for the daemon.
		hup := make(chan os.Signal, 1)
		signal.Notify(hup, syscall.SIGHUP)
		defer signal.Stop(hup)

		if !notifyRunnerReload(reloadConfig(dir)) {
			t.Fatal("expected true for a held lock with a live PID")
		}

		select {
		case <-hup:
		case <-time.After(2 * time.Second):
			t.Fatal("SIGHUP was not delivered")
		}
	})
}

func TestLockConnectDataDirRecordsPID(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "data")

	lock, err := lockConnectDataDir(dir)
	if err != nil {
		t.Fatalf("lockConnectDataDir: %v", err)
	}
	defer func() { _ = lock.Close() }()

	raw, err := os.ReadFile(runnerLockPath(dir))
	if err != nil {
		t.Fatalf("read lock file: %v", err)
	}
	if got, want := string(raw), strconv.Itoa(os.Getpid()); got != want {
		t.Errorf("lock record = %q, want %q", got, want)
	}
}
