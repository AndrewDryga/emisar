package signing

import (
	"bufio"
	"bytes"
	"container/heap"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

const (
	nonceJournalVersion  = 1
	defaultMaxNonces     = 100_000
	defaultMaxJournal    = int64(16 * 1024 * 1024)
	defaultCompactAfter  = 1_024
	maxNonceRecordBytes  = 256
	maxNonceJournalLines = 200_001 // header + at most two generations of records
)

type nonceJournalHeader struct {
	Version     int   `json:"version"`
	RetentionNS int64 `json:"retention_ns"`
}

type nonceJournalRecord struct {
	Nonce    string `json:"nonce"`
	IssuedAt string `json:"issued_at"`
}

type nonceExpiry struct {
	nonce  string
	issued time.Time
}

type expiryQueue []nonceExpiry

func (q expiryQueue) Len() int { return len(q) }
func (q expiryQueue) Less(i, j int) bool {
	if q[i].issued.Equal(q[j].issued) {
		return q[i].nonce < q[j].nonce
	}
	return q[i].issued.Before(q[j].issued)
}
func (q expiryQueue) Swap(i, j int)   { q[i], q[j] = q[j], q[i] }
func (q *expiryQueue) Push(value any) { *q = append(*q, value.(nonceExpiry)) }
func (q *expiryQueue) Pop() any {
	old := *q
	last := old[len(old)-1]
	*q = old[:len(old)-1]
	return last
}

// NonceStore owns replay state independently of replaceable verifier policy.
// A durable store appends and fsyncs one bounded JSON record before admitting a
// dispatch. Expired records are removed from memory with a heap and periodically
// compacted through a synced temp-file rename, so ordinary dispatch cost does
// not grow with the journal.
type NonceStore struct {
	mu sync.Mutex

	path      string
	lock      *nonceJournalLock
	retention time.Duration
	seen      map[string]time.Time
	expiry    expiryQueue
	fileSize  int64
	obsolete  int
	failed    error

	maxEntries   int
	maxBytes     int64
	compactAfter int
}

// OpenNonceStore opens or creates the durable replay journal. The retention
// horizon is written once and may not later be widened: compaction is allowed to
// discard anything older than that horizon, so widening it could make a pruned
// attestation fresh again without its nonce record. The prior bounded JSON-map
// format is migrated atomically while preserving every still-live nonce.
func OpenNonceStore(path string, maxAge time.Duration) (*NonceStore, error) {
	if path == "" {
		return nil, fmt.Errorf("signing: nonce journal path is required")
	}
	if maxAge <= 0 {
		return nil, fmt.Errorf("signing: max attestation age must be positive")
	}

	store := &NonceStore{
		path:         path,
		retention:    maxAge,
		seen:         make(map[string]time.Time),
		maxEntries:   defaultMaxNonces,
		maxBytes:     defaultMaxJournal,
		compactAfter: defaultCompactAfter,
	}
	dir := filepath.Dir(path)
	if err := fsutil.SecureMkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("signing: create nonce-journal dir: %w", err)
	}
	journalLock, err := acquireNonceJournalLock(path + ".lock")
	if err != nil {
		return nil, fmt.Errorf("signing: lock nonce journal %q: %w", path, err)
	}
	store.lock = journalLock
	opened := false
	defer func() {
		if !opened {
			_ = journalLock.Close()
		}
	}()

	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		if err := store.rewriteLocked(); err != nil {
			return nil, err
		}
		opened = true
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("signing: stat nonce journal %q: %w", path, err)
	}
	if info.Size() > store.maxBytes {
		return nil, fmt.Errorf("signing: nonce journal %q is %d bytes, limit %d", path, info.Size(), store.maxBytes)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("signing: read nonce journal %q: %w", path, err)
	}

	migrated, err := store.load(raw, time.Now())
	if err != nil {
		return nil, fmt.Errorf("signing: nonce journal %q is corrupt: %w", path, err)
	}
	if maxAge > store.retention {
		return nil, fmt.Errorf(
			"signing: max attestation age %s exceeds nonce journal retention %s; keep the old value or rotate trusted CAs before resetting replay state",
			maxAge, store.retention,
		)
	}
	store.fileSize = info.Size()
	heap.Init(&store.expiry)
	if migrated || store.obsolete > 0 {
		if err := store.rewriteLocked(); err != nil {
			return nil, err
		}
	}
	opened = true
	return store, nil
}

// NewMemoryNonceStore is for unit tests and explicitly non-durable callers.
// Production signature enforcement rejects a memory-only store before use.
func NewMemoryNonceStore() *NonceStore {
	return &NonceStore{
		seen:         make(map[string]time.Time),
		maxEntries:   defaultMaxNonces,
		maxBytes:     defaultMaxJournal,
		compactAfter: defaultCompactAfter,
	}
}

// Durable reports whether accepted nonces are crash-durably journaled.
func (s *NonceStore) Durable() bool { return s != nil && s.path != "" }

// Close releases the process-lifetime journal lock. The connect command owns
// the store and closes it only after every verifier and dispatch goroutine has
// stopped. Memory-only test stores have no lock and Close is a no-op.
func (s *NonceStore) Close() error {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lock == nil {
		return nil
	}
	err := s.lock.Close()
	s.lock = nil
	return err
}

// bindRetention binds a process-local store on its first enforcing verifier and
// rejects any later widening. A durable store is already bound by its header.
func (s *NonceStore) bindRetention(maxAge time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if maxAge <= 0 {
		return fmt.Errorf("signing: max attestation age must be positive")
	}
	if s.retention == 0 {
		s.retention = maxAge
		return nil
	}
	if maxAge > s.retention {
		return fmt.Errorf(
			"signing: max attestation age %s exceeds nonce retention %s; rotate trusted CAs before resetting replay state",
			maxAge, s.retention,
		)
	}
	return nil
}

// consume durably records nonce, or reports that it remains inside the replay
// horizon. Persistence completes before the live map changes. Once persistence
// becomes ambiguous the store latches closed for the process lifetime.
func (s *NonceStore) consume(nonce string, issued, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failed != nil {
		return false, fmt.Errorf("signing: nonce journal previously failed: %w", s.failed)
	}
	if s.retention <= 0 {
		return false, fmt.Errorf("signing: nonce retention is not bound")
	}

	s.pruneLocked(now.Add(-s.retention))
	if _, used := s.seen[nonce]; used {
		return false, nil
	}
	if s.path != "" && s.shouldCompactLocked() {
		if err := s.rewriteLocked(); err != nil {
			return false, s.latchLocked(err)
		}
	}
	if len(s.seen) >= s.maxEntries {
		return false, fmt.Errorf("signing: nonce journal has %d fresh entries, limit %d", len(s.seen), s.maxEntries)
	}

	record := nonceJournalRecord{Nonce: nonce, IssuedAt: issued.Format(time.RFC3339Nano)}
	line, err := json.Marshal(record)
	if err != nil {
		return false, fmt.Errorf("signing: marshal nonce record: %w", err)
	}
	line = append(line, '\n')
	if int64(len(line))+s.fileSize > s.maxBytes && s.path != "" {
		if err := s.rewriteLocked(); err != nil {
			return false, s.latchLocked(err)
		}
		if int64(len(line))+s.fileSize > s.maxBytes {
			return false, fmt.Errorf("signing: nonce journal would exceed %d bytes", s.maxBytes)
		}
	}
	if s.path != "" {
		if err := s.appendLocked(line); err != nil {
			return false, s.latchLocked(err)
		}
	}
	s.seen[nonce] = issued
	heap.Push(&s.expiry, nonceExpiry{nonce: nonce, issued: issued})
	return true, nil
}

func (s *NonceStore) latchLocked(err error) error {
	s.failed = err
	return err
}

func (s *NonceStore) pruneLocked(cutoff time.Time) {
	for s.expiry.Len() > 0 && s.expiry[0].issued.Before(cutoff) {
		expired := heap.Pop(&s.expiry).(nonceExpiry)
		if issued, ok := s.seen[expired.nonce]; ok && issued.Equal(expired.issued) {
			delete(s.seen, expired.nonce)
			s.obsolete++
		}
	}
}

func (s *NonceStore) shouldCompactLocked() bool {
	return s.obsolete >= s.compactAfter && s.obsolete >= len(s.seen)
}

// load returns true for the legacy JSON-map format, which must be rewritten as
// a journal before OpenNonceStore returns.
func (s *NonceStore) load(raw []byte, now time.Time) (bool, error) {
	if len(raw) == 0 {
		return false, fmt.Errorf("empty file")
	}
	firstLine := raw
	if newline := bytes.IndexByte(raw, '\n'); newline >= 0 {
		firstLine = raw[:newline]
	}
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(firstLine, &probe); err != nil {
		return false, err
	}
	if _, journal := probe["version"]; !journal {
		if err := s.loadLegacy(raw, now.Add(-s.retention)); err != nil {
			return false, err
		}
		return true, nil
	}
	return false, s.loadJournal(raw, now)
}

func (s *NonceStore) loadLegacy(raw []byte, cutoff time.Time) error {
	var stored map[string]string
	if err := decodeStrict(raw, &stored); err != nil {
		return err
	}
	if len(stored) > s.maxEntries {
		return fmt.Errorf("legacy cache has %d entries, limit %d", len(stored), s.maxEntries)
	}
	for nonce, issuedText := range stored {
		if !validNonce(nonce) {
			return fmt.Errorf("legacy cache has invalid nonce %q", nonce)
		}
		issued, err := time.Parse(time.RFC3339Nano, issuedText)
		if err != nil {
			return fmt.Errorf("legacy cache has bad timestamp for %q: %w", nonce, err)
		}
		if issued.Before(cutoff) {
			continue
		}
		s.addLoaded(nonce, issued)
	}
	return nil
}

func (s *NonceStore) loadJournal(raw []byte, now time.Time) error {
	if !bytes.HasSuffix(raw, []byte{'\n'}) {
		return fmt.Errorf("torn trailing record")
	}
	lines := bytes.Split(raw[:len(raw)-1], []byte{'\n'})
	if len(lines) == 0 || len(lines) > maxNonceJournalLines {
		return fmt.Errorf("journal has %d lines, limit %d", len(lines), maxNonceJournalLines)
	}
	var header nonceJournalHeader
	if err := decodeStrict(lines[0], &header); err != nil {
		return fmt.Errorf("bad header: %w", err)
	}
	if header.Version != nonceJournalVersion {
		return fmt.Errorf("unsupported version %d", header.Version)
	}
	if header.RetentionNS <= 0 {
		return fmt.Errorf("invalid retention_ns %d", header.RetentionNS)
	}
	s.retention = time.Duration(header.RetentionNS)
	cutoff := now.Add(-s.retention)
	for lineNumber, line := range lines[1:] {
		if len(line) == 0 || len(line) > maxNonceRecordBytes {
			return fmt.Errorf("record %d has invalid size %d", lineNumber+2, len(line))
		}
		var record nonceJournalRecord
		if err := decodeStrict(line, &record); err != nil {
			return fmt.Errorf("record %d: %w", lineNumber+2, err)
		}
		if !validNonce(record.Nonce) {
			return fmt.Errorf("record %d has invalid nonce", lineNumber+2)
		}
		issued, err := time.Parse(time.RFC3339Nano, record.IssuedAt)
		if err != nil {
			return fmt.Errorf("record %d has bad issued_at: %w", lineNumber+2, err)
		}
		if issued.Before(cutoff) {
			s.obsolete++
			continue
		}
		if _, duplicate := s.seen[record.Nonce]; duplicate {
			return fmt.Errorf("record %d duplicates a fresh nonce", lineNumber+2)
		}
		if len(s.seen) >= s.maxEntries {
			return fmt.Errorf("journal has more than %d fresh entries", s.maxEntries)
		}
		s.addLoaded(record.Nonce, issued)
	}
	return nil
}

func (s *NonceStore) addLoaded(nonce string, issued time.Time) {
	s.seen[nonce] = issued
	s.expiry = append(s.expiry, nonceExpiry{nonce: nonce, issued: issued})
}

func decodeStrict(data []byte, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("trailing JSON data")
	}
	return nil
}

func (s *NonceStore) appendLocked(line []byte) error {
	file, err := os.OpenFile(s.path, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("signing: open nonce journal for append: %w", err)
	}
	written, err := file.Write(line)
	if err != nil {
		_ = file.Close()
		return fmt.Errorf("signing: append nonce journal: %w", err)
	}
	if written != len(line) {
		_ = file.Close()
		return fmt.Errorf("signing: append nonce journal: %w", io.ErrShortWrite)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return fmt.Errorf("signing: sync nonce journal: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("signing: close nonce journal: %w", err)
	}
	s.fileSize += int64(len(line))
	return nil
}

func (s *NonceStore) rewriteLocked() error {
	entries := make([]nonceExpiry, 0, len(s.seen))
	for nonce, issued := range s.seen {
		entries = append(entries, nonceExpiry{nonce: nonce, issued: issued})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].issued.Equal(entries[j].issued) {
			return entries[i].nonce < entries[j].nonce
		}
		return entries[i].issued.Before(entries[j].issued)
	})

	var data bytes.Buffer
	writer := bufio.NewWriter(&data)
	if err := writeJSONLine(writer, nonceJournalHeader{Version: nonceJournalVersion, RetentionNS: int64(s.retention)}); err != nil {
		return fmt.Errorf("signing: marshal nonce-journal header: %w", err)
	}
	for _, entry := range entries {
		record := nonceJournalRecord{Nonce: entry.nonce, IssuedAt: entry.issued.Format(time.RFC3339Nano)}
		if err := writeJSONLine(writer, record); err != nil {
			return fmt.Errorf("signing: marshal nonce-journal record: %w", err)
		}
	}
	if err := writer.Flush(); err != nil {
		return fmt.Errorf("signing: buffer nonce journal: %w", err)
	}
	if int64(data.Len()) > s.maxBytes {
		return fmt.Errorf("signing: compacted nonce journal is %d bytes, limit %d", data.Len(), s.maxBytes)
	}

	dir := filepath.Dir(s.path)
	temp, err := os.CreateTemp(dir, "."+filepath.Base(s.path)+".tmp-")
	if err != nil {
		return fmt.Errorf("signing: create nonce-journal temp file: %w", err)
	}
	tempPath := temp.Name()
	removeTemp := true
	defer func() {
		if removeTemp {
			_ = os.Remove(tempPath)
		}
	}()
	if err := temp.Chmod(0o600); err != nil {
		_ = temp.Close()
		return fmt.Errorf("signing: chmod nonce-journal temp file: %w", err)
	}
	written, err := temp.Write(data.Bytes())
	if err != nil {
		_ = temp.Close()
		return fmt.Errorf("signing: write nonce-journal temp file: %w", err)
	}
	if written != data.Len() {
		_ = temp.Close()
		return fmt.Errorf("signing: write nonce-journal temp file: %w", io.ErrShortWrite)
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return fmt.Errorf("signing: sync nonce-journal temp file: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("signing: close nonce-journal temp file: %w", err)
	}
	if err := os.Rename(tempPath, s.path); err != nil {
		return fmt.Errorf("signing: replace nonce journal: %w", err)
	}
	removeTemp = false
	if err := syncDirectory(dir); err != nil {
		return fmt.Errorf("signing: sync nonce-journal directory: %w", err)
	}
	s.fileSize = int64(data.Len())
	s.obsolete = 0
	return nil
}

func writeJSONLine(writer *bufio.Writer, value any) error {
	line, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if _, err := writer.Write(line); err != nil {
		return err
	}
	return writer.WriteByte('\n')
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	if err := directory.Sync(); err != nil {
		_ = directory.Close()
		return err
	}
	return directory.Close()
}
