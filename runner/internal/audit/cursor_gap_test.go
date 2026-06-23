package audit

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"testing"
)

// This file closes the PHASE-2 "gap" rows for RSEC-014 (audit ack cursor):
// idempotent MarkAcked, atomic write-then-rename, disk-failure-advances-memory,
// corrupt-file parse error, max<=0 default, perms, and sorted snapshot
// (cursor.go).

// TestCursor_MarkAckedIdempotent — acking the same id twice is a
// no-op on the second call: size unchanged and (since the early-return skips
// persist) the second call cannot fail on a write.
func TestCursor_MarkAckedIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ack.json")
	c, err := OpenCursor(path, 16)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.MarkAcked("evt_a"); err != nil {
		t.Fatal(err)
	}
	if err := c.MarkAcked("evt_a"); err != nil {
		t.Fatalf("re-acking should be a no-op, got %v", err)
	}
	if c.Size() != 1 {
		t.Fatalf("size after double-ack = %d, want 1", c.Size())
	}
}

// TestCursor_AtomicWriteThenRename — persist writes to a .tmp
// then renames into place, leaving no stray temp file and a valid final file
// the reopen path can parse. (Crash-mid-write durability is the reason for the
// rename; we assert its observable result.)
func TestCursor_AtomicWriteThenRename(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ack.json")
	c, err := OpenCursor(path, 16)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.MarkAcked("evt_1"); err != nil {
		t.Fatal(err)
	}

	// The committed file exists and is valid JSON...
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("final cursor file should exist after rename: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var s CursorState
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatalf("committed cursor file should be valid JSON: %v", err)
	}
	// ...and the .tmp staging file was renamed away, not left behind.
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("staging .tmp should be renamed away, stat err = %v", err)
	}
}

// TestCursor_DiskFailureAdvancesMemory — when persist fails,
// MarkAcked returns the error BUT the in-memory state has already advanced, so
// IsAcked still reports true. The cursor opens cleanly; the write is then
// failed by stripping write permission from the parent dir so the .tmp staging
// write is denied.
func TestCursor_DiskFailureAdvancesMemory(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("directory write-permission bits don't gate writes on windows")
	}
	if os.Geteuid() == 0 {
		t.Skip("root bypasses directory write permissions")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "ack.json")

	c, err := OpenCursor(path, 16)
	if err != nil {
		t.Fatal(err)
	}
	// Deny writes in the directory so persist's .tmp write fails. (MkdirAll on
	// an already-existing dir is a no-op, so it gets past that to the write.)
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) }) // let t.TempDir clean up

	err = c.MarkAcked("evt_1")
	if err == nil {
		t.Fatal("expected persist to fail when the directory is not writable")
	}
	// In-memory state advanced despite the disk error.
	if !c.IsAcked("evt_1") {
		t.Fatal("in-memory ack should hold even when persist failed")
	}
}

// TestCursor_CorruptFileParseError — opening a malformed JSON
// sidecar surfaces a parse error rather than silently starting empty.
func TestCursor_CorruptFileParseError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ack.json")
	if err := os.WriteFile(path, []byte("{not valid json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenCursor(path, 16); err == nil {
		t.Fatal("expected a parse error opening a corrupt cursor file")
	}
}

// TestCursor_MaxDefaults — max <= 0 falls back to 4096, so a
// non-positive bound never means "retain nothing".
func TestCursor_MaxDefaults(t *testing.T) {
	for _, max := range []int{0, -7} {
		c, err := OpenCursor(filepath.Join(t.TempDir(), "ack.json"), max)
		if err != nil {
			t.Fatal(err)
		}
		// Ack a handful; none should be trimmed under the 4096 default.
		for _, id := range []string{"evt_a", "evt_b", "evt_c"} {
			if err := c.MarkAcked(id); err != nil {
				t.Fatal(err)
			}
		}
		if c.Size() != 3 {
			t.Fatalf("max=%d should default to 4096 (no trim), size=%d", max, c.Size())
		}
	}
}

// TestCursor_PersistPerms — the sidecar file is 0o600 and the
// directory the cursor creates is 0o750, matching the audit log's posture
// (the cursor records which event ids were acked — still host metadata).
func TestCursor_PersistPerms(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix permission bits are not meaningful on windows")
	}
	// Nest so persist's MkdirAll(dir, 0o750) — not t.TempDir's 0o700 — is the
	// directory under test.
	dir := filepath.Join(t.TempDir(), "outbox")
	path := filepath.Join(dir, "ack.json")
	c, err := OpenCursor(path, 16)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.MarkAcked("evt_1"); err != nil {
		t.Fatal(err)
	}

	di, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := di.Mode().Perm(); got != 0o750 {
		t.Fatalf("cursor dir perm = %#o, want 0o750", got)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := fi.Mode().Perm(); got != 0o600 {
		t.Fatalf("cursor file perm = %#o, want 0o600", got)
	}
}

// TestCursor_SnapshotSortedOnDisk — acking out of order yields a
// sorted acked_event_ids array on disk, so the file is stable / diff-friendly.
func TestCursor_SnapshotSortedOnDisk(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ack.json")
	c, err := OpenCursor(path, 16)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"evt_c", "evt_a", "evt_b"} {
		if err := c.MarkAcked(id); err != nil {
			t.Fatal(err)
		}
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var s CursorState
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatal(err)
	}
	if !sort.StringsAreSorted(s.AckedEventIDs) {
		t.Fatalf("persisted ids should be sorted, got %v", s.AckedEventIDs)
	}
	if len(s.AckedEventIDs) != 3 {
		t.Fatalf("expected 3 persisted ids, got %v", s.AckedEventIDs)
	}
}
