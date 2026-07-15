package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReloadComponents_ReloadsSigningAfterPackFailure(t *testing.T) {
	packErr := errors.New("malformed pack")
	signingCalled := false
	changed, gotPackErr, signingErr := reloadComponents(
		func() error { return packErr },
		func() error {
			signingCalled = true
			return nil
		},
	)
	if !signingCalled {
		t.Fatal("signing reload was skipped after pack failure")
	}
	if !errors.Is(gotPackErr, packErr) || signingErr != nil {
		t.Fatalf("errors = (%v, %v), want (%v, nil)", gotPackErr, signingErr, packErr)
	}
	if !changed {
		t.Fatal("successful signing reload must trigger re-advertisement")
	}
}

func TestConnectRequiresDurableDataDir(t *testing.T) {
	for _, dataDir := range []string{"", "  ", "\n"} {
		if err := validateConnectDataDir(dataDir); err == nil {
			t.Fatalf("validateConnectDataDir(%q) accepted memory-only dispatch state", dataDir)
		}
	}
	if err := validateConnectDataDir(t.TempDir()); err != nil {
		t.Fatalf("validateConnectDataDir(valid): %v", err)
	}
}

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

// Once the identity path exists, corrupt state must fail closed. Minting a new
// id would create a second logical runner with an independent nonce journal.
func TestResolveExternalIDBlankFileFailsClosed(t *testing.T) {
	for _, blank := range []string{"", "   ", "\n\t\n"} {
		dir := t.TempDir()
		path := filepath.Join(dir, "runner_id")
		if err := os.WriteFile(path, []byte(blank), 0o600); err != nil {
			t.Fatalf("seed blank id file: %v", err)
		}

		if id, err := resolveExternalID("", dir); err == nil || id != "" {
			t.Fatalf("resolveExternalID(blank=%q) = %q, %v; want a closed failure", blank, id, err)
		}
	}
}

func TestResolveExternalIDUnreadablePathFailsClosed(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "runner_id"), 0o700); err != nil {
		t.Fatal(err)
	}
	if id, err := resolveExternalID("", dir); err == nil || id != "" {
		t.Fatalf("resolveExternalID = %q, %v; want a closed failure", id, err)
	}
}

// Minting persists the id atomically with tight permissions: the data dir is
// 0o750 and the id file is 0o600, so a co-tenant user can't read or swap the
// runner's durable identity, and a crash mid-write can't leave a torn file
// (write-tmp + rename).
func TestResolveExternalIDMintWritesTightPerms(t *testing.T) {
	parent := t.TempDir()
	// data_dir does not exist yet — resolveExternalID must MkdirAll it 0o750.
	dataDir := filepath.Join(parent, "data")

	id, err := resolveExternalID("", dataDir)
	if err != nil {
		t.Fatalf("resolveExternalID: %v", err)
	}

	dirInfo, err := os.Stat(dataDir)
	if err != nil {
		t.Fatalf("data dir not created: %v", err)
	}
	if perm := dirInfo.Mode().Perm(); perm != 0o750 {
		t.Errorf("data dir perm = %o, want 0o750", perm)
	}

	path := filepath.Join(dataDir, "runner_id")
	fileInfo, err := os.Stat(path)
	if err != nil {
		t.Fatalf("id file not created: %v", err)
	}
	if perm := fileInfo.Mode().Perm(); perm != 0o600 {
		t.Errorf("id file perm = %o, want 0o600", perm)
	}
	if fileInfo.Mode()&os.ModeSymlink != 0 {
		t.Errorf("id file must be a regular file, not a symlink")
	}

	// No leftover .tmp from the atomic write.
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("atomic-write .tmp must be renamed away, found leftover")
	}

	// Sanity: the persisted bytes match the returned id.
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read id file: %v", err)
	}
	if strings.TrimSpace(string(b)) != id {
		t.Errorf("persisted id %q != returned %q", strings.TrimSpace(string(b)), id)
	}
}
