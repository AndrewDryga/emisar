package executor

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestExecutor_SuccessfulExec(t *testing.T) {
	e := New()
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/echo",
		Argv:   []string{"hello", "world"},
		Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusOK || res.ExitCode != 0 {
		t.Fatalf("status=%s exit=%d", res.Status, res.ExitCode)
	}
	if !strings.Contains(res.Stdout, "hello world") {
		t.Fatalf("stdout: %q", res.Stdout)
	}
}

func TestExecutor_NonZeroExit(t *testing.T) {
	e := New()
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/sh",
		Argv:   []string{"-c", "exit 7"},
		Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != StatusNonZero || res.ExitCode != 7 {
		t.Fatalf("status=%s exit=%d", res.Status, res.ExitCode)
	}
}

func TestExecutor_Timeout(t *testing.T) {
	e := New()
	start := time.Now()
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/sh",
		Argv:   []string{"-c", "sleep 5"},
		Limits: Limits{Timeout: 200 * time.Millisecond, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !res.TimedOut {
		t.Fatalf("expected timed out, status=%s", res.Status)
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("waited too long: %s", elapsed)
	}
}

func TestExecutor_StdoutLimit(t *testing.T) {
	e := New()
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/sh",
		Argv:   []string{"-c", "printf '%s' AAAAAAAAAA"},
		Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 3, MaxStderrBytes: 1024},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Stdout) != 3 {
		t.Fatalf("stdout len=%d (want 3): %q", len(res.Stdout), res.Stdout)
	}
	if !res.Truncated.Stdout {
		t.Fatal("expected stdout truncated flag")
	}
	if res.StdoutBytes < 10 {
		t.Fatalf("StdoutBytes (total seen) should reflect 10, got %d", res.StdoutBytes)
	}
}

func TestExecutor_StderrCaptured(t *testing.T) {
	e := New()
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/sh",
		Argv:   []string{"-c", "echo whoops 1>&2; exit 1"},
		Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.Stderr, "whoops") {
		t.Fatalf("stderr: %q", res.Stderr)
	}
}

func TestExecutor_DoesNotUseShell(t *testing.T) {
	// Confirm a "shell metacharacter" argv element is passed literally, not
	// interpreted by a shell.
	e := New()
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/echo",
		Argv:   []string{"$HOME && rm -rf /"},
		Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.Stdout, "$HOME && rm -rf /") {
		t.Fatalf("stdout should contain the literal argv element; got %q", res.Stdout)
	}
}

func TestExecutor_ExplicitEnvWins(t *testing.T) {
	e := New()
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/sh",
		Argv:   []string{"-c", "echo $X"},
		Env:    map[string]string{"X": "yes"},
		Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.Stdout, "yes") {
		t.Fatalf("env not honoured: %q", res.Stdout)
	}
}

func TestExecutor_StreamingChunks(t *testing.T) {
	var (
		mu     sync.Mutex
		chunks []string
	)
	e := New()
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/sh",
		Argv:   []string{"-c", "printf 'one\\ntwo\\nthree\\n'"},
		Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
		OnChunk: func(s Stream, data []byte) {
			if s != StreamStdout {
				return
			}
			mu.Lock()
			defer mu.Unlock()
			chunks = append(chunks, string(data))
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Stdout != "" {
		t.Fatalf("streaming mode should not also capture stdout, got %q", res.Stdout)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(chunks) != 3 {
		t.Fatalf("expected 3 lines, got %d: %v", len(chunks), chunks)
	}
	if chunks[0] != "one\n" || chunks[1] != "two\n" || chunks[2] != "three\n" {
		t.Fatalf("chunks: %v", chunks)
	}
	if res.StdoutBytes != 14 { // "one\n" + "two\n" + "three\n"
		t.Fatalf("StdoutBytes = %d", res.StdoutBytes)
	}
	if res.StdoutSHA256 == "" {
		t.Fatal("StdoutSHA256 should be set even when streaming")
	}
}

func TestExecutor_GracefulCancelSIGTERMThenSIGKILL(t *testing.T) {
	// A shell trap on SIGTERM that lets us observe the graceful path:
	// the process exits cleanly with code 42 in response to SIGTERM,
	// well before the 5s WaitDelay.
	//
	// Timing tolerances are intentionally generous (10s upper bound) to
	// survive heavily-loaded CI runners. The point is that SIGTERM is
	// honored — not that it lands within X ms.
	e := New()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(200 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	res, err := e.Execute(ctx, Plan{
		Binary: "/bin/sh",
		Argv: []string{"-c",
			`trap 'exit 42' TERM; while true; do sleep 0.05; done`},
		Limits:      Limits{Timeout: 30 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
		CancelGrace: 5 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	elapsed := time.Since(start)
	// Must exit well before the 30s action timeout — that's the real
	// behaviour we care about. Use a wide window for CI tolerance.
	if elapsed > 10*time.Second {
		t.Fatalf("took too long (%s) — graceful cancel may not have worked", elapsed)
	}
	if res.ExitCode != 42 {
		t.Fatalf("expected trap exit 42, got %d (status=%s start_err=%q)",
			res.ExitCode, res.Status, res.StartError)
	}
}

func TestExecutor_HardKillAfterGracePeriod(t *testing.T) {
	// Trap SIGTERM but never exit; SIGKILL must arrive after CancelGrace.
	// Tolerances are wide enough to survive a slow CI runner: grace=1s,
	// upper-bound deadline=10s.
	e := New()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(200 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	res, err := e.Execute(ctx, Plan{
		Binary: "/bin/sh",
		Argv: []string{"-c",
			`trap '' TERM; while true; do sleep 0.05; done`},
		Limits:      Limits{Timeout: 30 * time.Second, MaxStdoutBytes: 1024, MaxStderrBytes: 1024},
		CancelGrace: 1 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	elapsed := time.Since(start)
	if elapsed > 10*time.Second {
		t.Fatalf("hard kill took too long: %s", elapsed)
	}
	// SIGKILL must have happened — the trap couldn't keep it alive.
	if res.Status == StatusOK {
		t.Fatalf("a SIGKILLed process must not report StatusOK")
	}
}

func TestExecutor_StreamingTruncatesAtLimit(t *testing.T) {
	var chunks []string
	e := New()
	res, err := e.Execute(context.Background(), Plan{
		Binary: "/bin/sh",
		Argv:   []string{"-c", "printf 'aaaaaaaaaa'"},
		Limits: Limits{Timeout: 5 * time.Second, MaxStdoutBytes: 3, MaxStderrBytes: 1024},
		OnChunk: func(_ Stream, data []byte) {
			chunks = append(chunks, string(data))
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(chunks, "")
	if got != "aaa" {
		t.Fatalf("streamed bytes: %q", got)
	}
	if !res.Truncated.Stdout {
		t.Fatal("expected truncated flag")
	}
	if res.StdoutBytes != 10 {
		t.Fatalf("StdoutBytes should reflect full output, got %d", res.StdoutBytes)
	}
}

func TestAllowInheritEnv_ExtendsDefaultsAndDedups(t *testing.T) {
	e := New()
	e.AllowInheritEnv("NOMAD_ADDR", "NOMAD_TOKEN", "PATH", "")

	has := func(k string) bool {
		for _, v := range e.InheritEnv {
			if v == k {
				return true
			}
		}
		return false
	}
	count := func(k string) int {
		n := 0
		for _, v := range e.InheritEnv {
			if v == k {
				n++
			}
		}
		return n
	}

	// Adding a var must NOT drop the always-on defaults (the PATH footgun).
	for _, d := range DefaultInheritEnv {
		if !has(d) {
			t.Errorf("default %q dropped from inherit list: %v", d, e.InheritEnv)
		}
	}
	// Configured vars are added; a duplicate of a default isn't repeated; the
	// empty name is ignored.
	if !has("NOMAD_ADDR") || !has("NOMAD_TOKEN") {
		t.Errorf("configured vars missing: %v", e.InheritEnv)
	}
	if count("PATH") != 1 {
		t.Errorf("PATH should appear once, got %d: %v", count("PATH"), e.InheritEnv)
	}
	if has("") {
		t.Errorf("empty var name should be filtered: %v", e.InheritEnv)
	}

	// New() copies DefaultInheritEnv, so none of this mutates the global.
	if len(DefaultInheritEnv) != 4 {
		t.Errorf("DefaultInheritEnv was mutated: %v", DefaultInheritEnv)
	}
}
