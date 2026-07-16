package signing

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func journalNonce(label string) string {
	digest := sha256.Sum256([]byte(label))
	return hex.EncodeToString(digest[:16])
}

func TestNonceJournalAppendsAndSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "signing", "nonce-cache.json")
	now := time.Now().UTC()
	first := journalNonce("first")
	second := journalNonce("second")

	store, err := OpenNonceStore(path, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if accepted, err := store.consume(first, now, now); err != nil || !accepted {
		t.Fatalf("consume first = %v, %v", accepted, err)
	}
	afterFirst, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if accepted, err := store.consume(second, now.Add(time.Minute), now.Add(time.Minute)); err != nil || !accepted {
		t.Fatalf("consume second = %v, %v", accepted, err)
	}
	afterSecond, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(afterSecond, afterFirst) {
		t.Fatal("ordinary nonce consumption rewrote the journal instead of appending")
	}
	if err := store.Close(); err != nil {
		t.Fatalf("Close before restart: %v", err)
	}

	restarted, err := OpenNonceStore(path, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore after restart: %v", err)
	}
	t.Cleanup(func() { _ = restarted.Close() })
	if accepted, err := restarted.consume(first, now, now.Add(2*time.Minute)); err != nil || accepted {
		t.Fatalf("restarted consume replay = %v, %v", accepted, err)
	}
}

func TestNonceJournalRejectsLegacySnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonce-cache.json")
	nonce := journalNonce("legacy")
	issued := time.Now().UTC()
	legacy := []byte(`{"` + nonce + `":"` + issued.Format(time.RFC3339Nano) + `"}`)
	if err := os.WriteFile(path, legacy, 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := OpenNonceStore(path, time.Hour); err == nil {
		t.Fatal("legacy nonce snapshot did not fail closed")
	}
}

func TestNonceJournalCompactsExpiredRecords(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonce-cache.json")
	store, err := OpenNonceStore(path, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	store.compactAfter = 1
	now := time.Now().UTC()
	oldNonce := journalNonce("expired")
	newNonce := journalNonce("fresh")
	if accepted, err := store.consume(oldNonce, now, now); err != nil || !accepted {
		t.Fatalf("consume old = %v, %v", accepted, err)
	}
	later := now.Add(2 * time.Hour)
	if accepted, err := store.consume(newNonce, later, later); err != nil || !accepted {
		t.Fatalf("consume fresh = %v, %v", accepted, err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(oldNonce)) {
		t.Fatal("compaction retained an expired nonce record")
	}
	if lines := bytes.Count(raw, []byte{'\n'}); lines != 2 {
		t.Fatalf("compacted journal has %d lines, want header + fresh record", lines)
	}
}

func TestNonceJournalCapacityFailsWithoutEvictingFreshEntries(t *testing.T) {
	store := NewMemoryNonceStore()
	if err := store.bindRetention(time.Hour); err != nil {
		t.Fatal(err)
	}
	store.maxEntries = 2
	now := time.Now().UTC()
	first := journalNonce("one")
	second := journalNonce("two")
	third := journalNonce("three")
	for _, nonce := range []string{first, second} {
		if accepted, err := store.consume(nonce, now, now); err != nil || !accepted {
			t.Fatalf("consume %s = %v, %v", nonce, accepted, err)
		}
	}
	if accepted, err := store.consume(third, now, now); err == nil || accepted {
		t.Fatalf("over-capacity consume = %v, %v", accepted, err)
	}
	if len(store.seen) != 2 {
		t.Fatalf("capacity failure evicted a fresh nonce: %d remain", len(store.seen))
	}
	if _, ok := store.seen[first]; !ok {
		t.Fatal("capacity failure evicted the oldest fresh nonce")
	}
	if accepted, err := store.consume(third, now.Add(2*time.Hour), now.Add(2*time.Hour)); err != nil || !accepted {
		t.Fatalf("consume after expiry = %v, %v", accepted, err)
	}
}

func TestNonceJournalByteLimitFailsWithoutConsumingNonce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonce-cache.json")
	store, err := OpenNonceStore(path, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	store.maxBytes = store.fileSize + 1
	now := time.Now().UTC()
	nonce := journalNonce("byte-limit")
	if accepted, err := store.consume(nonce, now, now); err == nil || accepted {
		t.Fatalf("over-byte-limit consume = %v, %v", accepted, err)
	}
	if _, consumed := store.seen[nonce]; consumed {
		t.Fatal("byte-limit failure consumed the nonce in memory")
	}
	store.maxBytes = defaultMaxJournal
	if accepted, err := store.consume(nonce, now, now); err != nil || !accepted {
		t.Fatalf("consume after capacity recovery = %v, %v", accepted, err)
	}
}

func TestNonceJournalLockRejectsASecondOwnerAndReleasesCleanly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonce-cache.json")
	owner, err := OpenNonceStore(path, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore owner: %v", err)
	}
	if _, err := OpenNonceStore(path, time.Hour); err == nil ||
		!strings.Contains(err.Error(), "file lock is already held") {
		t.Fatalf("second owner error = %v", err)
	}
	if err := owner.Close(); err != nil {
		t.Fatalf("Close owner: %v", err)
	}

	reopened, err := OpenNonceStore(path, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore after release: %v", err)
	}
	t.Cleanup(func() { _ = reopened.Close() })
}

func TestNonceJournalRejectsRetentionWidening(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonce-cache.json")
	store, err := OpenNonceStore(path, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if err := store.bindRetention(30 * time.Minute); err != nil {
		t.Fatalf("narrowing retention must be safe: %v", err)
	}
	if err := store.bindRetention(time.Hour); err != nil {
		t.Fatalf("restoring the persisted horizon must be safe: %v", err)
	}
	if err := store.bindRetention(2 * time.Hour); err == nil {
		t.Fatal("in-process retention widening must be rejected")
	}
	if err := store.Close(); err != nil {
		t.Fatalf("Close before restart: %v", err)
	}
	if _, err := OpenNonceStore(path, 2*time.Hour); err == nil {
		t.Fatal("restart-time retention widening must be rejected")
	}
}

func TestVerifierReloadRejectsRetentionWidening(t *testing.T) {
	cas, _ := testCA(t)
	store := NewMemoryNonceStore()
	if _, err := NewVerifier(true, cas, time.Hour, testRunnerID, testOrigin, testGroup, testLabels(), store); err != nil {
		t.Fatalf("initial verifier: %v", err)
	}
	if _, err := NewVerifier(true, cas, 2*time.Hour, testRunnerID, testOrigin, testGroup, testLabels(), store); err == nil {
		t.Fatal("replacement verifier widened the replay horizon")
	}
}

func TestNonceJournalRejectsTornAndUnknownRecords(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nonce-cache.json")
	store, err := OpenNonceStore(path, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore: %v", err)
	}
	header, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("Close before corruption tests: %v", err)
	}

	t.Run("torn", func(t *testing.T) {
		if err := os.WriteFile(path, append(header, []byte(`{"nonce":`)...), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := OpenNonceStore(path, time.Hour); err == nil {
			t.Fatal("a torn trailing record must fail startup")
		}
	})

	t.Run("unknown field", func(t *testing.T) {
		record := `{"nonce":"` + journalNonce("unknown") + `","issued_at":"` +
			time.Now().UTC().Format(time.RFC3339Nano) + `","extra":true}` + "\n"
		if err := os.WriteFile(path, append(header, record...), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := OpenNonceStore(path, time.Hour); err == nil {
			t.Fatal("an unknown journal field must fail startup")
		}
	})
}

func TestNonceJournalAppendFailureLatchesClosed(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root bypasses the file mode this test relies on")
	}
	path := filepath.Join(t.TempDir(), "nonce-cache.json")
	store, err := OpenNonceStore(path, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if err := os.Chmod(path, 0o400); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o600) })
	now := time.Now().UTC()
	if accepted, err := store.consume(journalNonce("write-fails"), now, now); err == nil || accepted {
		t.Fatalf("unwritable append = %v, %v", accepted, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if accepted, err := store.consume(journalNonce("still-closed"), now, now); err == nil || accepted ||
		!strings.Contains(err.Error(), "previously failed") {
		t.Fatalf("latched append = %v, %v", accepted, err)
	}
}
