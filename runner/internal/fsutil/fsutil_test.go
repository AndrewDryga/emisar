package fsutil

import (
	"errors"
	"io"
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

func TestReplaceFileWritesDurablyWithOwnerOnlyMode(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state", "token.json")
	if err := ReplaceFile(path, func(w io.Writer) error {
		_, err := io.WriteString(w, "first")
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if err := ReplaceFile(path, func(w io.Writer) error {
		_, err := io.WriteString(w, "second")
		return err
	}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "second" {
		t.Fatalf("content = %q, err = %v", data, err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, err = %v", info.Mode(), err)
	}
	leftovers, err := filepath.Glob(filepath.Join(filepath.Dir(path), ".*tmp-*"))
	if err != nil || len(leftovers) != 0 {
		t.Fatalf("temp leftovers = %v, err = %v", leftovers, err)
	}
}

func TestReplaceFileFailedWriteKeepsOriginalAndRemovesTemp(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	callbackErr := errors.New("serialization exploded")
	err := ReplaceFile(path, func(io.Writer) error { return callbackErr })
	if !errors.Is(err, callbackErr) {
		t.Fatalf("err = %v, want the callback's own error", err)
	}
	data, err2 := os.ReadFile(path)
	if err2 != nil || string(data) != "original" {
		t.Fatalf("original clobbered: %q, %v", data, err2)
	}
	leftovers, err2 := filepath.Glob(filepath.Join(dir, ".*tmp-*"))
	if err2 != nil || len(leftovers) != 0 {
		t.Fatalf("temp leftovers = %v, err = %v", leftovers, err2)
	}
}

// A symlink planted AT the destination is replaced by the rename — the write
// lands at path itself, never through the link at a redirected target.
func TestReplaceFileDoesNotFollowDestinationSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	if err := os.WriteFile(target, []byte("leave me"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "state.json")
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	if err := ReplaceFile(path, func(w io.Writer) error {
		_, err := io.WriteString(w, "new state")
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "leave me" {
		t.Fatalf("symlink target changed: %q, %v", data, err)
	}
	if info, err := os.Lstat(path); err != nil || info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("path is still a symlink: %v, %v", info, err)
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != "new state" {
		t.Fatalf("replacement content = %q, %v", data, err)
	}
}
