package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// --ca-key takes the key MATERIAL, so the root of trust for signed dispatch
// lands in shell history and in the process table, readable by every other user
// on the host while the command runs. There was no file-based alternative at
// all, and these flags freeze at 1.0.
func TestCAKeyMaterial(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "ca.key")
	if err := os.WriteFile(path, []byte("  key-material-here\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Run("reads the file and trims it", func(t *testing.T) {
		got, err := caKeyMaterial("", path)
		if err != nil {
			t.Fatalf("caKeyMaterial: %v", err)
		}
		if got != "key-material-here" {
			t.Errorf("material = %q, want the trimmed file contents", got)
		}
	})

	t.Run("the argv form still works", func(t *testing.T) {
		got, err := caKeyMaterial("inline-key", "")
		if err != nil || got != "inline-key" {
			t.Errorf("caKeyMaterial(inline) = %q, %v", got, err)
		}
	})

	// Silently preferring one is how an operator signs with a key they did not
	// think they passed.
	t.Run("both is a usage mistake", func(t *testing.T) {
		_, err := caKeyMaterial("inline-key", path)
		if err == nil {
			t.Fatal("passing both should be refused")
		}
		if got := exitCode(t.Context(), err); got != exitUsage {
			t.Errorf("exit = %d, want %d", got, exitUsage)
		}
	})

	t.Run("neither names the preferred way through", func(t *testing.T) {
		_, err := caKeyMaterial("", "")
		if err == nil {
			t.Fatal("passing neither should be refused")
		}
		if !strings.Contains(err.Error(), "--ca-key-file") {
			t.Errorf("the refusal should recommend the file form, got %v", err)
		}
	})

	t.Run("an unreadable file is reported, not silently empty", func(t *testing.T) {
		if _, err := caKeyMaterial("", filepath.Join(dir, "missing")); err == nil {
			t.Error("a missing key file must be an error, never an empty key")
		}
	})
}
