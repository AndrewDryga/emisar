package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The runner's durable identity: generated once, persisted, reused. This
// is what lets a reconnect map back to the same cloud runner row instead
// of registering a brand-new one each time.
func TestResolveExternalIDPersistsAndReuses(t *testing.T) {
	dir := t.TempDir()

	id1, err := resolveExternalID("", dir)
	if err != nil {
		t.Fatalf("resolveExternalID: %v", err)
	}
	if len(id1) != 36 {
		t.Errorf("generated id = %q, want a 36-char UUID", id1)
	}

	b, err := os.ReadFile(filepath.Join(dir, "runner_id"))
	if err != nil {
		t.Fatalf("runner_id not persisted: %v", err)
	}
	if strings.TrimSpace(string(b)) != id1 {
		t.Errorf("persisted id = %q, want %q", strings.TrimSpace(string(b)), id1)
	}

	id2, err := resolveExternalID("", dir)
	if err != nil {
		t.Fatalf("resolveExternalID (2nd): %v", err)
	}
	if id2 != id1 {
		t.Errorf("second call id = %q, want stable %q", id2, id1)
	}
}

// An operator-pinned `runner.id` in config wins and isn't persisted.
func TestResolveExternalIDPrefersConfiguredID(t *testing.T) {
	dir := t.TempDir()

	id, err := resolveExternalID("  operator-pinned  ", dir)
	if err != nil {
		t.Fatalf("resolveExternalID: %v", err)
	}
	if id != "operator-pinned" {
		t.Errorf("id = %q, want operator-pinned (trimmed)", id)
	}

	if _, err := os.Stat(filepath.Join(dir, "runner_id")); !os.IsNotExist(err) {
		t.Errorf("runner_id should not be written when id comes from config")
	}
}
