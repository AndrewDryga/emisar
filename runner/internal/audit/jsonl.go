package audit

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// JSONLSink writes one JSON-encoded event per line. It supports size-
// based rotation: when the current file exceeds MaxSizeBytes, it is
// renamed to .1, the previous .1 to .2, and so on up to MaxBackups
// (oldest dropped). Rotation is checked on every Write; the check is a
// single Stat() call so the cost is minimal.
type JSONLSink struct {
	path         string
	maxSizeBytes int64
	maxBackups   int

	mu       sync.Mutex
	f        *os.File
	lastHash string // sha256(prev line without trailing newline), hex
}

// JSONLOptions configure the sink. Zero values mean "no rotation".
type JSONLOptions struct {
	// MaxSizeBytes is the rollover threshold. <= 0 disables rotation.
	MaxSizeBytes int64
	// MaxBackups is the number of rotated files kept (.1 .. .N). <= 0
	// keeps just the active file when rotation triggers, losing history.
	// 1 means keep one backup (.1).
	MaxBackups int
}

// OpenJSONL opens (or creates) a JSONL sink at path with the given
// rotation policy. Pass JSONLOptions{} for an unrotated sink.
func OpenJSONL(path string, opts JSONLOptions) (*JSONLSink, error) {
	if path == "" {
		return nil, fmt.Errorf("audit: jsonl path is empty")
	}
	// Audit events can contain redacted-but-still-sensitive metadata
	// (action ids the model called, arg hashes, exit codes). Lock the
	// directory + file down so other users on the host can't read it.
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o750); err != nil {
			return nil, fmt.Errorf("audit: create dir: %w", err)
		}
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, fmt.Errorf("audit: open jsonl: %w", err)
	}
	sink := &JSONLSink{
		path:         path,
		maxSizeBytes: opts.MaxSizeBytes,
		maxBackups:   opts.MaxBackups,
		f:            f,
	}
	// Seed lastHash from the file so the chain continues across process
	// restarts. Empty file → empty seed → first new event has prev_hash="".
	if err := sink.seedLastHashLocked(); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("audit: seed chain: %w", err)
	}
	return sink, nil
}

// seedLastHashLocked reads the file and computes the sha256 of the last
// non-empty line. Called once at Open; mu is not yet shared so no lock
// is needed, but the name preserves the convention.
func (s *JSONLSink) seedLastHashLocked() error {
	f, err := os.Open(s.path)
	if err != nil {
		return err
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1<<20)
	var lastLine []byte
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		// Copy — Scanner reuses its buffer.
		lastLine = append(lastLine[:0], line...)
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if len(lastLine) > 0 {
		h := sha256.Sum256(lastLine)
		s.lastHash = hex.EncodeToString(h[:])
	}
	return nil
}

// Write appends one JSON-encoded event followed by a newline, rotating
// the file first if it has exceeded MaxSizeBytes. The event's PrevHash
// is overwritten with the chain head before marshalling — callers don't
// need to set it.
func (s *JSONLSink) Write(_ context.Context, ev Event) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	ev.PrevHash = s.lastHash

	b, err := json.Marshal(ev)
	if err != nil {
		return err
	}

	line := make([]byte, len(b)+1)
	copy(line, b)
	line[len(b)] = '\n'

	if err := s.maybeRotateLocked(int64(len(line))); err != nil {
		return err
	}
	// Defensive: rotation can land in a state where the active file
	// failed to reopen (disk full, perms). maybeRotateLocked returns
	// an error in that case but if a future change ever loses that
	// path, a nil-deref here would panic the runner goroutine.
	if s.f == nil {
		return fmt.Errorf("audit: jsonl sink has no active file")
	}
	if _, err := s.f.Write(line); err != nil {
		return err
	}

	// Chain advances only after the bytes are durably appended. If the
	// Write above had failed, lastHash stays put and the next attempt
	// chains from the same point.
	h := sha256.Sum256(b)
	s.lastHash = hex.EncodeToString(h[:])
	return nil
}

// maybeRotateLocked rotates the file when the next write would cross
// the size threshold. Caller must hold s.mu.
func (s *JSONLSink) maybeRotateLocked(incoming int64) error {
	if s.maxSizeBytes <= 0 || s.f == nil {
		return nil
	}
	info, err := s.f.Stat()
	if err != nil {
		return err
	}
	if info.Size()+incoming < s.maxSizeBytes {
		return nil
	}
	if err := s.f.Close(); err != nil {
		// Best-effort: log path failure but continue rotating.
		s.f = nil
	}
	// Shift .N-1 -> .N, .N-2 -> .N-1, ..., active -> .1.
	// The oldest (.MaxBackups) is overwritten.
	for i := s.maxBackups; i > 1; i-- {
		from := fmt.Sprintf("%s.%d", s.path, i-1)
		to := fmt.Sprintf("%s.%d", s.path, i)
		_ = os.Rename(from, to)
	}
	if s.maxBackups >= 1 {
		_ = os.Rename(s.path, s.path+".1")
	} else {
		// No backups requested: just discard the old file.
		_ = os.Remove(s.path)
	}
	// Reopen a fresh active file. Mode matches the initial open at
	// line 55 — 0o600 (owner-only). Don't downgrade to 0o644 on
	// rotation: the audit log can contain redacted-but-still-sensitive
	// metadata and must not become world-readable mid-life.
	f, err := os.OpenFile(s.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("audit: reopen jsonl after rotation: %w", err)
	}
	s.f = f
	return nil
}

// VerifyError describes the first break in a JSONL audit chain.
type VerifyError struct {
	// Line (1-indexed) where the break was detected. The break is in this
	// event's prev_hash field — either the file content above this point
	// was mutated, or this event was inserted out of order.
	Line int
	// EventID of the broken entry, for cross-referencing audit search.
	EventID string
	// What the chain expected this event's prev_hash to be.
	Expected string
	// What the event actually carried.
	Got string
}

func (e *VerifyError) Error() string {
	return fmt.Sprintf("audit: chain break at line %d (event %s): expected prev_hash=%s, got %s",
		e.Line, e.EventID, e.Expected, e.Got)
}

// VerifyChain re-derives the prev_hash chain from path and returns nil
// if every event correctly chains from the previous serialized line.
// On the first break it returns a *VerifyError pointing at the offending
// line. Use VerifyReader to plug into a non-file source (e.g., piped
// from gzip or a test buffer).
func VerifyChain(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return VerifyReader(f)
}

// VerifyReader is the io.Reader form of VerifyChain. Skips empty lines.
func VerifyReader(r io.Reader) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 1<<20)

	var expected string
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var probe struct {
			EventID  string `json:"event_id"`
			PrevHash string `json:"prev_hash"`
		}
		if err := json.Unmarshal(line, &probe); err != nil {
			return fmt.Errorf("audit: line %d: parse: %w", lineNo, err)
		}
		if probe.PrevHash != expected {
			return &VerifyError{
				Line: lineNo, EventID: probe.EventID,
				Expected: expected, Got: probe.PrevHash,
			}
		}
		h := sha256.Sum256(line)
		expected = hex.EncodeToString(h[:])
	}
	return scanner.Err()
}

// Close closes the underlying file.
func (s *JSONLSink) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.f != nil {
		err := s.f.Close()
		s.f = nil
		return err
	}
	return nil
}
