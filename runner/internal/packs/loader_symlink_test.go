package packs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const minimalEcho = `
schema_version: 1
id: t.echo
title: Echo
kind: exec
risk: low
description: d
side_effects: [none]
args:
  - name: msg
    type: string
    required: true
execution:
  command:
    binary: echo
    argv: ["{{ args.msg }}"]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

const minimalPack = `schema_version: 1
id: testpack
name: testpack
version: 0.0.1
description: t
actions:
  - actions/echo.yaml
`

// TestSymlinkRejected_ActionYAML — a symlinked action file inside the
// pack must be rejected by default. The lexical isUnder check passes
// (the symlink path is under pack root), but EvalSymlinks resolves the
// target outside, and the Lstat-based "is the segment a symlink" check
// rejects it.
func TestSymlinkRejected_ActionYAML(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "real.yaml"), []byte(minimalEcho), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "real.yaml"), filepath.Join(root, "actions", "echo.yaml")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "pack.yaml"), []byte(minimalPack), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := LoadAll([]string{root}, LoadOptions{})
	if err == nil {
		t.Fatal("expected symlink action YAML to be rejected")
	}
	if !strings.Contains(err.Error(), "symlink") && !strings.Contains(err.Error(), "escapes pack root") {
		t.Fatalf("expected symlink/escape error, got %v", err)
	}
}

// TestSymlinkAccepted_WhenOptedIn — an action YAML symlink is accepted when
// the pack opts in via allow_symlinks: true. The target sits inside the pack:
// a target escaping the pack root is refused even with the opt-in
// (TestLoad_SymlinkEscapingRootRejectedAfterEvalSymlinks).
func TestSymlinkAccepted_WhenOptedIn(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "real")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nested, "echo.yaml"), []byte(minimalEcho), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(nested, "echo.yaml"), filepath.Join(root, "actions", "echo.yaml")); err != nil {
		t.Fatal(err)
	}

	pack := `schema_version: 1
id: testpack
name: testpack
version: 0.0.1
description: t
allow_symlinks: true
actions:
  - actions/echo.yaml
`
	if err := os.WriteFile(filepath.Join(root, "pack.yaml"), []byte(pack), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := LoadAll([]string{root}, LoadOptions{}); err != nil {
		t.Fatalf("expected symlink to be allowed under allow_symlinks, got %v", err)
	}
}

// A pack.yaml that cannot be stat'ed for a reason other than absence (here a
// self-referential symlink: ELOOP, deterministic even as root) is a broken
// pack, not "not a pack". Fail-fast loads refuse it; SkipBrokenPacks reports
// it as degraded and keeps loading healthy siblings. Before, the pack silently
// vanished from the registry with nothing in Degraded.
func TestLoadAll_UnstatableManifestIsBrokenNotAbsent(t *testing.T) {
	loopManifest := func(t *testing.T, dir string) {
		t.Helper()
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		manifest := filepath.Join(dir, "pack.yaml")
		if err := os.Symlink(manifest, manifest); err != nil {
			t.Fatal(err)
		}
	}

	t.Run("child pack", func(t *testing.T) {
		parent := t.TempDir()
		writePack(t, parent, "good", map[string]string{
			"pack.yaml":      packYAML("good"),
			"actions/a.yaml": actionYAML("good.a"),
		})
		broken := filepath.Join(parent, "broken")
		loopManifest(t, broken)

		if _, err := LoadAll([]string{parent}, LoadOptions{}); err == nil || !strings.Contains(err.Error(), "pack.yaml") {
			t.Fatalf("fail-fast load should refuse the unstatable manifest, got %v", err)
		}
		reg, err := LoadAll([]string{parent}, LoadOptions{SkipBrokenPacks: true})
		if err != nil {
			t.Fatalf("SkipBrokenPacks load: %v", err)
		}
		if loaded := reg.Packs(); len(loaded) != 1 || loaded[0].ID != "good" {
			t.Fatalf("loaded packs=%v, want only good", loaded)
		}
		if degraded := reg.Degraded(); len(degraded) != 1 || degraded[0].Dir != broken || degraded[0].Reason == "" {
			t.Fatalf("degraded=%v, want the broken pack dir with a reason", degraded)
		}
	})

	t.Run("configured root", func(t *testing.T) {
		root := filepath.Join(t.TempDir(), "pack")
		loopManifest(t, root)

		if _, err := LoadAll([]string{root}, LoadOptions{}); err == nil || !strings.Contains(err.Error(), "pack.yaml") {
			t.Fatalf("fail-fast load should refuse the unstatable manifest, got %v", err)
		}
		reg, err := LoadAll([]string{root}, LoadOptions{SkipBrokenPacks: true})
		if err != nil {
			t.Fatalf("SkipBrokenPacks load: %v", err)
		}
		if degraded := reg.Degraded(); len(degraded) != 1 || degraded[0].Dir != root {
			t.Fatalf("degraded=%v, want the configured root", degraded)
		}
	})

	t.Run("missing manifest is still not a pack", func(t *testing.T) {
		parent := t.TempDir()
		if err := os.MkdirAll(filepath.Join(parent, "notes"), 0o755); err != nil {
			t.Fatal(err)
		}
		reg, err := LoadAll([]string{parent}, LoadOptions{})
		if err != nil {
			t.Fatalf("a directory without pack.yaml must be skipped: %v", err)
		}
		if len(reg.Packs()) != 0 || len(reg.Degraded()) != 0 {
			t.Fatalf("packs=%v degraded=%v, want none", reg.Packs(), reg.Degraded())
		}
	})
}
