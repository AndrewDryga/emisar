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
	"strings"
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

// A registry tarball carries pack scripts executable (catalog.Tarball marks
// every .sh 0755). Extraction must honor that bit — an action whose binary IS
// the script fails EACCES otherwise — while never adopting the archive's raw
// mode, so setuid/setgid bits cannot ride in from a hostile tarball.
func TestExtractTarGz_HonorsExecutableBitOnly(t *testing.T) {
	entries := []struct {
		name string
		mode int64
		exec bool
	}{
		{name: "scripts/pureget.sh", mode: 0o755, exec: true},
		{name: "pack.yaml", mode: 0o644, exec: false},
		{name: "scripts/setuid.sh", mode: 0o4755, exec: true},
	}

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, entry := range entries {
		if err := tw.WriteHeader(&tar.Header{
			Name:     entry.name,
			Mode:     entry.mode,
			Size:     1,
			Typeflag: tar.TypeReg,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte("x")); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}

	dest := t.TempDir()
	if err := extractTarGz(bytes.NewReader(buf.Bytes()), dest); err != nil {
		t.Fatalf("extract: %v", err)
	}

	for _, entry := range entries {
		t.Run(entry.name, func(t *testing.T) {
			info, err := os.Stat(filepath.Join(dest, filepath.FromSlash(entry.name)))
			if err != nil {
				t.Fatal(err)
			}
			// The umask can only clear bits, so test the property (owner may
			// execute) rather than an exact mode.
			if executable := info.Mode().Perm()&0o100 != 0; executable != entry.exec {
				t.Errorf("mode %v: executable = %v, want %v", info.Mode(), executable, entry.exec)
			}
			if info.Mode()&(os.ModeSetuid|os.ModeSetgid) != 0 {
				t.Errorf("mode %v carries a setuid/setgid bit from the archive", info.Mode())
			}
		})
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

func TestFetch_RefusesCleartextRemoteSource(t *testing.T) {
	// A cleartext http pack source on a non-loopback host is refused before any
	// request is made — a MITM mustn't get the chance to serve poisoned bytes.
	_, _, err := Fetch(context.Background(), "http://example.com/packs/redis/pack.tar.gz", nil)
	if err == nil {
		t.Fatal("expected Fetch to refuse a cleartext remote pack source")
	}
	if !strings.Contains(err.Error(), "cleartext") {
		t.Fatalf("expected a cleartext-scheme error, got: %v", err)
	}
}

func TestSecureFetchClientRefusesHTTPSDowngrade(t *testing.T) {
	client := secureFetchClient(&http.Client{})
	httpsRequest, _ := http.NewRequest(http.MethodGet, "https://packs.example/pack.tar.gz", nil)
	httpRequest, _ := http.NewRequest(http.MethodGet, "http://localhost/pack.tar.gz", nil)

	if err := client.CheckRedirect(httpRequest, []*http.Request{httpsRequest}); err == nil {
		t.Fatal("HTTPS to HTTP redirect was accepted")
	}

	loopbackRequest, _ := http.NewRequest(http.MethodGet, "http://localhost/start", nil)
	if err := client.CheckRedirect(httpRequest, []*http.Request{loopbackRequest}); err != nil {
		t.Fatalf("loopback HTTP redirect error = %v", err)
	}
}
