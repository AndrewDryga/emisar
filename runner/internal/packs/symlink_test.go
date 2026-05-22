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
    binary: /bin/echo
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

// TestSymlinkAccepted_WhenOptedIn — same setup but the pack opts in via
// allow_symlinks: true; loader accepts it.
func TestSymlinkAccepted_WhenOptedIn(t *testing.T) {
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
	// IMPORTANT: even with allow_symlinks, the EvalSymlinks containment
	// re-check would still reject this because the resolved target is
	// outside resolvedRoot. So this test reuses the outside path as
	// nested inside the pack instead.
	nested := filepath.Join(root, "real")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	// Move the real.yaml inside the pack and update the symlink.
	if err := os.WriteFile(filepath.Join(nested, "echo.yaml"), []byte(minimalEcho), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "actions", "echo.yaml")); err != nil {
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
