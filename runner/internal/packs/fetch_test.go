package packs

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// makeTarGz builds an in-memory gzip tarball from a name→content map.
func makeTarGz(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for name, content := range files {
		if err := tw.WriteHeader(&tar.Header{
			Name:     name,
			Mode:     0o644,
			Size:     int64(len(content)),
			Typeflag: tar.TypeReg,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestExtractTarGz_Roundtrip(t *testing.T) {
	data := makeTarGz(t, map[string]string{
		"pack.yaml":          "id: x\n",
		"actions/info.yaml":  "id: x.info\n",
		"actions/stats.yaml": "id: x.stats\n",
	})
	dest := t.TempDir()
	if err := extractTarGz(bytes.NewReader(data), dest); err != nil {
		t.Fatalf("extract: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dest, "actions", "info.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "id: x.info\n" {
		t.Errorf("info.yaml content = %q", got)
	}
}

func TestExtractTarGz_RejectsTraversal(t *testing.T) {
	for _, bad := range []string{"../escape.yaml", "/etc/passwd", "a/../../b.yaml"} {
		data := makeTarGz(t, map[string]string{bad: "x"})
		if err := extractTarGz(bytes.NewReader(data), t.TempDir()); err == nil {
			t.Errorf("expected rejection for entry %q, got nil", bad)
		}
	}
}

func TestExtractTarGz_RejectsSymlink(t *testing.T) {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	_ = tw.WriteHeader(&tar.Header{
		Name:     "evil",
		Typeflag: tar.TypeSymlink,
		Linkname: "/etc/passwd",
	})
	tw.Close()
	gz.Close()
	if err := extractTarGz(bytes.NewReader(buf.Bytes()), t.TempDir()); err == nil {
		t.Error("expected rejection for symlink entry")
	}
}

func TestFetch_DownloadsAndExtracts(t *testing.T) {
	data := makeTarGz(t, map[string]string{"pack.yaml": "id: redis\n"})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/packs/redis/pack.tar.gz" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/gzip")
		_, _ = w.Write(data)
	}))
	defer srv.Close()

	dir, cleanup, err := Fetch(context.Background(), srv.URL+"/packs/redis/pack.tar.gz", srv.Client())
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	defer cleanup()

	got, err := os.ReadFile(filepath.Join(dir, "pack.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "id: redis\n" {
		t.Errorf("pack.yaml = %q", got)
	}
}

func TestFetch_404IsClearError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer srv.Close()

	_, _, err := Fetch(context.Background(), srv.URL+"/packs/nope/pack.tar.gz", srv.Client())
	if err == nil {
		t.Fatal("expected 404 error")
	}
}
