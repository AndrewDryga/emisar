package catalog

import (
	"archive/tar"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/packs"
)

func buildFixtureCatalog(t *testing.T) (*packs.Registry, *Catalog) {
	t.Helper()
	reg := loadReg(t, threePackRoot(t))
	cat, err := Build(reg, BuildOptions{BaseURL: testBaseURL})
	if err != nil {
		t.Fatal(err)
	}
	return reg, cat
}

func TestWrite_ObjectSetAndImmutability(t *testing.T) {
	reg, cat := buildFixtureCatalog(t)
	out := t.TempDir()
	m, err := Write(reg, cat, out)
	if err != nil {
		t.Fatalf("Write: %v", err)
	}

	byPath := map[string]Object{}
	for _, o := range m.Objects {
		byPath[o.Path] = o
		// Every listed object exists on disk.
		if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(o.Path))); err != nil {
			t.Errorf("object %s not written: %v", o.Path, err)
		}
	}

	// Mutable pointers.
	for _, p := range []string{"v1/catalog.json", "v1/suggest.json"} {
		o, ok := byPath[p]
		if !ok {
			t.Fatalf("missing %s", p)
		}
		if o.Immutable {
			t.Errorf("%s should be a mutable pointer", p)
		}
	}

	// Content-addressed snapshot named after the catalog hash, immutable.
	snapshot := "v1/catalog/" + m.CatalogHash + ".json"
	if o, ok := byPath[snapshot]; !ok || !o.Immutable {
		t.Errorf("catalog snapshot %s missing or not immutable", snapshot)
	}

	// Schemas immutable.
	for _, name := range []string{"catalog.schema.json", "pack.schema.json", "action.schema.json"} {
		o, ok := byPath["v1/schemas/"+name]
		if !ok || !o.Immutable {
			t.Errorf("schema %s missing or not immutable", name)
		}
	}

	// One immutable tarball per pack, at the content-addressed path.
	for _, p := range cat.Packs {
		path := TarballObject(p.ID, p.Version, p.ContentHash)
		o, ok := byPath[path]
		if !ok || !o.Immutable {
			t.Errorf("tarball %s missing or not immutable", path)
		}
		if o.ContentType != contentTypeGzip {
			t.Errorf("tarball %s content-type = %s", path, o.ContentType)
		}
	}

	// manifest.json is written but NOT itself a published object.
	if _, err := os.Stat(filepath.Join(out, "manifest.json")); err != nil {
		t.Errorf("manifest.json not written: %v", err)
	}
	if _, listed := byPath["manifest.json"]; listed {
		t.Error("manifest.json must not list itself as a published object")
	}
}

func TestWrite_TarballRoundTripsToContentHash(t *testing.T) {
	reg, cat := buildFixtureCatalog(t)
	out := t.TempDir()
	if _, err := Write(reg, cat, out); err != nil {
		t.Fatal(err)
	}

	for _, p := range cat.Packs {
		tb := filepath.Join(out, filepath.FromSlash(TarballObject(p.ID, p.Version, p.ContentHash)))
		extracted := extractTarball(t, tb)
		re, err := packs.LoadOne(extracted, packs.LoadOptions{})
		if err != nil {
			t.Fatalf("reload extracted %s: %v", p.ID, err)
		}
		got, _ := re.PackHash(p.ID)
		if got != p.ContentHash {
			t.Errorf("pack %s: extracted tarball hash %s != catalog %s", p.ID, got, p.ContentHash)
		}
	}
}

func TestWrite_Deterministic(t *testing.T) {
	reg, cat := buildFixtureCatalog(t)
	a, b := t.TempDir(), t.TempDir()
	m1, err := Write(reg, cat, a)
	if err != nil {
		t.Fatal(err)
	}
	m2, err := Write(reg, cat, b)
	if err != nil {
		t.Fatal(err)
	}
	if m1.CatalogHash != m2.CatalogHash {
		t.Fatalf("catalog hash not deterministic: %s vs %s", m1.CatalogHash, m2.CatalogHash)
	}
	// Tarballs byte-identical across builds (idempotent republish).
	for _, p := range cat.Packs {
		rel := filepath.FromSlash(TarballObject(p.ID, p.Version, p.ContentHash))
		if !sameFile(t, filepath.Join(a, rel), filepath.Join(b, rel)) {
			t.Errorf("tarball for %s not byte-identical across builds", p.ID)
		}
	}
}

func extractTarball(t *testing.T, path string) string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	defer gz.Close()
	dest := t.TempDir()
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		out := filepath.Join(dest, filepath.FromSlash(hdr.Name))
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			t.Fatal(err)
		}
		data := make([]byte, hdr.Size)
		if _, err := io.ReadFull(tr, data); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(out, data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dest
}

func sameFile(t *testing.T, a, b string) bool {
	t.Helper()
	da, err := os.ReadFile(a)
	if err != nil {
		t.Fatal(err)
	}
	db, err := os.ReadFile(b)
	if err != nil {
		t.Fatal(err)
	}
	return string(da) == string(db)
}
