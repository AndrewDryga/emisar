package fsutil

import (
	"os"
	"path/filepath"
	"strings"
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

func TestAcquireFileLock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runner.lock")
	owner, err := AcquireFileLock(path)
	if err != nil {
		t.Fatalf("acquire owner: %v", err)
	}
	if _, err := AcquireFileLock(path); err == nil || !strings.Contains(err.Error(), "already held") {
		t.Fatalf("second owner error = %v, want already held", err)
	}
	if err := owner.Close(); err != nil {
		t.Fatalf("close owner: %v", err)
	}

	reopened, err := AcquireFileLock(path)
	if err != nil {
		t.Fatalf("reacquire after close: %v", err)
	}
	if err := reopened.Close(); err != nil {
		t.Fatalf("close reopened lock: %v", err)
	}
}
