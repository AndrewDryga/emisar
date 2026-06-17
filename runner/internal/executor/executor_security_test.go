package executor

import (
	"context"
	"strings"
	"testing"
	"time"
)

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
