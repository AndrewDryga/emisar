//go:build darwin || dragonfly || freebsd || illumos || linux || netbsd || openbsd

package audit

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestJSONL_LockTimeoutLeavesSinkRetryable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	sink, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer sink.Close()
	lock, err := lockJournal(path)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := sink.Write(context.Background(), Event{EventID: "blocked"}); !errors.Is(err, syscall.EWOULDBLOCK) {
		t.Fatalf("contended write = %v, want lock timeout", err)
	}
	if info, err := os.Stat(path); err != nil || info.Size() != 0 {
		t.Fatalf("timed-out write modified journal: %v, %v", info, err)
	}
	if err := lock.Close(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := sink.Write(ctx, Event{EventID: "cancelled", Type: EventActionCancelled}); err != nil {
		t.Fatalf("cancellation receipt after contention: %v", err)
	}
	assertSharedJournal(t, path, 1)
}

func TestJSONL_RefusesUnsafeFiles(t *testing.T) {
	for _, suffix := range []string{"", ".lock"} {
		for _, kind := range []string{"symlink", "fifo"} {
			t.Run(suffix+"/"+kind, func(t *testing.T) {
				dir := t.TempDir()
				path := filepath.Join(dir, "events.jsonl")
				target := filepath.Join(dir, "untouched")
				if err := os.WriteFile(target, []byte("keep me"), 0o644); err != nil {
					t.Fatal(err)
				}
				var err error
				if kind == "symlink" {
					err = os.Symlink(target, path+suffix)
				} else {
					err = syscall.Mkfifo(path+suffix, 0o600)
				}
				if err != nil {
					t.Fatal(err)
				}
				if sink, err := OpenJSONL(path, JSONLOptions{}); err == nil {
					_ = sink.Close()
					t.Fatal("opened unsafe journal path")
				}
				body, err := os.ReadFile(target)
				if err != nil || string(body) != "keep me" {
					t.Fatalf("changed symlink target: %q, %v", body, err)
				}
				info, err := os.Stat(target)
				if err != nil || info.Mode().Perm() != 0o644 {
					t.Fatalf("changed target permissions: %v, %v", info, err)
				}
			})
		}
	}
}

func TestJSONL_RootPreservesServiceOwnership(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires root to exercise the service-user/root-CLI ownership boundary")
	}
	dir := t.TempDir()
	if err := os.Chown(dir, 65534, 65534); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "events.jsonl")
	sink, err := OpenJSONL(path, JSONLOptions{MaxSizeBytes: 1, MaxBackups: 1})
	if err != nil {
		t.Fatal(err)
	}
	defer sink.Close()
	for _, id := range []string{"first", "rotated"} {
		if err := sink.Write(context.Background(), Event{EventID: id}); err != nil {
			t.Fatal(err)
		}
	}
	for _, file := range []string{path, path + ".1", path + ".lock"} {
		info, err := os.Stat(file)
		if err != nil {
			t.Fatal(err)
		}
		stat := info.Sys().(*syscall.Stat_t)
		if stat.Uid != 65534 || stat.Gid != 65534 || info.Mode().Perm() != 0o600 {
			t.Errorf("%s: uid/gid/mode = %d/%d/%o, want 65534/65534/600", file, stat.Uid, stat.Gid, info.Mode().Perm())
		}
	}
}
