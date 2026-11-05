package main

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// The runner answered 1 for every failure: a mistyped flag, a misconfigured
// host, and an action that ran and failed were indistinguishable to a script —
// while emisar-mcp answered 2 for the very same mistakes, under a contract
// compatibility.md freezes explicitly. `action run` is the documented
// post-install verification step, so CI really does branch on this, and the
// runner's flat 1 would have frozen by default.
func TestExitCode(t *testing.T) {
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()

	for _, tc := range []struct {
		name string
		ctx  context.Context
		err  error
		want int
	}{
		{"work failed", context.Background(), errors.New("connect: host unreachable"), exitFailure},
		{"usage mistake", context.Background(), usageError{errors.New("unknown flag: --nope")}, exitUsage},
		{"interrupted", cancelled, errors.New("context canceled"), exitSignal},

		// A usage mistake reported while the context happens to be cancelled is
		// still the actionable one — the operator typed something wrong.
		{"usage wins over a cancelled context", cancelled,
			usageError{errors.New("unknown command \"nope\"")}, exitUsage},

		// Wrapped, because errors travel up through the command tree.
		{"wrapped usage mistake", context.Background(),
			wrapped{usageError{errors.New("accepts 1 arg(s), received 2")}}, exitUsage},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := exitCode(tc.ctx, tc.err); got != tc.want {
				t.Errorf("exitCode = %d, want %d", got, tc.want)
			}
		})
	}
}

type wrapped struct{ err error }

func (w wrapped) Error() string { return "run: " + w.err.Error() }
func (w wrapped) Unwrap() error { return w.err }

// The mistakes cobra reports as ordinary errors rather than through
// SetFlagErrorFunc still have to reach exit 2.
func TestUsageErrorFromExecute(t *testing.T) {
	usage := []string{
		`unknown command "nope" for "emisar"`,
		"unknown flag: --nope",
		"unknown shorthand flag: 'z' in -z",
		"accepts 1 arg(s), received 2",
		"requires at least 1 arg(s), only received 0",
		`required flag(s) "ca-cert" not set`,
	}
	for _, message := range usage {
		if got := exitCode(context.Background(), usageErrorFromExecute(errors.New(message))); got != exitUsage {
			t.Errorf("%q exited %d, want %d", message, got, exitUsage)
		}
	}

	// A real failure of the work must NOT be reclassified as a typo.
	work := []string{
		"connect: host unreachable",
		"pack redis: content hash mismatch",
		"process exited with code 22",
	}
	for _, message := range work {
		if got := exitCode(context.Background(), usageErrorFromExecute(errors.New(message))); got != exitFailure {
			t.Errorf("%q exited %d, want %d", message, got, exitFailure)
		}
	}
}

// `emisar --version` is the one-line MACHINE contract: install.sh compares it
// by exact string equality against "emisar version <X.Y.Z>" and dies on any
// difference. It used to ride cobra's DEFAULT template, so a library upgrade
// that reworded its own default would have broken every install at the
// verification step, with nothing in this repo changed. The format is ours now,
// and this pins the exact shape install.sh expects.
func TestVersionFlagMatchesTheInstallerContract(t *testing.T) {
	root := newRootCmd()
	var out strings.Builder
	root.SetOut(&out)
	root.SetErr(&out)
	root.SetArgs([]string{"--version"})

	if err := root.Execute(); err != nil {
		t.Fatalf("--version: %v", err)
	}
	want := "emisar version " + Version + "\n"
	if out.String() != want {
		t.Errorf("--version = %q, want %q (install.sh compares this exactly)", out.String(), want)
	}
}

// Value mistakes found inside helpers and RunE bodies are the same class as a
// mistyped flag and must exit 2 too.
func TestFlagValueMistakesAreUsageErrors(t *testing.T) {
	_, scopeErr := parseScope("env")
	_, ttlErr := parseTTL("soon")
	_, ttlNeg := parseTTL("-1h")
	_, ttlYears := parseTTL("293y")
	_, _, packSpec := resolvePackSource(context.Background(), "a=Bad Version", "")
	_, _, packName := resolvePackSource(context.Background(), "Bad Name", "")
	_, keyErr := generateSigningKey("rsa")
	for name, err := range map[string]error{
		"scope": scopeErr, "ttl": ttlErr, "ttl non-positive": ttlNeg, "ttl years": ttlYears,
		"pack spec": packSpec, "pack name": packName, "key alg": keyErr,
	} {
		if got := exitCode(context.Background(), err); got != exitUsage {
			t.Errorf("%s: exit %d, want %d (err: %v)", name, got, exitUsage, err)
		}
	}
}
