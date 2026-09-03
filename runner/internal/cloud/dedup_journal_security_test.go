//go:build !windows

package cloud

import (
	"bytes"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestDispatchJournalRejectsUnsafeFilesystemObjects(t *testing.T) {
	header := journalTestBytes(t, dispatchJournalHeader{
		Format: dispatchJournalFormat, Version: dispatchJournalVersion,
	})

	t.Run("symlink", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "target.jsonl")
		path := filepath.Join(dir, dispatchLogFilename)
		if err := os.WriteFile(target, header, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, path); err != nil {
			t.Fatal(err)
		}
		if d := newDedupRing(4, path, "", nil); d.loadErr == nil {
			t.Fatal("symlink dispatch journal loaded")
		}
		if report := InspectDispatchLog(dir); report.State != DispatchLogCorrupt {
			t.Fatalf("symlink inspection = %+v", report)
		}
	})

	t.Run("fifo", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), dispatchLogFilename)
		if err := syscall.Mkfifo(path, 0o600); err != nil {
			t.Fatal(err)
		}
		if d := newDedupRing(4, path, "", nil); d.loadErr == nil {
			t.Fatal("FIFO dispatch journal loaded")
		}
	})

	t.Run("device", func(t *testing.T) {
		if _, err := readDispatchLog("/dev/null"); err == nil {
			t.Fatal("device dispatch journal loaded")
		}
	})

	t.Run("loose mode", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), dispatchLogFilename)
		if err := os.WriteFile(path, header, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0o640); err != nil {
			t.Fatal(err)
		}
		if d := newDedupRing(4, path, "", nil); d.loadErr == nil {
			t.Fatal("group-readable dispatch journal loaded")
		}
	})

	t.Run("foreign owner", func(t *testing.T) {
		if os.Geteuid() != 0 {
			t.Skip("changing file ownership requires root")
		}
		path := filepath.Join(t.TempDir(), dispatchLogFilename)
		if err := os.WriteFile(path, header, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chown(path, 65_534, -1); err != nil {
			t.Fatal(err)
		}
		if d := newDedupRing(4, path, "", nil); d.loadErr == nil {
			t.Fatal("foreign-owned dispatch journal loaded by the daemon path")
		}
		// Root's read-only diagnostic path may inspect the service user's file.
		dir := filepath.Dir(path)
		if report := InspectDispatchLog(dir); report.State != DispatchLogOK {
			t.Fatalf("root diagnostic inspection = %+v", report)
		}
	})
}

func TestDispatchJournalAppendRefusesPathReplacementBeforeWriting(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, dispatchLogFilename)
	d := newDedupRing(4, path, "", nil)
	original := filepath.Join(dir, "original.jsonl")
	if err := os.Rename(path, original); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "target.jsonl")
	if err := os.WriteFile(target, []byte("sentinel"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}

	if _, _, err := d.reserve("req", testDispatchDigest("req")); err == nil {
		t.Fatal("reservation followed a replacement symlink")
	}
	targetData, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(targetData, []byte("sentinel")) {
		t.Fatalf("symlink target changed: %q", targetData)
	}
	if d.loadErr != nil || dedupSize(d) != 0 {
		t.Fatalf("pre-write replacement latched or changed memory: load=%v size=%d", d.loadErr, dedupSize(d))
	}

	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(original, path); err != nil {
		t.Fatal(err)
	}
	if decision, _, err := d.reserve("req", testDispatchDigest("req")); err != nil || decision != reservationNew {
		t.Fatalf("retry after restoring journal: decision=%v err=%v", decision, err)
	}
}

func TestDispatchJournalRejectsOversizedFileBeforeParsing(t *testing.T) {
	path := filepath.Join(t.TempDir(), dispatchLogFilename)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(maxDispatchJournalFileBytes + 1); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	if _, err := readDispatchLog(path); err == nil {
		t.Fatal("oversized dispatch journal loaded")
	}
}
