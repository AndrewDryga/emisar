package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The exact spellings that made this a defect: each one loads, advertises,
// persists, produces a valid pack_ref and can be signed — and is then refused
// by `packctl catalog build`, so it can never be published. Catching them at
// authoring is the whole point.
func TestPublishableVersion(t *testing.T) {
	for _, ok := range []string{"1", "1.4", "0.3.15", "10.20.30"} {
		if err := publishableVersion(ok); err != nil {
			t.Errorf("publishableVersion(%q) = %v, want nil", ok, err)
		}
	}
	for _, bad := range []string{"", "1.0.0-rc1", "2.0.0+build", "v1.2", "stable", "1.0.0.beta"} {
		if err := publishableVersion(bad); err == nil {
			t.Errorf("publishableVersion(%q) = nil, want a refusal", bad)
		}
	}
}

func TestValidatePackVersions(t *testing.T) {
	write := func(t *testing.T, body string) string {
		t.Helper()
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "pack.yaml"), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return dir
	}

	t.Run("a publishable version passes", func(t *testing.T) {
		dir := write(t, "schema_version: 1\nversion: 0.3.15\nretired_below: 0.3.15\n")
		if err := validatePackVersions(dir); err != nil {
			t.Errorf("validatePackVersions = %v, want nil", err)
		}
	})

	t.Run("a prerelease version is refused with its reason", func(t *testing.T) {
		dir := write(t, "schema_version: 1\nversion: 1.0.0-rc1\n")
		err := validatePackVersions(dir)
		if err == nil {
			t.Fatal("validatePackVersions accepted a version the registry cannot publish")
		}
		if !strings.Contains(err.Error(), "never reach the registry") {
			t.Errorf("error does not explain the consequence: %v", err)
		}
	})

	// The retirement floor is compared against published versions by the same
	// parser, so an unspellable floor is the same defect one field over.
	t.Run("an unpublishable retirement floor is refused", func(t *testing.T) {
		dir := write(t, "schema_version: 1\nversion: 1.0.0\nretired_below: 1.0.0-rc1\n")
		err := validatePackVersions(dir)
		if err == nil {
			t.Fatal("validatePackVersions accepted an uncomparable retired_below")
		}
		if !strings.Contains(err.Error(), "retired_below") {
			t.Errorf("error does not name the field: %v", err)
		}
	})
}

// Every pack we ship must already satisfy the lint — otherwise it is a rule
// nobody could adopt.
func TestEveryShippedPackVersionIsPublishable(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", "..", "packs"))
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dir := filepath.Join(root, entry.Name())
		if _, err := os.Stat(filepath.Join(dir, "pack.yaml")); err != nil {
			continue
		}
		checked++
		if err := validatePackVersions(dir); err != nil {
			t.Errorf("shipped pack: %v", err)
		}
	}
	if checked == 0 {
		t.Fatal("no packs were checked; the path is wrong")
	}
}
