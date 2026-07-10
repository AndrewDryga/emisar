package catalog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/packs"
)

// --- fixtures ---------------------------------------------------------

func packYAML(id, version string, extra string) string {
	return "schema_version: 1\nid: " + id + "\nname: " + strings.ToUpper(id) +
		"\nversion: " + version + "\ndescription: the  " + id + "   pack\n" + extra +
		"actions:\n  - actions/a.yaml\n"
}

func execAction(id string) string {
	return `schema_version: 1
id: ` + id + `.read
title: Read thing
kind: exec
risk: low
description: reads
side_effects: [none]
args: []
execution:
  command:
    binary: cat
    argv: ["{{ args.path }}"]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`
}

// writePack writes one pack's files under root/<id>/.
func writePack(t *testing.T, root, id string, files map[string]string) {
	t.Helper()
	for rel, body := range files {
		full := filepath.Join(root, id, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func loadReg(t *testing.T, root string) *packs.Registry {
	t.Helper()
	reg, err := packs.LoadAll([]string{root}, packs.LoadOptions{})
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	return reg
}

// threePackRoot writes: alpha (generic-only requires → stripped detect),
// beta (explicit detect wins), remote (no detect signal → suggest omits it).
func threePackRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	writePack(t, root, "alpha", map[string]string{
		"pack.yaml":      packYAML("alpha", "1.0.0", "requires:\n  os: [linux]\n  binaries: [curl, alpha-tool]\n"),
		"actions/a.yaml": execAction("alpha"),
	})
	writePack(t, root, "beta", map[string]string{
		"pack.yaml": packYAML("beta", "2.1.0",
			"requires:\n  binaries: [curl]\ndetect:\n  binaries: [beta-bin]\n  processes: [betad]\n  ports: [1234]\n"),
		"actions/a.yaml": execAction("beta"),
	})
	writePack(t, root, "remote", map[string]string{
		"pack.yaml":      packYAML("remote", "0.1.0", "requires:\n  binaries: [curl]\n"),
		"actions/a.yaml": execAction("remote"),
	})
	return root
}

const testBaseURL = "https://cdn.example/registry"

// --- tests ------------------------------------------------------------

func TestBuild(t *testing.T) {
	reg := loadReg(t, threePackRoot(t))
	cat, err := Build(reg, BuildOptions{BaseURL: testBaseURL + "/"})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	if cat.SchemaVersion != SchemaVersion {
		t.Errorf("schema_version = %d, want %d", cat.SchemaVersion, SchemaVersion)
	}
	if len(cat.Packs) != 3 {
		t.Fatalf("got %d packs, want 3", len(cat.Packs))
	}
	// Sorted by id.
	if cat.Packs[0].ID != "alpha" || cat.Packs[1].ID != "beta" || cat.Packs[2].ID != "remote" {
		t.Fatalf("packs not sorted by id: %v", []string{cat.Packs[0].ID, cat.Packs[1].ID, cat.Packs[2].ID})
	}

	alpha := cat.Packs[0]
	wantHash, _ := reg.PackHash("alpha")
	if alpha.ContentHash != wantHash {
		t.Errorf("content_hash = %s, want %s (must match loader)", alpha.ContentHash, wantHash)
	}
	if alpha.Vendor != "emisar" {
		t.Errorf("vendor = %q, want default emisar", alpha.Vendor)
	}
	if alpha.Homepage != DefaultRepoURL {
		t.Errorf("homepage = %q, want default repo", alpha.Homepage)
	}
	if alpha.SourceURL != DefaultRepoURL+"/tree/main/packs/alpha" {
		t.Errorf("source_url = %q", alpha.SourceURL)
	}
	if alpha.Description != "the alpha pack" {
		t.Errorf("description = %q, want whitespace-collapsed", alpha.Description)
	}
	// BaseURL trailing slash trimmed; tarball path content-addressed.
	wantTarball := testBaseURL + "/v1/packs/alpha/1.0.0/" + strings.TrimPrefix(wantHash, "sha256:") + "/pack.tar.gz"
	if alpha.TarballURL != wantTarball {
		t.Errorf("tarball_url = %q, want %q", alpha.TarballURL, wantTarball)
	}
	// Generic helper stripped, real tool kept.
	if got := alpha.Detect.Binaries; len(got) != 1 || got[0] != "alpha-tool" {
		t.Errorf("alpha detect.binaries = %v, want [alpha-tool] (curl stripped)", got)
	}
	if len(alpha.Actions) != 1 || alpha.Actions[0].Command == nil || alpha.Actions[0].Command.Binary != "cat" {
		t.Errorf("alpha action command not carried: %+v", alpha.Actions)
	}

	// Explicit detect wins over requires-derived binaries.
	beta := cat.Packs[1]
	if got := beta.Detect.Binaries; len(got) != 1 || got[0] != "beta-bin" {
		t.Errorf("beta detect.binaries = %v, want [beta-bin]", got)
	}
	if len(beta.Detect.Ports) != 1 || beta.Detect.Ports[0] != 1234 {
		t.Errorf("beta detect.ports = %v, want [1234]", beta.Detect.Ports)
	}
}

func TestBuild_MissingBaseURL(t *testing.T) {
	reg := loadReg(t, threePackRoot(t))
	if _, err := Build(reg, BuildOptions{}); err == nil {
		t.Fatal("expected error when BaseURL is empty")
	}
}

func TestSuggest_OmitsDetectlessPacks(t *testing.T) {
	reg := loadReg(t, threePackRoot(t))
	cat, err := Build(reg, BuildOptions{BaseURL: testBaseURL})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, p := range cat.Suggest().Packs {
		got[p.ID] = true
	}
	if !got["alpha"] || !got["beta"] {
		t.Errorf("suggest should include alpha and beta, got %v", got)
	}
	if got["remote"] {
		t.Error("suggest must omit remote (no detect signal)")
	}
}

func TestBuild_DriftCheck(t *testing.T) {
	root := threePackRoot(t)
	base, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL})
	if err != nil {
		t.Fatal(err)
	}

	t.Run("same bytes same version passes", func(t *testing.T) {
		if _, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: base}); err != nil {
			t.Errorf("republish of identical packs should pass: %v", err)
		}
	})

	t.Run("changed bytes same version fails", func(t *testing.T) {
		// Mutate alpha's action WITHOUT bumping the version → new hash, same id+version.
		writePack(t, root, "alpha", map[string]string{
			"actions/a.yaml": strings.Replace(execAction("alpha"), "reads", "reads more", 1),
		})
		_, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: base})
		if err == nil {
			t.Fatal("expected drift error for changed bytes at same version")
		}
		if !strings.Contains(err.Error(), "alpha") || !strings.Contains(err.Error(), "bump the version") {
			t.Errorf("drift error should name the pack and advise a version bump: %v", err)
		}
	})

	t.Run("changed bytes with version bump passes", func(t *testing.T) {
		writePack(t, root, "alpha", map[string]string{
			"pack.yaml":      packYAML("alpha", "1.0.1", "requires:\n  os: [linux]\n  binaries: [curl, alpha-tool]\n"),
			"actions/a.yaml": strings.Replace(execAction("alpha"), "reads", "reads more", 1),
		})
		if _, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: base}); err != nil {
			t.Errorf("changed bytes at a new version should pass: %v", err)
		}
	})
}
