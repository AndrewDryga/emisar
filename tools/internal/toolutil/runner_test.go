package toolutil

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
)

func TestRunnerReportsOneErrorShape(t *testing.T) {
	ctx := context.Background()
	runner := &Runner{In: strings.NewReader(""), Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}

	out, err := runner.Output(ctx, "", nil, "sh", "-c", "echo hi")
	if err != nil || strings.TrimSpace(string(out)) != "hi" {
		t.Fatalf("Output = %q, %v", out, err)
	}

	// A failing child names the command line, the exit error, then its stderr.
	_, err = runner.Output(ctx, "", nil, "sh", "-c", "echo boom >&2; exit 3")
	if err == nil || !strings.HasPrefix(err.Error(), "sh -c echo boom >&2; exit 3: exit status 3: boom") {
		t.Fatalf("Output failure = %v", err)
	}

	// Whitespace-only stderr adds nothing.
	_, err = runner.Output(ctx, "", nil, "sh", "-c", "echo '  ' >&2; exit 4")
	if err == nil || !strings.HasSuffix(err.Error(), ": exit status 4") {
		t.Fatalf("whitespace stderr was appended: %v", err)
	}

	if err := runner.Run(ctx, "", nil, "sh", "-c", "exit 5"); err == nil || err.Error() != "sh -c exit 5: exit status 5" {
		t.Fatalf("Run failure = %v", err)
	}

	// A missing binary is reported as such, and a test can simulate one.
	runner.LookPath = func(string) (string, error) { return "", errors.New("nope") }
	if err := runner.Run(ctx, "", nil, "gcloud", "version"); err == nil || err.Error() != "gcloud is required but not installed" {
		t.Fatalf("missing binary = %v", err)
	}
	if _, err := runner.Output(ctx, "", nil, "gcloud"); err == nil || err.Error() != "gcloud is required but not installed" {
		t.Fatalf("missing binary (Output) = %v", err)
	}
}
