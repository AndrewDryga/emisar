package audit

import (
	"context"
	"errors"
	"fmt"
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

// TestChain_RotationProducesSelfContainedFiles — after size rotation, the
// active file AND every rotated sibling (.1, .2, …) must each verify as an
// intact, self-contained chain whose first line starts fresh (no
// prev_hash). Regression for the bug where the rotated-into file's first
// line carried a backward prev_hash to the rotated-away file, which
// VerifyChain (per-file, expecting "" at the start) flagged as tampering —
// false-alarming `emisar audit verify` on every rotated log.
func TestChain_RotationProducesSelfContainedFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	// Small threshold so several rotations happen across the writes.
	s, err := OpenJSONL(path, JSONLOptions{MaxSizeBytes: 300, MaxBackups: 20})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{AgentID: "a"}, s)
	for i := 0; i < 30; i++ {
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

	files := []string{path}
	for i := 1; ; i++ {
		p := fmt.Sprintf("%s.%d", path, i)
		if _, err := os.Stat(p); err != nil {
			break
		}
		files = append(files, p)
	}
	if len(files) < 2 {
		t.Fatalf("expected rotation to produce sibling files, got only %v", files)
	}
	for _, p := range files {
		if err := VerifyChain(p); err != nil {
			t.Fatalf("%s must be a self-contained chain, got %v", p, err)
		}
		body, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		first := strings.SplitN(string(body), "\n", 2)[0]
		if first == "" {
			continue
		}
		if strings.Contains(first, `"prev_hash"`) {
			t.Fatalf("%s first line must start a fresh chain (no prev_hash), got: %s", p, first)
		}
	}
}

// TestChain_TailTruncationIsNotDetected documents a deliberate limitation
// of the threat model: the chain has no external anchor (the cloud is the
// system of record), so dropping events off the END yields a shorter but
// still internally consistent chain that VerifyChain cannot flag. In-place
// edits, mid-file deletes, and reorders ARE caught (tests above); tail
// truncation and whole-file rewrite are not. This is intentional — locking
// it in so a future change that claims otherwise gets a failing test here.
func TestChain_TailTruncationIsNotDetected(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	writeN(t, path, 5)

	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
	if len(lines) != 5 {
		t.Fatalf("setup: expected 5 lines, got %d", len(lines))
	}
	// Drop the two most recent events.
	kept := strings.Join(lines[:3], "\n") + "\n"
	if err := os.WriteFile(path, []byte(kept), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := VerifyChain(path); err != nil {
		t.Fatalf("tail-truncated chain stays internally valid by design; "+
			"VerifyChain should return nil, got %v", err)
	}
}
