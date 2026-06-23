package packs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// packYAMLWithAction builds a pack.yaml that points its single action at an
// arbitrary relpath — used to drive the action-path containment checks with
// absolute / traversal / escaping references the normal helper can't express.
func packYAMLWithAction(id, actionRel string) string {
	return `schema_version: 1
id: ` + id + `
name: t
version: 0.0.1
description: t
actions:
  - ` + actionRel + `
`
}

const scriptActionYAML = `
schema_version: 1
id: %s
title: t
kind: script
risk: low
description: d
side_effects: [none]
args: []
execution:
  script:
    path: scripts/run.sh
    interpreter: /bin/sh
  argv: []
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

// RSEC-009-T04 — an absolute or empty action `rel` is rejected up front by
// resolveInsidePack, before any file read.
func TestLoad_AbsoluteOrEmptyActionPathRejected(t *testing.T) {
	t.Run("absolute path", func(t *testing.T) {
		root := writePack(t, t.TempDir(), "p", map[string]string{
			"pack.yaml": packYAMLWithAction("p", "/etc/passwd"),
		})
		_, err := LoadOne(root, LoadOptions{})
		if err == nil || !strings.Contains(err.Error(), "must be relative") {
			t.Fatalf("expected an absolute-path rejection, got %v", err)
		}
	})

	t.Run("empty path", func(t *testing.T) {
		// A pack.yaml listing an empty action entry: the YAML carries an
		// explicit empty-string list item so the path reaches resolveInsidePack.
		manifest := "schema_version: 1\nid: p\nname: t\nversion: 0.0.1\ndescription: t\nactions:\n  - \"\"\n"
		root := writePack(t, t.TempDir(), "p", map[string]string{"pack.yaml": manifest})
		_, err := LoadOne(root, LoadOptions{})
		if err == nil || !strings.Contains(err.Error(), "is empty") {
			t.Fatalf("expected an empty-path rejection, got %v", err)
		}
	})
}

// RSEC-009-T05 — a `..`-traversal action relpath is rejected lexically by
// isUnder, even before EvalSymlinks.
func TestLoad_TraversalActionPathRejected(t *testing.T) {
	// The escape target genuinely exists outside the pack so the failure is
	// the containment check, not a missing-file error.
	tmp := t.TempDir()
	if err := os.WriteFile(filepath.Join(tmp, "outside.yaml"), []byte(actionYAML("p.a")), 0o644); err != nil {
		t.Fatal(err)
	}
	root := writePack(t, tmp, "p", map[string]string{
		"pack.yaml": packYAMLWithAction("p", "../outside.yaml"),
	})
	_, err := LoadOne(root, LoadOptions{})
	if err == nil || !strings.Contains(err.Error(), "escapes pack root") {
		t.Fatalf("expected a pack-root escape rejection, got %v", err)
	}
}

// RSEC-009-T06 — a symlink *inside* the pack whose target resolves *outside*
// the root passes the lexical isUnder check but is rejected by the
// post-EvalSymlinks containment re-check. allow_symlinks:true is set so the
// earlier Lstat "is a symlink" guard is skipped, isolating the EvalSymlinks
// containment as the rejecting check.
func TestLoad_SymlinkEscapingRootRejectedAfterEvalSymlinks(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "real.yaml"), []byte(actionYAML("p.a")), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Symlink lives inside the pack (actions/a.yaml) but points outside it.
	if err := os.Symlink(filepath.Join(outside, "real.yaml"), filepath.Join(root, "actions", "a.yaml")); err != nil {
		t.Fatal(err)
	}
	manifest := packYAMLWithAction("p", "actions/a.yaml")
	manifest = strings.Replace(manifest, "description: t\n", "description: t\nallow_symlinks: true\n", 1)
	if err := os.WriteFile(filepath.Join(root, "pack.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := LoadOne(root, LoadOptions{})
	if err == nil || !strings.Contains(err.Error(), "escapes pack root via symlink") {
		t.Fatalf("expected a post-EvalSymlinks containment rejection, got %v", err)
	}
}

// RSEC-009-T08 — symlinks ABOVE the pack root are not scanned. A pack reached
// through a symlinked parent directory (mirroring macOS's /var → /private/var)
// loads fine; only symlinks *between* root and the resolved file are rejected.
func TestLoad_SymlinkAboveRootIgnored(t *testing.T) {
	realParent := t.TempDir()
	packDir := writePack(t, realParent, "p", map[string]string{
		"pack.yaml":      packYAML("abovepack"),
		"actions/a.yaml": actionYAML("abovepack.a"),
	})

	// Point a sibling symlink at realParent and load the pack *through* it, so
	// the pack root's parent chain contains a symlink the loader must ignore.
	linkedParent := filepath.Join(t.TempDir(), "linked")
	if err := os.Symlink(realParent, linkedParent); err != nil {
		t.Fatal(err)
	}
	rootViaLink := filepath.Join(linkedParent, filepath.Base(packDir))

	reg, err := LoadOne(rootViaLink, LoadOptions{})
	if err != nil {
		t.Fatalf("a pack reached through an above-root symlink should load: %v", err)
	}
	if _, ok := reg.Action("abovepack.a"); !ok {
		t.Fatal("action not registered when loaded through an above-root symlink")
	}
}

// RSEC-009-T10 — two pack directories declaring the same pack id abort the
// load (fail closed), the pack-level analogue of duplicate action ids.
func TestLoad_DuplicatePackIDsAbort(t *testing.T) {
	tmp := t.TempDir()
	writePack(t, tmp, "one", map[string]string{
		"pack.yaml":      packYAML("samepack"),
		"actions/a.yaml": actionYAML("samepack.one"),
	})
	writePack(t, tmp, "two", map[string]string{
		"pack.yaml":      packYAML("samepack"),
		"actions/a.yaml": actionYAML("samepack.two"),
	})
	_, err := LoadAll([]string{tmp}, LoadOptions{})
	if err == nil || !strings.Contains(err.Error(), "duplicate pack id") {
		t.Fatalf("expected a duplicate pack id error, got %v", err)
	}
}

// RSEC-009-T15 — discovery handles both shapes: a configured path that *is* a
// pack (contains pack.yaml), and a parent path whose immediate children are
// packs.
func TestLoad_DiscoveryDirectVsParentScan(t *testing.T) {
	t.Run("path is a single pack", func(t *testing.T) {
		root := writePack(t, t.TempDir(), "solo", map[string]string{
			"pack.yaml":      packYAML("solo"),
			"actions/a.yaml": actionYAML("solo.a"),
		})
		reg, err := LoadAll([]string{root}, LoadOptions{})
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := reg.Action("solo.a"); !ok {
			t.Fatal("single-pack path did not load its action")
		}
	})

	t.Run("path is a parent of many packs", func(t *testing.T) {
		parent := t.TempDir()
		writePack(t, parent, "alpha", map[string]string{
			"pack.yaml":      packYAML("alpha"),
			"actions/a.yaml": actionYAML("alpha.a"),
		})
		writePack(t, parent, "beta", map[string]string{
			"pack.yaml":      packYAML("beta"),
			"actions/a.yaml": actionYAML("beta.a"),
		})
		reg, err := LoadAll([]string{parent}, LoadOptions{})
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := reg.Action("alpha.a"); !ok {
			t.Fatal("parent scan missed alpha.a")
		}
		if _, ok := reg.Action("beta.a"); !ok {
			t.Fatal("parent scan missed beta.a")
		}
	})
}

// RSEC-009-T16 — a configured path that is a regular file errors; a
// non-existent path is silently skipped (not every configured dir need exist).
func TestLoad_NonDirErrorsAndMissingSkipped(t *testing.T) {
	t.Run("file path errors", func(t *testing.T) {
		f := filepath.Join(t.TempDir(), "afile")
		if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		_, err := LoadAll([]string{f}, LoadOptions{})
		if err == nil || !strings.Contains(err.Error(), "is not a directory") {
			t.Fatalf("expected a not-a-directory error, got %v", err)
		}
	})

	t.Run("missing path skipped", func(t *testing.T) {
		missing := filepath.Join(t.TempDir(), "does-not-exist")
		reg, err := LoadAll([]string{missing}, LoadOptions{})
		if err != nil {
			t.Fatalf("a missing pack dir should be skipped, got %v", err)
		}
		if len(reg.Packs()) != 0 {
			t.Fatalf("expected an empty registry, got %d packs", len(reg.Packs()))
		}
	})
}

// RSEC-009-T17 — pack.yaml and action structs are Validate()'d after parse;
// a structurally-malformed manifest/action fails the load.
func TestLoad_StructsValidatedAfterParse(t *testing.T) {
	t.Run("pack missing required field", func(t *testing.T) {
		// Drop the required `name` field — Validate() must reject it.
		manifest := "schema_version: 1\nid: p\nversion: 0.0.1\ndescription: t\nactions:\n  - actions/a.yaml\n"
		root := writePack(t, t.TempDir(), "p", map[string]string{
			"pack.yaml":      manifest,
			"actions/a.yaml": actionYAML("p.a"),
		})
		_, err := LoadOne(root, LoadOptions{})
		if err == nil || !strings.Contains(err.Error(), "missing name") {
			t.Fatalf("expected a pack validation error, got %v", err)
		}
	})

	t.Run("action missing required field", func(t *testing.T) {
		// An action with no title fails actionspec.Action.Validate().
		bad := "schema_version: 1\nid: p.a\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\nargs: []\nexecution:\n  command:\n    binary: /bin/echo\n    argv: []\n  timeout: 5s\noutput:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"
		root := writePack(t, t.TempDir(), "p", map[string]string{
			"pack.yaml":      packYAML("p"),
			"actions/a.yaml": bad,
		})
		_, err := LoadOne(root, LoadOptions{})
		if err == nil || !strings.Contains(err.Error(), "missing title") {
			t.Fatalf("expected an action validation error, got %v", err)
		}
	})
}

// RSEC-009-T18 — a script-kind action gets its script SHA256 stamped at load,
// unless SkipScriptChecksum is set (used by tests where script bytes vary).
func TestLoad_ScriptChecksumStampedUnlessSkipped(t *testing.T) {
	files := map[string]string{
		"pack.yaml":      packYAML("scr"),
		"actions/a.yaml": strings.Replace(scriptActionYAML, "%s", "scr.run", 1),
		"scripts/run.sh": "#!/bin/sh\necho hi\n",
	}

	t.Run("checksum stamped by default", func(t *testing.T) {
		root := writePack(t, t.TempDir(), "p", files)
		reg, err := LoadOne(root, LoadOptions{})
		if err != nil {
			t.Fatal(err)
		}
		si, ok := reg.ScriptInfo("scr.run")
		if !ok {
			t.Fatal("script info not registered")
		}
		if si.SHA256 == "" {
			t.Fatal("expected a script SHA256 to be stamped at load")
		}
	})

	t.Run("checksum skipped with the flag", func(t *testing.T) {
		root := writePack(t, t.TempDir(), "p", files)
		reg, err := LoadOne(root, LoadOptions{SkipScriptChecksum: true})
		if err != nil {
			t.Fatal(err)
		}
		si, ok := reg.ScriptInfo("scr.run")
		if !ok {
			t.Fatal("script info not registered")
		}
		if si.SHA256 != "" {
			t.Fatalf("expected no SHA256 with SkipScriptChecksum, got %q", si.SHA256)
		}
	})
}
