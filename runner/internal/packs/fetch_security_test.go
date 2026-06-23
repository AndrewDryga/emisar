package packs

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// gzipTar wraps a caller-built tar body in a gzip stream. Used by the cap /
// type tests that need precise control over headers (sizes, counts, names)
// that the name→content helper in fetch_test.go can't express.
func gzipTar(t *testing.T, build func(tw *tar.Writer)) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	build(tw)
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// writeReg writes one regular-file entry of `size` 'a' bytes with an honest
// header Size. (archive/tar's Writer enforces Write length == header Size, so
// a fixture cannot under-declare a body; the streaming LimitReader/n>max guard
// in fetch.go defends a hand-crafted/non-stdlib tar that lies, which this
// stdlib-built fixture can't express — the honest-header check at fetch.go:118
// is the reachable guard here.)
func writeReg(t *testing.T, tw *tar.Writer, name string, size int) {
	t.Helper()
	if err := tw.WriteHeader(&tar.Header{
		Name:     name,
		Mode:     0o644,
		Size:     int64(size),
		Typeflag: tar.TypeReg,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write(bytes.Repeat([]byte{'a'}, size)); err != nil {
		t.Fatal(err)
	}
}

// RSEC-011-T04 — loopback http is allowed for a local dev registry (the
// accepted cleartext exception). httptest serves on 127.0.0.1, so a
// successful Fetch over its plain-http URL proves the loopback carve-out.
func TestFetch_AllowsLoopbackHTTP(t *testing.T) {
	data := makeTarGz(t, map[string]string{"pack.yaml": "id: local\n"})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(data)
	}))
	defer srv.Close()

	// httptest.NewServer (not TLS) yields an http://127.0.0.1:PORT URL.
	if !strings.HasPrefix(srv.URL, "http://") {
		t.Fatalf("expected a cleartext loopback server URL, got %q", srv.URL)
	}
	dir, cleanup, err := Fetch(context.Background(), srv.URL+"/packs/local/pack.tar.gz", srv.Client())
	if err != nil {
		t.Fatalf("loopback http should be permitted: %v", err)
	}
	cleanup()
	_ = dir
}

// RSEC-011-T06 — an absolute / leading-slash entry name is rejected by
// safeJoin before anything is written. The tar writer normalizes some
// absolute names, so assert safeJoin directly for the leading-slash forms
// and via a full extract for a clearly-absolute name.
func TestExtractTarGz_RejectsAbsoluteEntry(t *testing.T) {
	for _, name := range []string{"/etc/passwd", "/abs.yaml"} {
		if _, err := safeJoin(t.TempDir(), name); err == nil {
			t.Errorf("safeJoin(%q) = nil error, want rejection", name)
		}
	}

	// End-to-end through extractTarGz: a leading-slash member must be refused.
	data := gzipTar(t, func(tw *tar.Writer) {
		writeReg(t, tw, "/etc/cron.d/evil", 4)
	})
	if err := extractTarGz(bytes.NewReader(data), t.TempDir()); err == nil {
		t.Error("expected extractTarGz to reject an absolute entry name")
	}
}

// RSEC-011-T07 — an empty entry name is rejected. The tar writer refuses to
// emit an empty Name, so this exercises safeJoin (the function extractTarGz
// calls for every header) directly.
func TestSafeJoin_RejectsEmptyName(t *testing.T) {
	if _, err := safeJoin(t.TempDir(), ""); err == nil {
		t.Fatal("safeJoin(\"\") = nil error, want rejection")
	}
}

// RSEC-011-T09 — a single entry larger than maxSingleBytes (8 MiB) is
// rejected. (Tested via an honest oversized header; the streaming
// LimitReader/n>max guard for a header that lies smaller is unreachable from
// an archive/tar-built fixture — see writeReg.)
func TestExtractTarGz_PerFileSizeCap(t *testing.T) {
	data := gzipTar(t, func(tw *tar.Writer) {
		writeReg(t, tw, "big.bin", maxSingleBytes+1)
	})
	err := extractTarGz(bytes.NewReader(data), t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "too large") {
		t.Fatalf("expected per-file size rejection, got %v", err)
	}
}

// RSEC-011-T16 — an entry exactly at the per-file limit is accepted (only
// strictly-greater is rejected). Boundary partner of T09.
func TestExtractTarGz_PerFileSizeAtLimitAccepted(t *testing.T) {
	dest := t.TempDir()
	data := gzipTar(t, func(tw *tar.Writer) {
		writeReg(t, tw, "exact.bin", maxSingleBytes)
	})
	if err := extractTarGz(bytes.NewReader(data), dest); err != nil {
		t.Fatalf("entry at exactly the per-file limit should be accepted, got %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dest, "exact.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != maxSingleBytes {
		t.Fatalf("wrote %d bytes, want %d", len(got), maxSingleBytes)
	}
}

// RSEC-011-T10 — the running total uncompressed cap (32 MiB) is enforced
// across entries even when each entry is individually under the per-file
// cap. The decompression-bomb guard.
func TestExtractTarGz_TotalSizeCap(t *testing.T) {
	// Each entry is 4 MiB (< 8 MiB per-file cap). 9 of them = 36 MiB > 32 MiB
	// total, so extraction must abort once the running total crosses the cap.
	const each = 4 << 20
	data := gzipTar(t, func(tw *tar.Writer) {
		for i := 0; i < 9; i++ {
			writeReg(t, tw, fmt.Sprintf("chunk%d.bin", i), each)
		}
	})
	err := extractTarGz(bytes.NewReader(data), t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "total size limit") {
		t.Fatalf("expected total-size rejection, got %v", err)
	}
}

// RSEC-011-T11 — the entry-count cap (4000) is enforced. Build an archive of
// many tiny entries; extraction must abort past maxPackFiles.
func TestExtractTarGz_EntryCountCap(t *testing.T) {
	data := gzipTar(t, func(tw *tar.Writer) {
		for i := 0; i <= maxPackFiles; i++ {
			writeReg(t, tw, fmt.Sprintf("f%d.txt", i), 1)
		}
	})
	err := extractTarGz(bytes.NewReader(data), t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "too many entries") {
		t.Fatalf("expected entry-count rejection, got %v", err)
	}
}

// RSEC-011-T13 — a non-200, non-404 status (e.g. 500) surfaces as an error
// distinct from the 404 path.
func TestFetch_Non200IsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	_, _, err := Fetch(context.Background(), srv.URL+"/packs/x/pack.tar.gz", srv.Client())
	if err == nil {
		t.Fatal("expected an error for HTTP 500")
	}
	if !strings.Contains(err.Error(), "500") {
		t.Fatalf("expected the status code in the error, got %v", err)
	}
}

// RSEC-011-T14 — a corrupt gzip body surfaces as a wrapped error and the temp
// dir is removed (no half-extracted tree left behind). The cleanup closure is
// internal, so assert no leak by counting emisar-pack-* temp dirs before/after.
func TestFetch_CorruptGzipErrorsAndCleansTemp(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("this is not gzip"))
	}))
	defer srv.Close()

	before := countPackTemps(t)
	_, _, err := Fetch(context.Background(), srv.URL+"/packs/x/pack.tar.gz", srv.Client())
	if err == nil {
		t.Fatal("expected an extract error for a corrupt gzip body")
	}
	if !strings.Contains(err.Error(), "extract") {
		t.Fatalf("expected a wrapped extract error, got %v", err)
	}
	if after := countPackTemps(t); after > before {
		t.Fatalf("temp dir leaked on extract failure: before=%d after=%d", before, after)
	}
}

// RSEC-011-T15 — a nil HTTP client is accepted and Fetch falls back to its
// 30s-timeout default. Against a loopback server the request still succeeds,
// proving the nil path constructs a working client rather than panicking.
func TestFetch_NilClientUsesDefault(t *testing.T) {
	data := makeTarGz(t, map[string]string{"pack.yaml": "id: dflt\n"})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(data)
	}))
	defer srv.Close()

	dir, cleanup, err := Fetch(context.Background(), srv.URL+"/packs/dflt/pack.tar.gz", nil)
	if err != nil {
		t.Fatalf("nil client should use the default and succeed: %v", err)
	}
	cleanup()
	_ = dir
}

func countPackTemps(t *testing.T) int {
	t.Helper()
	entries, err := os.ReadDir(os.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "emisar-pack-") {
			n++
		}
	}
	return n
}
