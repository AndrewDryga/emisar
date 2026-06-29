package fsutil

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSecureMkdirAll(t *testing.T) {
	tests := []struct {
		name    string
		pre     os.FileMode // 0 = don't pre-create; let SecureMkdirAll create it
		request os.FileMode
		want    os.FileMode
	}{
		{name: "creates a fresh dir with the requested perm", pre: 0, request: 0o750, want: 0o750},
		{name: "tightens a pre-existing world-readable dir", pre: 0o777, request: 0o750, want: 0o750},
		{name: "clears group-write and world bits", pre: 0o775, request: 0o750, want: 0o750},
		{name: "never loosens a stricter pre-existing dir", pre: 0o700, request: 0o750, want: 0o700},
		{name: "leaves an already-correct dir untouched", pre: 0o750, request: 0o750, want: 0o750},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "data")

			if tc.pre != 0 {
				if err := os.MkdirAll(dir, tc.pre); err != nil {
					t.Fatal(err)
				}
				// chmod after MkdirAll to defeat the test process's umask, so
				// the pre-existing dir really has tc.pre.
				if err := os.Chmod(dir, tc.pre); err != nil {
					t.Fatal(err)
				}
			}

			if err := SecureMkdirAll(dir, tc.request); err != nil {
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
