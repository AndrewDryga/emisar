package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/catalog"
)

// `packctl catalog build` writes the artifact tree and (with --json) the
// manifest. Driven end-to-end against a temp packs dir.
func TestPackCatalogBuildCmd(t *testing.T) {
	packsDir := t.TempDir()
	writeValidPack(t, packsDir, "redis")
	out := filepath.Join(t.TempDir(), "dist")
	withJSONOut(t, true)

	var execErr error
	stdout := captureStdout(t, func() {
		cmd := packCatalogBuildCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"--packs", packsDir, "--out", out, "--base-url", "https://cdn.example"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("catalog build: %v", execErr)
	}

	var m catalog.Manifest
	if err := json.Unmarshal([]byte(stdout), &m); err != nil {
		t.Fatalf("manifest JSON: %v\n%s", err, stdout)
	}
	if m.CatalogHash == "" || len(m.Objects) == 0 {
		t.Fatalf("empty manifest: %+v", m)
	}
	for _, want := range []string{"v1/catalog.json", "v1/suggest.json"} {
		if _, err := os.Stat(filepath.Join(out, want)); err != nil {
			t.Errorf("missing %s: %v", want, err)
		}
	}
}

// `catalog build` errors clearly when the packs dir has no packs.
func TestPackCatalogBuildCmd_NoPacks(t *testing.T) {
	empty := t.TempDir()
	cmd := packCatalogBuildCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--packs", empty, "--out", filepath.Join(t.TempDir(), "d")})
	if err := cmd.Execute(); err == nil {
		t.Fatal("expected error for an empty packs dir")
	}
}

// `catalog publish --dry-run` runs without a token or network.
func TestPackCatalogPublishCmd_DryRun(t *testing.T) {
	packsDir := t.TempDir()
	writeValidPack(t, packsDir, "redis")
	dist := filepath.Join(t.TempDir(), "dist")

	build := packCatalogBuildCmd()
	build.SilenceUsage, build.SilenceErrors = true, true
	build.SetArgs([]string{"--packs", packsDir, "--out", dist, "--base-url", "https://cdn.example"})
	if err := build.Execute(); err != nil {
		t.Fatalf("build: %v", err)
	}

	t.Setenv("GOOGLE_OAUTH_ACCESS_TOKEN", "")
	pub := packCatalogPublishCmd()
	pub.SilenceUsage, pub.SilenceErrors = true, true
	pub.SetArgs([]string{"--dir", dist, "--bucket", "b", "--dry-run"})
	if err := pub.Execute(); err != nil {
		t.Fatalf("dry-run publish should succeed without a token: %v", err)
	}
}
