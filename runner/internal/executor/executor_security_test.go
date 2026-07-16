package executor

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestExecutor_PreCancelledContextDoesNotSpawnProcess(t *testing.T) {
	tests := []struct {
		name     string
		context  func(*testing.T) context.Context
		status   Status
		timedOut bool
	}{
		{
			name: "cancelled",
			context: func(t *testing.T) context.Context {
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				return ctx
			},
			status: StatusCancelled,
		},
		{
			name: "deadline exceeded",
			context: func(t *testing.T) context.Context {
				ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
				t.Cleanup(cancel)
				return ctx
			},
			status:   StatusTimeout,
			timedOut: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sentinel := filepath.Join(t.TempDir(), "spawned")
			res, err := New().Execute(tt.context(t), Plan{
				Binary: "/bin/sh",
				Argv:   []string{"-c", `printf spawned > "$1"`, "sh", sentinel},
				Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
			})
			if err != nil {
				t.Fatal(err)
			}
			if res.Status != tt.status || res.TimedOut != tt.timedOut {
				t.Fatalf("status = %s, timed_out = %t; want %s, %t", res.Status, res.TimedOut, tt.status, tt.timedOut)
			}
			if res.ExitCode != -1 {
				t.Fatalf("exit code = %d, want -1 for an unstarted process", res.ExitCode)
			}
			if _, err := os.Stat(sentinel); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("pre-cancelled process created sentinel: %v", err)
			}
		})
	}
}

// TestExecutor_StripsNonAllowlistedParentEnv: a parent environment variable
// that is NOT in the inherit allowlist must not reach the child process.
// This is the guard that keeps host secrets (the runner's own auth key,
// cloud tokens, …) out of every action's environment.
func TestExecutor_StripsNonAllowlistedParentEnv(t *testing.T) {
	t.Setenv("EMISAR_LEAK_PROBE", "supersecret")
	e := New() // DefaultInheritEnv = PATH/LANG/LC_ALL/TERM — not our probe
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/sh",
		Argv:   []string{"-c", `printf '%s' "${EMISAR_LEAK_PROBE}"`},
		Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(res.Stdout, "supersecret") {
		t.Fatalf("non-allowlisted parent env leaked into the child: %q", res.Stdout)
	}
}

// TestExecutor_AllowlistedParentEnvPassesThrough is the complement: a var the
// operator explicitly allowlisted IS inherited, so the allowlist genuinely
// gates rather than blocking everything.
func TestExecutor_AllowlistedParentEnvPassesThrough(t *testing.T) {
	t.Setenv("EMISAR_ALLOWED_PROBE", "visible")
	e := New()
	e.InheritEnv = append([]string{"EMISAR_ALLOWED_PROBE"}, DefaultInheritEnv...)
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/sh",
		Argv:   []string{"-c", `printf '%s' "${EMISAR_ALLOWED_PROBE}"`},
		Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.Stdout, "visible") {
		t.Fatalf("allowlisted parent env did not pass through: %q", res.Stdout)
	}
}

// TestStreamPipe_BoundsUnboundedLine: a child that emits a huge line with NO
// newline must not force streamPipe to buffer the whole line in RAM — the old
// ReadBytes('\n') accumulated the entire line before the size limit applied (an
// output-OOM vector, ×MaxConcurrentRuns). The limit still caps what's captured;
// the full stream is still counted; truncated is set.
func TestStreamPipe_BoundsUnboundedLine(t *testing.T) {
	const limit = 1024
	// Far larger than the 64 KiB read buffer, no newline — forces the bounded
	// ReadSlice/ErrBufferFull path the fix relies on.
	blob := strings.Repeat("A", 5*streamReaderBuf+7)

	res, err := streamPipe(strings.NewReader(blob), limit, StreamStdout, nil)
	if err != nil {
		t.Fatalf("streamPipe: %v", err)
	}
	if !res.truncated {
		t.Error("want truncated=true for a blob over the limit")
	}
	if len(res.captured) != limit {
		t.Errorf("captured %d bytes, want it bounded to the limit %d", len(res.captured), limit)
	}
	if res.totalBytes != len(blob) {
		t.Errorf("totalBytes %d, want the full stream %d (counted past the limit)", res.totalBytes, len(blob))
	}
}
