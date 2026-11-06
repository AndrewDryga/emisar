package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
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
		cmd.SetArgs([]string{"--packs", packsDir, "--out", out, "--base-url", "https://cdn.example", "--repo-url", testRepoURL})
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

const testRepoURL = "https://git.example/infra/packs"

// A private registry's catalog names only the authorship its publisher
// declared. The build used to default the source repository and vendor to
// emisar's, so the guide's command credited every customer pack to emisar and
// linked it at a path in emisar's repository that does not exist.
func TestPackCatalogBuildCmd_CreditsOnlyDeclaredAuthorship(t *testing.T) {
	packsDir := t.TempDir()
	writeValidPack(t, packsDir, "redis")

	t.Run("--repo-url is required", func(t *testing.T) {
		cmd := packCatalogBuildCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"--packs", packsDir, "--out", filepath.Join(t.TempDir(), "dist"), "--base-url", "https://cdn.example"})
		if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), `"repo-url"`) {
			t.Fatalf("expected a missing --repo-url error, got %v", err)
		}
	})

	t.Run("the catalog links the declared repository and vendor", func(t *testing.T) {
		out := filepath.Join(t.TempDir(), "dist")
		withJSONOut(t, true)
		cmd := packCatalogBuildCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"--packs", packsDir, "--out", out, "--base-url", "https://cdn.example", "--repo-url", testRepoURL})
		var execErr error
		captureStdout(t, func() { execErr = cmd.Execute() })
		if execErr != nil {
			t.Fatalf("catalog build: %v", execErr)
		}

		body, err := os.ReadFile(filepath.Join(out, "v1/catalog.json"))
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(body), "andrewdryga") {
			t.Errorf("a private catalog links at emisar's repository:\n%s", body)
		}
		var cat catalog.Catalog
		if err := json.Unmarshal(body, &cat); err != nil {
			t.Fatalf("catalog JSON: %v", err)
		}
		if len(cat.Packs) != 1 {
			t.Fatalf("packs = %d, want 1", len(cat.Packs))
		}
		got := cat.Packs[0]
		if want := testRepoURL + "/tree/main/packs/redis"; got.SourceURL != want {
			t.Errorf("source_url = %q, want %q", got.SourceURL, want)
		}
		if got.Homepage != testRepoURL {
			t.Errorf("homepage = %q, want %q", got.Homepage, testRepoURL)
		}
		if got.Vendor != "acme" {
			t.Errorf("vendor = %q, want the declared acme", got.Vendor)
		}
	})
}

// `catalog build` errors clearly when the packs dir has no packs.
func TestPackCatalogBuildCmd_NoPacks(t *testing.T) {
	empty := t.TempDir()
	cmd := packCatalogBuildCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--packs", empty, "--out", filepath.Join(t.TempDir(), "d"), "--repo-url", testRepoURL})
	if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "no packs found") {
		t.Fatalf("expected a no-packs error for an empty packs dir, got %v", err)
	}
}

// `catalog publish --dry-run` runs without a token or network.
func TestPackCatalogPublishCmd_DryRun(t *testing.T) {
	packsDir := t.TempDir()
	writeValidPack(t, packsDir, "redis")
	dist := filepath.Join(t.TempDir(), "dist")

	build := packCatalogBuildCmd()
	build.SilenceUsage, build.SilenceErrors = true, true
	build.SetArgs([]string{"--packs", packsDir, "--out", dist, "--base-url", "https://cdn.example", "--repo-url", testRepoURL})
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

	// --dry-run promises to contact nothing and --check exists to read the
	// bucket, so asking for both has no honest answer.
	both := packCatalogPublishCmd()
	both.SilenceUsage, both.SilenceErrors = true, true
	both.SetArgs([]string{"--dir", dist, "--bucket", "b", "--dry-run", "--check"})
	if err := both.Execute(); err == nil {
		t.Fatal("--dry-run with --check should be refused")
	}
}
