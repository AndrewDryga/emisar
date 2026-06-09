package redact

import (
	"bytes"
	"strings"
)

// defaultStreamHold is how many trailing raw bytes a StreamRedactor keeps
// buffered before committing earlier bytes. It bounds the longest multi-line
// secret that streaming redaction is guaranteed to catch: any rule match no
// longer than this is always fully present in the buffer before the lines it
// spans become eligible to emit. 16 KiB comfortably covers PEM/PGP private-key
// blocks (a few KiB even at RSA-4096) with room to spare.
const defaultStreamHold = 16 << 10

// StreamRedactor applies an Engine's rules to output delivered in arbitrary
// chunks (e.g. line-by-line from a child process) while preserving the
// multi-line guarantee of whole-buffer redaction.
//
// The problem it solves: a rule like the PEM private-key block matches across
// many lines (`-----BEGIN…-----END…`). Redacting each chunk independently — as
// a naive streaming path does — never sees the whole block, so the opening
// lines of a private key are emitted before the closing line arrives, leaking
// the secret onto the wire (and, because the cloud assembles stored output
// from these very chunks, into the permanent run record).
//
// StreamRedactor holds back a bounded tail and only commits a prefix once
// redacting that prefix standalone yields a stable prefix of redacting the
// whole buffer — so a multi-line match is never split across the emit
// boundary. Matches longer than the hold window can still leak on the live
// stream; that bound is deliberate (unbounded buffering is the only
// alternative) and sized so realistic key material is always covered.
//
// A StreamRedactor is not safe for concurrent use; callers that redact stdout
// and stderr from separate goroutines must use one instance per stream (or
// serialize access).
type StreamRedactor struct {
	eng     *Engine
	pending []byte
	hold    int
	hits    []Hit
}

// StreamRedactor returns a stateful redactor over e's rules. Feed it raw
// chunks with Write and drain the tail with Flush at end of stream.
func (e *Engine) StreamRedactor() *StreamRedactor {
	return &StreamRedactor{eng: e, hold: defaultStreamHold}
}

// Write feeds the next raw chunk and returns the bytes that are now safe to
// emit, fully redacted. Bytes that might still be part of an in-progress
// multi-line match are retained until a later Write or Flush. The returned
// slice is freshly allocated and owned by the caller.
func (s *StreamRedactor) Write(p []byte) []byte {
	s.pending = append(s.pending, p...)
	return s.commit(false)
}

// Flush redacts and returns everything still buffered. Call exactly once at
// end of stream; do not Write afterwards.
func (s *StreamRedactor) Flush() []byte {
	return s.commit(true)
}

// Hits reports the cumulative per-rule hit counts across every committed
// (and flushed) segment. Valid to read after Flush.
func (s *StreamRedactor) Hits() []Hit { return s.hits }

func (s *StreamRedactor) commit(flush bool) []byte {
	if len(s.pending) == 0 {
		return nil
	}
	if flush {
		out, hits := s.eng.Apply(string(s.pending))
		s.hits = MergeHits(s.hits, hits)
		s.pending = nil
		return []byte(out)
	}
	// Keep at least `hold` raw bytes buffered. This guarantees that by the
	// time a line becomes eligible to emit, enough following bytes have
	// arrived that any multi-line match no longer than `hold` which started
	// at or before that line has already closed inside the buffer.
	if len(s.pending) <= s.hold {
		return nil
	}
	// Cut on a line boundary within the committable region. Emitting partial
	// lines would risk splitting a single-line match mid-token.
	cut := indexAfterLastNewline(s.pending, len(s.pending)-s.hold)
	if cut == 0 {
		return nil
	}
	// Soundness gate: redacting the prefix standalone must produce a stable
	// prefix of redacting the whole buffer. If it doesn't, the cut splits a
	// match that has already closed further along — hold and wait for the cut
	// to advance past the whole match on a later chunk.
	fullRed, _ := s.eng.Apply(string(s.pending))
	segRed, hits := s.eng.Apply(string(s.pending[:cut]))
	if !strings.HasPrefix(fullRed, segRed) {
		return nil
	}
	s.hits = MergeHits(s.hits, hits)
	rest := make([]byte, len(s.pending)-cut)
	copy(rest, s.pending[cut:])
	s.pending = rest
	return []byte(segRed)
}

// indexAfterLastNewline returns the index just past the last '\n' that occurs
// before limit, or 0 if there is no newline in b[:limit].
func indexAfterLastNewline(b []byte, limit int) int {
	if limit > len(b) {
		limit = len(b)
	}
	if limit <= 0 {
		return 0
	}
	nl := bytes.LastIndexByte(b[:limit], '\n')
	if nl < 0 {
		return 0
	}
	return nl + 1
}
