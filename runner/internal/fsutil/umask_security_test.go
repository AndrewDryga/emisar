//go:build darwin || dragonfly || freebsd || illumos || linux || netbsd || openbsd

package fsutil

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// A strict umask may narrow a fresh directory below the requested mode, but
// SecureMkdirAll must never widen it past the umask or past the request.
func TestSecureMkdirAll_StrictUmaskNarrowsFreshDir(t *testing.T) {
	tests := []struct {
		name  string
		umask int
		want  os.FileMode
	}{
		{name: "umask 022 keeps the request", umask: 0o022, want: 0o750},
		{name: "umask 027 keeps the request", umask: 0o027, want: 0o750},
		{name: "umask 077 narrows to owner only", umask: 0o077, want: 0o700},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			old := syscall.Umask(tc.umask)
			defer syscall.Umask(old)

			dir := filepath.Join(t.TempDir(), "a", "data")
			if err := SecureMkdirAll(dir, 0o750); err != nil {
				t.Fatalf("SecureMkdirAll: %v", err)
			}
			info, err := os.Stat(dir)
			if err != nil {
				t.Fatal(err)
			}
			if got := info.Mode().Perm(); got != tc.want {
				t.Fatalf("perm = %#o, want %#o", got, tc.want)
			}
		})
	}
}
