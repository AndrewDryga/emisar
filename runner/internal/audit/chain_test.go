package audit

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeN writes n events through a fresh sink at path, returning the
// sink so callers can close + reopen it.
func writeN(t *testing.T, path string, n int) {
	t.Helper()
	s, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{AgentID: "a"}, s)
	for i := 0; i < n; i++ {
		if _, err := j.Record(context.Background(), Event{
			Type:     EventExecutionCompleted,
			ActionID: "x.do",
		}); err != nil {
			t.Fatal(err)
		}
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}
}

// TestChain_Intact verifies a fresh, unmodified JSONL passes verify.
func TestChain_Intact(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	writeN(t, path, 5)

	if err := VerifyChain(path); err != nil {
		t.Fatalf("expected intact chain, got %v", err)
	}
}

// TestChain_FirstEventHasEmptyPrevHash — the chain anchor is the empty
// string (omitempty in JSON), so re-verification of a brand-new file
// works without bootstrap state.
func TestChain_FirstEventHasEmptyPrevHash(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	writeN(t, path, 1)

	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), `"prev_hash"`) {
		t.Fatalf("first event should omit empty prev_hash, got: %s", body)
	}
}

// TestChain_DetectsByteMutation — flipping a single byte in line 1
// invalidates its hash, which invalidates line 2's prev_hash.
func TestChain_DetectsByteMutation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	writeN(t, path, 4)

	// Mutate one byte in line 1 (which has no prev_hash field, so any
	// byte change must surface on line 2's chain check).
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	firstNL := strings.IndexByte(string(body), '\n')
	if firstNL < 0 {
		t.Fatal("file has no newline")
	}
	// Replace a character well into line 1, away from braces/quotes.
	body[firstNL-5] = 'X'
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}

	err = VerifyChain(path)
	var ve *VerifyError
	if !errors.As(err, &ve) {
		t.Fatalf("expected *VerifyError, got %v", err)
	}
	if ve.Line != 2 {
		t.Fatalf("expected break on line 2, got %d", ve.Line)
	}
}

// TestChain_DetectsDeletedLine — removing an event from the middle
// of the file breaks the chain at the subsequent line.
func TestChain_DetectsDeletedLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	writeN(t, path, 4)

	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.SplitN(string(body), "\n", -1)
	// Drop line 2 (index 1). Keep the trailing empty element so SplitN
	// preserved the format.
	out := append(lines[:1], lines[2:]...)
	if err := os.WriteFile(path, []byte(strings.Join(out, "\n")), 0o600); err != nil {
		t.Fatal(err)
	}

	err = VerifyChain(path)
	var ve *VerifyError
	if !errors.As(err, &ve) {
		t.Fatalf("expected *VerifyError, got %v", err)
	}
	if ve.Line != 2 {
		t.Fatalf("expected break on line 2 (the new line 2 was originally line 3), got %d", ve.Line)
	}
}

// TestChain_ContinuesAcrossReopen — closing the sink and reopening
// the same file must NOT break the chain. The new sink seeds its
// lastHash from the existing tail.
func TestChain_ContinuesAcrossReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	writeN(t, path, 2) // first sink

	// Second sink reads tail, computes lastHash, then appends more.
	s, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{AgentID: "a"}, s)
	for i := 0; i < 2; i++ {
		if _, err := j.Record(context.Background(), Event{
			Type:     EventExecutionCompleted,
			ActionID: "x.do",
		}); err != nil {
			t.Fatal(err)
		}
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}

	if err := VerifyChain(path); err != nil {
		t.Fatalf("expected intact chain after reopen, got %v", err)
	}
}
