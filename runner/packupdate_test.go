package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/packs"
)

func TestFetchPackIndex_ParsesIndex(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/packs.json" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"packs":[
			{"id":"redis","version":"0.2.4","hash":"sha256:aaa","tarball":"x"},
			{"id":"postgres","version":"0.2.5","hash":"sha256:bbb"}
		]}`))
	}))
	defer srv.Close()

	idx, err := fetchPackIndex(context.Background(), srv.URL)
	if err != nil {
		t.Fatalf("fetchPackIndex: %v", err)
	}
	if len(idx) != 2 {
		t.Fatalf("want 2 packs, got %d", len(idx))
	}
	if idx["redis"].Hash != "sha256:aaa" || idx["redis"].Version != "0.2.4" {
		t.Errorf("redis entry = %+v", idx["redis"])
	}
}

func TestFetchPackIndex_HTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()
	if _, err := fetchPackIndex(context.Background(), srv.URL); err == nil {
		t.Fatal("expected error on HTTP 500")
	}
}

func TestUpdateOnePack_VerifiesHashAndSwapsAtomically(t *testing.T) {
	const id = "redis"
	srcDir := filepath.Join("examples", "packs", id)

	reg, err := packs.LoadOne(srcDir, packs.LoadOptions{})
	if err != nil {
		t.Fatalf("load source pack: %v", err)
	}
	hash, _ := reg.PackHash(id)
	tarball := tarDir(t, srcDir)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/packs/"+id+"/pack.tar.gz" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(tarball)
	}))
	defer srv.Close()

	dest := t.TempDir()
	installed := filepath.Join(dest, id)
	if err := os.MkdirAll(installed, 0o755); err != nil {
		t.Fatal(err)
	}
	// Sentinel from the "old" install, so we can tell a swap actually happened.
	if err := os.WriteFile(filepath.Join(installed, "OLD"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Wrong hash → rejected before any swap; the old install stays intact.
	bad := registryPack{ID: id, Hash: "sha256:" + strings.Repeat("1", 64)}
	if err := updateOnePack(context.Background(), id, dest, srv.URL, bad); err == nil {
		t.Fatal("expected hash-mismatch rejection")
	}
	if _, err := os.Stat(filepath.Join(installed, "OLD")); err != nil {
		t.Errorf("old install should be untouched on mismatch: %v", err)
	}

	// Correct hash → fetched pack swapped in.
	good := registryPack{ID: id, Version: "9.9.9", Hash: hash}
	if err := updateOnePack(context.Background(), id, dest, srv.URL, good); err != nil {
		t.Fatalf("updateOnePack: %v", err)
	}
	if _, err := os.Stat(filepath.Join(installed, "OLD")); !os.IsNotExist(err) {
		t.Error("sentinel should be gone after the swap")
	}
	if _, err := os.Stat(filepath.Join(installed, "pack.yaml")); err != nil {
		t.Errorf("updated pack should have pack.yaml: %v", err)
	}
	if _, err := os.Stat(installed + ".tmp-update"); !os.IsNotExist(err) {
		t.Error("staging dir should be cleaned up")
	}
}

// tarDir builds a gzip tarball of every regular file under root, with paths
// relative to root (so the pack files land at the tarball root).
func tarDir(t *testing.T, root string) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)

	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err := tw.WriteHeader(&tar.Header{
			Name:     rel,
			Mode:     0o644,
			Size:     int64(len(data)),
			Typeflag: tar.TypeReg,
		}); err != nil {
			return err
		}
		_, err = tw.Write(data)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}
