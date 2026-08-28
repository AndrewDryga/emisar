package main

import (
	"context"
	"errors"
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
		"requires exactly 2 arg(s)",
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
