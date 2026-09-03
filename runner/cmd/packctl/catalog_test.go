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
	for _, want := range []string{
		"v1/catalog.json",
		"v1/suggest.json",
		"packs.json",
		"packs/suggest.json",
	} {
		if _, err := os.Stat(filepath.Join(out, want)); err != nil {
			t.Errorf("missing %s: %v", want, err)
		}
	}
}

// The catalog schema requires source_url and homepage, and both are frozen at
// 1.0. A self-hosted registry must be able to set them: without --repo-url
// every pack in a third-party catalog links at emisar's GitHub repo, at a path
// that does not exist there.
func TestPackCatalogBuildCmd_RepoURLSetsSourceLinks(t *testing.T) {
	packsDir := t.TempDir()
	writeValidPack(t, packsDir, "redis")
	out := filepath.Join(t.TempDir(), "dist")
	withJSONOut(t, true)

	cmd := packCatalogBuildCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{
		"--packs", packsDir, "--out", out,
		"--base-url", "https://cdn.example", "--repo-url", "https://git.example/infra/packs",
	})
	var execErr error
	captureStdout(t, func() { execErr = cmd.Execute() })
	if execErr != nil {
		t.Fatalf("catalog build: %v", execErr)
	}

	body, err := os.ReadFile(filepath.Join(out, "v1/catalog.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cat catalog.Catalog
	if err := json.Unmarshal(body, &cat); err != nil {
		t.Fatalf("catalog JSON: %v", err)
	}
	if len(cat.Packs) != 1 {
		t.Fatalf("packs = %d, want 1", len(cat.Packs))
	}
	got := cat.Packs[0]
	if want := "https://git.example/infra/packs/tree/main/packs/redis"; got.SourceURL != want {
		t.Errorf("source_url = %q, want %q", got.SourceURL, want)
	}
	if want := "https://git.example/infra/packs"; got.Homepage != want {
		t.Errorf("homepage = %q, want %q", got.Homepage, want)
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

func TestLoadPreviousCatalog_AllowsOnlyTheLegacyGenerationOmission(t *testing.T) {
	packsDir := t.TempDir()
	writeValidPack(t, packsDir, "redis")
	dist := filepath.Join(t.TempDir(), "dist")

	build := packCatalogBuildCmd()
	build.SilenceUsage, build.SilenceErrors = true, true
	build.SetArgs([]string{"--packs", packsDir, "--out", dist, "--base-url", "https://cdn.example"})
	if err := build.Execute(); err != nil {
		t.Fatalf("build fixture: %v", err)
	}

	currentPath := filepath.Join(dist, "v1", "catalog.json")
	currentBytes, err := os.ReadFile(currentPath)
	if err != nil {
		t.Fatalf("read current catalog: %v", err)
	}
	var legacy map[string]any
	if err := json.Unmarshal(currentBytes, &legacy); err != nil {
		t.Fatalf("decode current catalog: %v", err)
	}
	delete(legacy, "generation")
	legacyBytes, err := json.Marshal(legacy)
	if err != nil {
		t.Fatalf("encode legacy catalog: %v", err)
	}
	legacyPath := filepath.Join(t.TempDir(), "legacy.json")
	if err := os.WriteFile(legacyPath, legacyBytes, 0o600); err != nil {
		t.Fatalf("write legacy catalog: %v", err)
	}

	previous, err := loadPreviousCatalog(legacyPath)
	if err != nil {
		t.Fatalf("load legacy predecessor: %v", err)
	}
	if previous.Generation != 0 {
		t.Fatalf("legacy generation = %d, want 0", previous.Generation)
	}
	if err := catalog.ValidateCatalogDocument(legacyBytes); err == nil {
		t.Fatal("legacy omission leaked into the current published schema")
	}

	legacy["generation"] = 0
	invalidBytes, err := json.Marshal(legacy)
	if err != nil {
		t.Fatalf("encode explicit zero generation: %v", err)
	}
	invalidPath := filepath.Join(t.TempDir(), "invalid.json")
	if err := os.WriteFile(invalidPath, invalidBytes, 0o600); err != nil {
		t.Fatalf("write invalid catalog: %v", err)
	}
	if _, err := loadPreviousCatalog(invalidPath); err == nil {
		t.Fatal("explicit generation zero should not use the legacy omission path")
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
