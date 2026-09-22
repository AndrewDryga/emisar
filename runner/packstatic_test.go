package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/catalog"
	"github.com/andrewdryga/emisar/runner/internal/packs"
)

// Exercise the publisher's actual output, including its content-addressed
// tarballs and full-catalog packs.json alias. A static registry has no hosted
// /packs/<id>/pack.tar.gz redirect to hide reader/writer contract drift.
func staticRegistry(t *testing.T, source string) (baseURL, tarballPath string) {
	t.Helper()
	out := t.TempDir()
	srv := httptest.NewServer(http.FileServer(http.Dir(out)))
	t.Cleanup(srv.Close)
	reg, err := packs.LoadOne(source, packs.LoadOptions{})
	if err != nil {
		t.Fatal(err)
	}
	cat, err := catalog.Build(reg, catalog.BuildOptions{BaseURL: srv.URL})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := catalog.Write(reg, cat, out); err != nil {
		t.Fatal(err)
	}
	p := cat.Packs[0]
	return srv.URL, filepath.Join(out, filepath.FromSlash(catalog.TarballObject(p.ID, p.Version, p.ContentHash)))
}

func staticPack(t *testing.T, version, risk string) string {
	t.Helper()
	return writePackTree(t, map[string]string{
		"pack.yaml":      diffPackYAML(version, "actions/a.yaml"),
		"actions/a.yaml": diffActionYAML("redis.a", risk, ""),
	})
}

func TestStaticRegistryUpdateAndDiff(t *testing.T) {
	dest := t.TempDir()
	installed := filepath.Join(dest, "redis")
	if err := copyTree(staticPack(t, "0.3.0", "low"), installed); err != nil {
		t.Fatal(err)
	}
	oldHash := packHashOnDisk(t, installed, "redis")
	candidate := staticPack(t, "0.4.0", "medium")
	newHash := packHashOnDisk(t, candidate, "redis")
	registry, _ := staticRegistry(t, candidate)

	out, err := runUpdate(t, dest, registry, "--dry-run")
	if err != nil || !strings.Contains(out, "v0.3.0 → v0.4.0 (update available)") {
		t.Fatalf("dry-run: %v\n%s", err, out)
	}
	out, err = runDiff(t, dest, registry)
	if err != nil || !strings.Contains(out, "-risk: low") || !strings.Contains(out, "+risk: medium") {
		t.Fatalf("diff: %v\n%s", err, out)
	}
	if got := packHashOnDisk(t, installed, "redis"); got != oldHash {
		t.Fatal("preview changed the installed pack")
	}
	out, err = runUpdate(t, dest, registry)
	if err != nil || !strings.Contains(out, "v0.3.0 → v0.4.0 updated") {
		t.Fatalf("update: %v\n%s", err, out)
	}
	if got := packHashOnDisk(t, installed, "redis"); got != newHash {
		t.Fatalf("installed hash = %s, want %s", got, newHash)
	}
	before := mtime(t, filepath.Join(installed, "pack.yaml"))
	for _, args := range [][]string{{"--dry-run"}, nil} {
		out, err = runUpdate(t, dest, registry, args...)
		if err != nil || !strings.Contains(out, "up to date (v0.4.0)") {
			t.Fatalf("unchanged update %v: %v\n%s", args, err, out)
		}
	}
	if after := mtime(t, filepath.Join(installed, "pack.yaml")); after != before {
		t.Fatal("unchanged update rewrote the installed pack")
	}
}

func TestStaticRegistryRejectsChangedTarball(t *testing.T) {
	for _, command := range []string{"diff", "update"} {
		t.Run(command, func(t *testing.T) {
			dest := t.TempDir()
			installed := filepath.Join(dest, "redis")
			if err := copyTree(staticPack(t, "0.3.0", "low"), installed); err != nil {
				t.Fatal(err)
			}
			oldHash := packHashOnDisk(t, installed, "redis")
			registry, tarball := staticRegistry(t, staticPack(t, "0.4.0", "medium"))
			if err := os.WriteFile(tarball, tarDir(t, staticPack(t, "0.4.0", "high")), 0o644); err != nil {
				t.Fatal(err)
			}
			var out string
			var err error
			if command == "diff" {
				out, err = runDiff(t, dest, registry)
			} else {
				out, err = runUpdate(t, dest, registry)
			}
			if err == nil || !strings.Contains(out+err.Error(), "hash mismatch") {
				t.Fatalf("want hash mismatch, got %v\n%s", err, out)
			}
			if got := packHashOnDisk(t, installed, "redis"); got != oldHash {
				t.Fatal("rejected tarball changed the installed pack")
			}
		})
	}
}

func TestStaticRegistryDiffReportsMissingTarball(t *testing.T) {
	dest := t.TempDir()
	installPackInto(t, dest, "redis")
	registry, tarball := staticRegistry(t, staticPack(t, "0.4.0", "medium"))
	if err := os.Remove(tarball); err != nil {
		t.Fatal(err)
	}
	if out, err := runDiff(t, dest, registry); err == nil || !strings.Contains(err.Error(), "not found (404)") {
		t.Fatalf("want download error, got %v\n%s", err, out)
	}
}

func TestFetchPackIndexRejectsInvalidCatalogEntries(t *testing.T) {
	for _, tc := range []struct {
		name, entry, want string
	}{
		{"missing hash", `"tarball_url":"https://packs.example/redis.tgz"`, "missing content hash"},
		{"conflicting hashes", `"hash":"sha256:aaa","content_hash":"sha256:bbb"`, "conflicting content hashes"},
		{"local path", `"content_hash":"sha256:aaa","tarball_url":"/tmp/redis"`, "tarball URL"},
		{"file scheme", `"content_hash":"sha256:aaa","tarball_url":"file:///tmp/redis"`, "tarball URL"},
		{"insecure remote URL", `"content_hash":"sha256:aaa","tarball_url":"http://packs.example/redis.tgz"`, "tarball URL"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_, _ = fmt.Fprintf(w, `{"packs":[{"id":"redis","version":"0.4.0",%s}]}`, tc.entry)
			}))
			t.Cleanup(srv.Close)
			if _, err := fetchPackIndex(context.Background(), srv.URL); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want %q, got %v", tc.want, err)
			}
		})
	}
}
