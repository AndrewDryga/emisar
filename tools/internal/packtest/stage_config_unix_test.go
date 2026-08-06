//go:build !windows

package packtest

import (
	"bytes"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// The runner refuses a config owned by neither root nor the running process, or
// one writable by group or other, because whoever holds that write bit chooses
// the packs it loads. The harness used to point it at /workspace — a read-only
// bind mount of the repository checkout, carrying the HOST's ownership — so on
// CI every one of the 42 behavior packs failed on that check at once, while a
// workstation saw nothing because Docker Desktop remaps bind-mount ownership.
// Pin what the staged copy must satisfy so the harness cannot drift back.
func TestStageConfigProducesAConfigTheRunnerAccepts(t *testing.T) {
	source := filepath.Join(t.TempDir(), "test-config.yaml")
	contents := []byte("env_allowlist:\n  - CADDY_URL\n")
	if err := os.WriteFile(source, contents, 0o644); err != nil {
		t.Fatal(err)
	}

	staged, err := stageConfig(source)
	if err != nil {
		t.Fatalf("stageConfig: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(filepath.Dir(staged)) })

	if staged == source {
		t.Fatal("staged the source itself; the mount's ownership is the whole problem")
	}

	got, err := os.ReadFile(staged)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, contents) {
		t.Fatalf("staged contents = %q, want %q", got, contents)
	}

	info, err := os.Stat(staged)
	if err != nil {
		t.Fatal(err)
	}
	// The two rules in runner/internal/config/loader.go.
	if perm := info.Mode().Perm(); perm&0o022 != 0 {
		t.Errorf("staged config mode = %#o is group/other-writable; the runner refuses it", perm)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("no syscall.Stat_t; cannot verify the ownership this test exists for")
	}
	if owner := int(stat.Uid); owner != 0 && owner != os.Geteuid() {
		t.Errorf("staged config owned by uid %d, neither root nor this process (uid %d)",
			owner, os.Geteuid())
	}
}

// A stale copy from an earlier run must not leave a permissive mode behind.
func TestStageConfigIsNotReusedAcrossRuns(t *testing.T) {
	source := filepath.Join(t.TempDir(), "test-config.yaml")
	if err := os.WriteFile(source, []byte("env_allowlist: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	first, err := stageConfig(source)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(filepath.Dir(first)) })
	second, err := stageConfig(source)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(filepath.Dir(second)) })

	if first == second {
		t.Errorf("both runs staged %s; a shared path is what lets another user pre-create it", first)
	}
}
