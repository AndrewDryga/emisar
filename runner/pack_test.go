package main

import "testing"

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
