package signing

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// The replay cache lives in memory, but an empty cache after a restart or SIGHUP
// rebuild would let a captured, still-in-window attestation replay once. These
// two helpers mirror the cache to a small, bounded on-disk file so the seen-nonce
// set survives a process lifecycle. The file is `{nonce: issued_at}` JSON, kept
// pruned to entries inside the freshness window — so it stays bounded by the
// dispatch rate over maxAge, not by uptime.

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
		if err := os.MkdirAll(dir, 0o750); err != nil {
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
