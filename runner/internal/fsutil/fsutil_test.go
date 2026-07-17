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

func TestFileLockWriteRecord(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runner.lock")
	lock, err := AcquireFileLock(path)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	defer func() { _ = lock.Close() }()

	if err := lock.WriteRecord([]byte("12345")); err != nil {
		t.Fatalf("write record: %v", err)
	}
	if raw, _ := os.ReadFile(path); string(raw) != "12345" {
		t.Errorf("record = %q, want %q", raw, "12345")
	}

	// A rewrite truncates — a shorter record must not leave stale bytes.
	if err := lock.WriteRecord([]byte("7")); err != nil {
		t.Fatalf("rewrite record: %v", err)
	}
	if raw, _ := os.ReadFile(path); string(raw) != "7" {
		t.Errorf("record after rewrite = %q, want %q", raw, "7")
	}

	var released *FileLock
	if err := released.WriteRecord([]byte("x")); err == nil {
		t.Error("expected an error writing through a nil lock")
	}
}

func TestProbeFileLock(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "runner.lock")

	if _, err := ProbeFileLock(path); !os.IsNotExist(err) {
		t.Errorf("probe of a missing file = %v, want os.ErrNotExist", err)
	}

	lock, err := AcquireFileLock(path)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}

	// A probe through a second file description conflicts with the held
	// flock — even from the same process — so it reads held (the probe can't
	// tell WHO holds it, which is why callers read the PID record).
	if held, err := ProbeFileLock(path); err != nil || !held {
		t.Errorf("probe of a held lock: held=%v err=%v, want true, nil", held, err)
	}

	if err := lock.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	if held, err := ProbeFileLock(path); err != nil || held {
		t.Errorf("probe of a released lock: held=%v err=%v, want false, nil", held, err)
	}
}
