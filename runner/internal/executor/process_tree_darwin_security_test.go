//go:build darwin

package executor

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestExecutorDarwinCancellationKillsDescendantProcessGroup(t *testing.T) {
	pidPath := filepath.Join(t.TempDir(), "child.pid")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); {
			if _, err := os.Stat(pidPath); err == nil {
				time.Sleep(100 * time.Millisecond)
				cancel()
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
	}()

	res, err := New().Execute(ctx, Plan{
		Binary: "/bin/sh",
		Argv: []string{"-c", fmt.Sprintf(
			`trap '' TERM; (trap '' TERM; while :; do sleep 1; done) & echo $! > %q; while :; do sleep 1; done`,
			pidPath,
		)},
		Limits:      Limits{Timeout: 10 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
		CancelGrace: 200 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusCancelled {
		t.Fatalf("status = %s, want cancelled", res.Status)
	}

	pid := readDarwinProcessID(t, pidPath)
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })
	waitForDarwinProcessExit(t, pid, 3*time.Second)
}

func readDarwinProcessID(t *testing.T, path string) int {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatalf("parse pid %q: %v", raw, err)
	}
	return pid
}

func waitForDarwinProcessExit(t *testing.T, pid int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		err := syscall.Kill(pid, 0)
		if errors.Is(err, syscall.ESRCH) {
			return
		}
		if err != nil && !errors.Is(err, syscall.EPERM) {
			t.Fatalf("check descendant process %d: %v", pid, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("descendant process %d survived", pid)
}
