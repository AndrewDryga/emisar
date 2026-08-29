package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// writeEntraCredentialFile records the client id owner-only, and tightens a
// pre-existing world-readable file so a re-run cannot leave the app's identity
// readable by other users.
func TestWriteEntraCredentialFileIsOwnerOnly(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "entra.env")
	if err := os.WriteFile(path, []byte("stale\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	const clientID = "11111111-2222-3333-4444-555555555555"
	if err := writeEntraCredentialFile(path, clientID); err != nil {
		t.Fatalf("write credential file: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "ENTRA_CLIENT_ID="+clientID) || strings.Contains(string(data), "stale") {
		t.Fatalf("credential file = %q", data)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("mode = %o, want 0600", info.Mode().Perm())
		}
	}
}

func TestClientIDPattern(t *testing.T) {
	for value, want := range map[string]bool{
		"11111111-2222-3333-4444-555555555555": true,
		"AABBCCDD-2222-3333-4444-555555555555": true,
		"":                                     false,
		"not-a-guid":                           false,
		"11111111-2222-3333-4444-55555555555":  false,
		"Application (client) ID":              false,
	} {
		if got := clientIDPattern.MatchString(value); got != want {
			t.Errorf("clientIDPattern(%q) = %v, want %v", value, got, want)
		}
	}
}
