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
