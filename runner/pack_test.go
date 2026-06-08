package main

import (
	"os"
	"path/filepath"
	"testing"
)

// safePackName is the guard that keeps `pack uninstall` from turning a
// hostile id into a RemoveAll outside the packs dir, so its edge cases
// are worth pinning.
func TestSafePackName(t *testing.T) {
	ok := []string{"redis", "linux-core", "aws-ec2", "pack.with.dots", "a"}
	for _, n := range ok {
		if !safePackName(n) {
			t.Errorf("safePackName(%q) = false, want true", n)
		}
	}

	bad := []string{
		"",            // empty
		".",           // current dir
		"..",          // parent
		"../etc",      // traversal
		"../../etc",   // deeper traversal
		"a/b",         // separator
		"/etc/passwd", // absolute
		"foo/",        // trailing sep
		"./foo",       // dot-prefixed (not Clean'd form)
	}
	for _, n := range bad {
		if safePackName(n) {
			t.Errorf("safePackName(%q) = true, want false", n)
		}
	}
}

// copyTree must produce a world-readable pack tree even from a restrictive
// source: a fetched pack lands in a 0700 os.MkdirTemp dir, and preserving that
// would leave a `sudo pack install/update` pack unreadable to the non-root
// runner service user (the "only 2 of N packs loaded" bug).
func TestCopyTree_NormalizesModesForServiceUser(t *testing.T) {
	src := t.TempDir()
	if err := os.Chmod(src, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "pack.yaml"), []byte("id: x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(src, "actions"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "actions", "a.yaml"), []byte("id: x.a\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	dst := filepath.Join(t.TempDir(), "pack")
	if err := copyTree(src, dst); err != nil {
		t.Fatalf("copyTree: %v", err)
	}

	for _, dir := range []string{dst, filepath.Join(dst, "actions")} {
		fi, err := os.Stat(dir)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != 0o755 {
			t.Errorf("dir %s mode = %o, want 0755", dir, fi.Mode().Perm())
		}
	}
	for _, f := range []string{filepath.Join(dst, "pack.yaml"), filepath.Join(dst, "actions", "a.yaml")} {
		fi, err := os.Stat(f)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != 0o644 {
			t.Errorf("file %s mode = %o, want 0644", f, fi.Mode().Perm())
		}
	}
}
