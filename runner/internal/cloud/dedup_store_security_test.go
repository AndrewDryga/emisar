//go:build !windows

package cloud

import (
	"bytes"
	"errors"
	"io"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

func TestDedupStoreRefusesSymlinkAndFIFOAtStartupAndAppend(t *testing.T) {
	for _, kind := range []string{"symlink", "fifo", "directory"} {
		for _, phase := range []string{"startup", "append", "snapshot"} {
			t.Run(kind+"/"+phase, func(t *testing.T) {
				d := newDedupStoreFixture(t)
				before := maps.Clone(d.records)
				if err := os.Remove(d.storePath); err != nil {
					t.Fatal(err)
				}
				target := filepath.Join(t.TempDir(), "untouched")
				original := []byte("unrelated protected file\n")
				if err := os.WriteFile(target, original, 0o600); err != nil {
					t.Fatal(err)
				}
				switch kind {
				case "symlink":
					if err := os.Symlink(target, d.storePath); err != nil {
						t.Fatal(err)
					}
				case "fifo":
					if err := syscall.Mkfifo(d.storePath, 0o600); err != nil {
						t.Fatal(err)
					}
				case "directory":
					if err := os.Mkdir(d.storePath, 0o700); err != nil {
						t.Fatal(err)
					}
				}
				if phase == "snapshot" {
					d.needsSnapshot = true
				}
				done := make(chan error, 1)
				go func() {
					if phase == "startup" {
						done <- newDedupRing(8, d.storePath, "", nil).loadErr
						return
					}
					_, _, err := d.reserve("new", testDispatchDigest("new"))
					done <- err
				}()
				select {
				case err := <-done:
					if err == nil {
						t.Fatal("nonregular store was accepted")
					}
				case <-time.After(2 * time.Second):
					t.Fatal("nonregular store blocked inside open")
				}
				if !reflect.DeepEqual(before, d.records) {
					t.Fatal("refusal changed committed memory")
				}
				got, err := os.ReadFile(target)
				if err != nil || !bytes.Equal(got, original) {
					t.Fatalf("followed or overwrote unrelated target: %v", err)
				}
			})
		}
	}
}

func TestDedupStoreSecuresExistingAppendFile(t *testing.T) {
	d := newDedupStoreFixture(t)
	if err := os.Chmod(d.storePath, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := d.reserve("new", testDispatchDigest("new")); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(d.storePath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("append permissions=%v err=%v", info, err)
	}
	assertDedupRestartMatches(t, d)
}

func TestDedupStoreCommitBarrierPrecedesMemoryPublication(t *testing.T) {
	for _, operation := range []string{"reserve", "complete", "acknowledge"} {
		t.Run(operation, func(t *testing.T) {
			d := newDedupStoreFixture(t)
			before := maps.Clone(d.records)
			syncs := 0
			d.openAppend = func(path string) (dispatchFile, error) {
				file, err := openSecureLocalAppend(path)
				if err != nil {
					return nil, err
				}
				return &faultDispatchFile{dispatchFile: file, sync: func() error {
					syncs++
					// The hook runs under the ring mutex; no concurrent map read.
					if !reflect.DeepEqual(before, d.records) {
						t.Fatal("published before file Sync")
					}
					return file.Sync()
				}}, nil
			}
			if err := performDedupTestTransition(d, operation); err != nil {
				t.Fatal(err)
			}
			if syncs != 1 || reflect.DeepEqual(before, d.records) {
				t.Fatalf("commit publication or Sync count incorrect: %d", syncs)
			}
			assertDedupRestartMatches(t, d)
		})
	}
}

func TestDedupStorePostCommitStatFailureRequiresSnapshotNotDuplicate(t *testing.T) {
	for _, failure := range []string{"error", "unexpected size"} {
		t.Run(failure, func(t *testing.T) {
			d := newDedupStoreFixture(t)
			before := d.backing
			d.openAppend = func(path string) (dispatchFile, error) {
				file, err := openSecureLocalAppend(path)
				if err != nil {
					return nil, err
				}
				calls := 0
				return &faultDispatchFile{dispatchFile: file, stat: func() (os.FileInfo, error) {
					calls++
					if calls == 2 {
						if failure == "unexpected size" {
							return before, nil
						}
						return nil, errors.New("injected stat after Sync")
					}
					return file.Stat()
				}}, nil
			}
			if err := performDedupTestTransition(d, "reserve"); err != nil {
				t.Fatal(err)
			}
			if !d.needsSnapshot || !d.contains("new") {
				t.Fatal("committed reservation not retained pending snapshot")
			}
			assertDedupRestartMatches(t, d)
			d.openAppend = nil
			if err := performDedupTestTransition(d, "complete"); err != nil {
				t.Fatal(err)
			}
			assertDedupRestartMatches(t, d)
		})
	}
}

func TestDedupStoreSnapshotMetadataFailureRetainsCommittedMemory(t *testing.T) {
	d := newDedupStoreFixture(t)
	before := maps.Clone(d.records)
	d.needsSnapshot = true
	d.replaceFile = func(path string, write func(io.Writer) error) error {
		if err := fsutil.ReplaceFile(path, write); err != nil {
			return err
		}
		// The namespace becomes unavailable before metadata can be established.
		return os.Remove(path)
	}
	if err := performDedupTestTransition(d, "reserve"); err == nil {
		t.Fatal("accepted snapshot without baseline metadata")
	}
	if !d.needsSnapshot || !reflect.DeepEqual(before, d.records) {
		t.Fatal("metadata failure changed committed state")
	}
	d.replaceFile = nil
	if err := performDedupTestTransition(d, "reserve"); err != nil {
		t.Fatal(err)
	}
	assertDedupRestartMatches(t, d)
}
