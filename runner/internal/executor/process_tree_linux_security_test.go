//go:build linux

package executor

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestExecutor_CancellationKillsDescendantProcessGroup(t *testing.T) {
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
	if res.Status == StatusOK {
		t.Fatal("cancelled process tree reported success")
	}
	childPID := readProcessID(t, pidPath)
	waitForProcessExit(t, childPID, 3*time.Second)
}

func TestExecutor_CancellationKillsDescendantAfterLeaderExits(t *testing.T) {
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
			`trap 'exit 0' TERM; (trap '' TERM; exec >/dev/null 2>&1; while :; do sleep 1; done) & echo $! > %q; while :; do sleep 1; done`,
			pidPath,
		)},
		Limits:      Limits{Timeout: 10 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
		CancelGrace: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusCancelled {
		t.Fatalf("status = %s, want cancelled", res.Status)
	}
	waitForProcessExit(t, readProcessID(t, pidPath), 3*time.Second)
}

func TestExecutor_DescendantHoldingOutputPipeCannotHangWait(t *testing.T) {
	pidPath := filepath.Join(t.TempDir(), "child.pid")
	start := time.Now()
	res, err := New().Execute(context.Background(), Plan{
		Binary:      "/bin/sh",
		Argv:        []string{"-c", fmt.Sprintf(`sleep 30 & echo $! > %q`, pidPath)},
		Limits:      Limits{Timeout: 10 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
		CancelGrace: 200 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("Execute waited on an inherited pipe for %s", elapsed)
	}
	if res.Status != StatusFailed || !strings.Contains(res.StartError, "WaitDelay") {
		t.Fatalf("result=%+v, want a bounded inherited-pipe failure", res)
	}
	waitForProcessExit(t, readProcessID(t, pidPath), 3*time.Second)
}

func readProcessID(t *testing.T, path string) int {
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

func waitForProcessExit(t *testing.T, pid int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
		if os.IsNotExist(err) {
			return
		}
		if err == nil {
			fields := strings.Fields(string(raw))
			if len(fields) > 2 && fields[2] == "Z" {
				return
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("descendant process %d survived", pid)
}
