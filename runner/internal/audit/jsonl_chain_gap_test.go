package audit

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// This file closes the PHASE-2 "gap" rows for RSEC-012 (audit JSONL
// hash-chain) that the existing jsonl_chain_test.go / journal_test.go do not
// already assert. The chain's threat model is documented in event.go and
// jsonl.go: byte mutation / reorder / mid-file deletion ARE caught; tail
// truncation and a wholesale consistent rewrite are NOT (no external anchor —
// the cloud is the system of record). These tests lock both halves in.

// TestChain_DetectsReordering (RSEC-012-T07) — swapping two adjacent lines
// breaks the chain: each event's prev_hash is bound to the *bytes* of the
// line before it, so a reorder leaves the first swapped line carrying a
// prev_hash that no longer matches its new predecessor.
func TestChain_DetectsReordering(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	writeN(t, path, 4)

	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
	if len(lines) != 4 {
		t.Fatalf("setup: expected 4 lines, got %d", len(lines))
	}
	// Swap lines 2 and 3 (indices 1 and 2). Line 1 still anchors at "" so the
	// break surfaces on the first out-of-place line: the new line 2.
	lines[1], lines[2] = lines[2], lines[1]
	out := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(path, []byte(out), 0o600); err != nil {
		t.Fatal(err)
	}

	err = VerifyChain(path)
	var ve *VerifyError
	if !errors.As(err, &ve) {
		t.Fatalf("expected *VerifyError from a reordered chain, got %v", err)
	}
	if ve.Line != 2 {
		t.Fatalf("expected break on line 2 (first swapped line), got %d", ve.Line)
	}
}

// TestChain_ConsistentRewriteNotDetected (RSEC-012-T09) — a forger who drops
// an event and then RE-CHAINS the whole file from scratch produces an
// internally consistent chain that VerifyChain cannot flag. This is the same
// accepted limitation as tail truncation (TestChain_TailTruncationIsNotDetected):
// detection covers in-place tamper, not a wholesale rewrite, because the chain
// has no external anchor. Locked in so a change that claims otherwise fails here.
func TestChain_ConsistentRewriteNotDetected(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	writeN(t, path, 5)

	// Drop the middle event, then re-chain everything that remains through a
	// fresh sink writing to a new file. The result is a valid 4-event chain.
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
	if len(lines) != 5 {
		t.Fatalf("setup: expected 5 lines, got %d", len(lines))
	}

	rewritten := filepath.Join(t.TempDir(), "rewritten.jsonl")
	s, err := OpenJSONL(rewritten, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{}, s)
	for i, raw := range lines {
		if i == 2 {
			continue // the dropped event
		}
		var ev Event
		if err := json.Unmarshal([]byte(raw), &ev); err != nil {
			t.Fatal(err)
		}
		// Clear PrevHash so the sink re-stamps it as the rewritten chain head.
		ev.PrevHash = ""
		if _, err := j.Record(context.Background(), ev); err != nil {
			t.Fatal(err)
		}
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}

	if err := VerifyChain(rewritten); err != nil {
		t.Fatalf("a consistently re-chained file is undetectable by design; "+
			"VerifyChain should return nil, got %v", err)
	}
}

// TestVerifyReader_MatchesVerifyChain (RSEC-012-T17) — the io.Reader form must
// reach the identical verdict (and the identical break point) as the path form
// on the same bytes, so `audit verify` can read from gzip / a pipe / a buffer.
func TestVerifyReader_MatchesVerifyChain(t *testing.T) {
	t.Run("intact: both pass", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "events.jsonl")
		writeN(t, path, 4)

		if err := VerifyChain(path); err != nil {
			t.Fatalf("VerifyChain on intact file: %v", err)
		}
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := VerifyReader(strings.NewReader(string(body))); err != nil {
			t.Fatalf("VerifyReader on intact bytes should match (nil), got %v", err)
		}
	})

	t.Run("tampered: same break line", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "events.jsonl")
		writeN(t, path, 4)

		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		firstNL := strings.IndexByte(string(body), '\n')
		if firstNL < 0 {
			t.Fatal("file has no newline")
		}
		body[firstNL-5] = 'X' // mutate line 1, surfaces on line 2's prev_hash

		var fromChain, fromReader *VerifyError
		if err := os.WriteFile(path, body, 0o600); err != nil {
			t.Fatal(err)
		}
		if !errors.As(VerifyChain(path), &fromChain) {
			t.Fatalf("VerifyChain should report *VerifyError on the mutated file")
		}
		if !errors.As(VerifyReader(strings.NewReader(string(body))), &fromReader) {
			t.Fatalf("VerifyReader should report *VerifyError on the mutated bytes")
		}
		if fromChain.Line != fromReader.Line {
			t.Fatalf("reader/path disagree on break line: chain=%d reader=%d",
				fromChain.Line, fromReader.Line)
		}
	})
}

// TestChain_LastHashHoldsWhenWriteFails (RSEC-012-T04) — the chain head
// (lastHash) advances ONLY after the line is durably on disk. jsonl.go:191-196
// computes the new head after s.f.Write + s.f.Sync both succeed; a failure at
// either leaves lastHash untouched, so the next attempt re-chains from the same
// point rather than leaving a gap a verifier would read as tamper. This forces a
// real Write failure by closing the sink's underlying file out from under it
// (the file handle is the only seam needed — no production change): a write to a
// closed *os.File errors, exercising the early-return at jsonl.go:176-178 before
// the head advances. The proof is end-to-end: after the failed write, the chain
// head equals the last DURABLE line's hash, and a fresh sink (re-seeding from the
// file) continues the chain with no gap, so VerifyChain still passes.
func TestChain_LastHashHoldsWhenWriteFails(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	s, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}

	// One event lands durably; the chain head advances to its hash.
	if err := s.Write(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.do", EventID: "evt_1"}); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	headAfterFirst := s.lastHash
	s.mu.Unlock()
	if headAfterFirst == "" {
		t.Fatal("setup: chain head should have advanced after the first durable write")
	}

	// Force the NEXT write to fail at the os.File.Write stage by closing the
	// underlying handle. s.f stays non-nil (so the nil-guard passes) but is
	// closed, so Write returns an error before lastHash is recomputed.
	s.mu.Lock()
	if err := s.f.Close(); err != nil {
		s.mu.Unlock()
		t.Fatalf("closing the underlying file for the failure-injection: %v", err)
	}
	s.mu.Unlock()

	if err := s.Write(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.do", EventID: "evt_2"}); err == nil {
		t.Fatal("expected Write to fail against the closed file handle")
	}

	// The head must NOT have advanced — a failed write leaves the chain anchored
	// at the last durable line, so there is no gap to re-chain over.
	s.mu.Lock()
	headAfterFail := s.lastHash
	s.mu.Unlock()
	if headAfterFail != headAfterFirst {
		t.Fatalf("chain head advanced on a failed write: %q -> %q (a failed write must not move lastHash)",
			headAfterFirst, headAfterFail)
	}

	// And the durable file holds exactly the one event that actually synced — the
	// failed event left no bytes — so a reopened sink re-chains cleanly from it.
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(strings.TrimRight(string(body), "\n"), "\n") + 1; got != 1 {
		t.Fatalf("durable file should hold exactly the one synced event, has %d lines:\n%s", got, body)
	}
	if strings.Contains(string(body), "evt_2") {
		t.Fatal("the failed write must not have left its bytes on disk")
	}

	// Reopen: the fresh sink seeds its head from the durable file and the next
	// event chains straight on, with VerifyChain passing — proving the held head
	// produced a continuous chain, not a gap.
	s2, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := New(Defaults{}, s2).Record(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.do", EventID: "evt_3"}); err != nil {
		t.Fatal(err)
	}
	if err := s2.Close(); err != nil {
		t.Fatal(err)
	}
	if err := VerifyChain(path); err != nil {
		t.Fatalf("chain must stay continuous across a failed write + reopen, got %v", err)
	}
}

// BenchmarkChainWrite (RSEC-012-T18) — per-event chain write cost, dominated by
// the fsync in JSONLSink.Write. Establishes a throughput baseline; growth here
// flags a regression in the hot append path.
func BenchmarkChainWrite(b *testing.B) {
	path := filepath.Join(b.TempDir(), "events.jsonl")
	s, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		b.Fatal(err)
	}
	defer s.Close()
	ev := Event{Type: EventExecutionCompleted, ActionID: "x.do", EventID: "evt_bench"}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := s.Write(context.Background(), ev); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkVerifyChain (RSEC-012-T19) — VerifyChain is a linear scan with one
// sha256 per line; this measures verify cost over a fixed-size journal.
func BenchmarkVerifyChain(b *testing.B) {
	path := filepath.Join(b.TempDir(), "events.jsonl")
	s, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		b.Fatal(err)
	}
	for i := 0; i < 1000; i++ {
		if err := s.Write(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.do"}); err != nil {
			b.Fatal(err)
		}
	}
	if err := s.Close(); err != nil {
		b.Fatal(err)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := VerifyChain(path); err != nil {
			b.Fatal(err)
		}
	}
}
