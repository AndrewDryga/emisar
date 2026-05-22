package audit

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCursor_PersistAcrossOpen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ack.json")
	c, err := OpenCursor(path, 16)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.MarkAcked("evt_1"); err != nil {
		t.Fatal(err)
	}
	if err := c.MarkAcked("evt_2"); err != nil {
		t.Fatal(err)
	}

	// Reopen.
	c2, err := OpenCursor(path, 16)
	if err != nil {
		t.Fatal(err)
	}
	if !c2.IsAcked("evt_1") || !c2.IsAcked("evt_2") {
		t.Fatalf("acks not persisted: %d entries", c2.Size())
	}
	if c2.IsAcked("evt_3") {
		t.Fatal("evt_3 should not be acked")
	}
}

func TestCursor_TrimsToMax(t *testing.T) {
	c, err := OpenCursor(filepath.Join(t.TempDir(), "ack.json"), 3)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		if err := c.MarkAcked(idForIter(i)); err != nil {
			t.Fatal(err)
		}
	}
	if c.Size() != 3 {
		t.Fatalf("size=%d, want 3", c.Size())
	}
	// Oldest two should be evicted.
	if c.IsAcked("evt_0") || c.IsAcked("evt_1") {
		t.Fatalf("oldest entries should be evicted")
	}
	if !c.IsAcked("evt_2") || !c.IsAcked("evt_3") || !c.IsAcked("evt_4") {
		t.Fatalf("newest entries should remain")
	}
}

func TestCursor_NoPathSkipsPersist(t *testing.T) {
	c, err := OpenCursor("", 8)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.MarkAcked("evt_x"); err != nil {
		t.Fatalf("MarkAcked with empty path should succeed: %v", err)
	}
	if !c.IsAcked("evt_x") {
		t.Fatal("in-memory state should still work")
	}
}

func TestCursor_FileMissingIsEmpty(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.json")
	c, err := OpenCursor(path, 4)
	if err != nil {
		t.Fatal(err)
	}
	if c.Size() != 0 {
		t.Fatalf("expected empty cursor")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("file should not exist yet")
	}
}

func idForIter(i int) string {
	return "evt_" + string(rune('0'+i))
}
