package signing

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

// NonceStore owns replay state independently of any replaceable verifier policy.
// It is safe for concurrent use. A runner opens one store at boot and shares it
// with the initial verifier and every SIGHUP replacement, so a nonce consumed by
// either an old or new verifier is immediately visible to both.
//
// When path is non-empty, every mutation is mirrored to a bounded JSON file via
// atomic write + rename. The store holds no open file descriptor and needs no
// Close; its caller owns the pointer for the runner process lifetime.
type NonceStore struct {
	mu   sync.Mutex
	path string
	seen map[string]time.Time
}

// OpenNonceStore loads the durable replay state, dropping entries already
// outside maxAge. A missing file is a clean first boot. A present-but-unreadable
// or corrupt file fails construction closed rather than forgetting replay state.
func OpenNonceStore(path string, maxAge time.Duration) (*NonceStore, error) {
	if maxAge <= 0 {
		return nil, fmt.Errorf("signing: max attestation age must be positive")
	}
	seen := make(map[string]time.Time)
	if path != "" {
		loaded, err := loadNonces(path, time.Now().Add(-maxAge))
		if err != nil {
			return nil, err
		}
		seen = loaded
	}
	return &NonceStore{path: path, seen: seen}, nil
}

// NewMemoryNonceStore returns a process-local store for tests and callers that
// intentionally do not configure durable runner state.
func NewMemoryNonceStore() *NonceStore {
	return &NonceStore{seen: make(map[string]time.Time)}
}

// consume records nonce, or reports that it was already present inside cutoff.
// Persistence happens before the live map changes, so a write failure leaves the
// old in-memory state intact and the dispatch fails closed.
func (s *NonceStore) consume(nonce string, issued, cutoff time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	next := make(map[string]time.Time, len(s.seen)+1)
	for existing, seenAt := range s.seen {
		if !seenAt.Before(cutoff) {
			next[existing] = seenAt
		}
	}
	if _, used := next[nonce]; used {
		return false, nil
	}
	next[nonce] = issued

	if s.path != "" {
		if err := saveNonces(s.path, next); err != nil {
			return false, err
		}
	}
	s.seen = next
	return true, nil
}

// loadNonces reads the persisted replay cache from path, dropping any entry whose
// issued_at predates cutoff (already outside the window, so never replayable). A
// MISSING file is an empty cache — first run, nothing persisted yet. A present-but-
// unreadable or corrupt file is an error: the runner must FAIL CLOSED rather than
// start enforcing with a replay cache it can't trust.
func loadNonces(path string, cutoff time.Time) (map[string]time.Time, error) {
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return make(map[string]time.Time), nil
	}
	if err != nil {
		return nil, fmt.Errorf("signing: read nonce cache %q: %w", path, err)
	}

	var stored map[string]string
	if err := json.Unmarshal(raw, &stored); err != nil {
		return nil, fmt.Errorf("signing: nonce cache %q is corrupt: %w", path, err)
	}

	seen := make(map[string]time.Time, len(stored))
	for nonce, issuedStr := range stored {
		issued, err := time.Parse(time.RFC3339Nano, issuedStr)
		if err != nil {
			return nil, fmt.Errorf("signing: nonce cache %q has a bad timestamp for %q: %w", path, nonce, err)
		}
		if issued.Before(cutoff) {
			continue
		}
		seen[nonce] = issued
	}
	return seen, nil
}

// saveNonces atomically writes the (already-pruned) cache: temp file + rename, so
// a crash mid-write can't leave a torn file the next load rejects. Mode 0600 — the
// nonces aren't secret, but there's no reason for other host users to read them.
func saveNonces(path string, seen map[string]time.Time) error {
	stored := make(map[string]string, len(seen))
	for nonce, issued := range seen {
		stored[nonce] = issued.Format(time.RFC3339Nano)
	}
	data, err := json.Marshal(stored)
	if err != nil {
		return fmt.Errorf("signing: marshal nonce cache: %w", err)
	}

	if dir := filepath.Dir(path); dir != "" {
		if err := fsutil.SecureMkdirAll(dir, 0o750); err != nil {
			return fmt.Errorf("signing: create nonce-cache dir: %w", err)
		}
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("signing: write nonce cache: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("signing: replace nonce cache: %w", err)
	}
	return nil
}
