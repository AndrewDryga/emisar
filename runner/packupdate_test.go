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
	srcDir := writeSourcePack(t, id)

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

// fakeRegistry stands up an httptest server that serves /packs.json built from
// the given entries plus, for each id, a tarball of the source pack at
// /packs/<id>/pack.tar.gz. It returns the server URL. The registry URL is the
// only injection point `pack update` needs (--registry), so this exercises the
// real fetch path with no production change.
func fakeRegistry(t *testing.T, index []registryPack, tarballs map[string][]byte) string {
	t.Helper()
	var buf bytes.Buffer
	buf.WriteString(`{"packs":[`)
	for i, rp := range index {
		if i > 0 {
			buf.WriteByte(',')
		}
		buf.WriteString(`{"id":"` + rp.ID + `","version":"` + rp.Version + `","hash":"` + rp.Hash + `"}`)
	}
	buf.WriteString(`]}`)
	indexJSON := buf.Bytes()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/packs.json" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(indexJSON)
			return
		}
		for id, tb := range tarballs {
			if r.URL.Path == "/packs/"+id+"/pack.tar.gz" {
				_, _ = w.Write(tb)
				return
			}
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// installPackInto copies the source pack named id into dest/<id> (the shape an
// installed pack has on disk) and returns its content hash.
func installPackInto(t *testing.T, dest, id string) string {
	t.Helper()
	src := writeSourcePack(t, id)
	if err := copyTree(src, filepath.Join(dest, id)); err != nil {
		t.Fatalf("seed installed pack %q: %v", id, err)
	}
	return packHashOnDisk(t, src, id)
}

// runUpdate drives `pack update` against registry with --packs-dir pointed at
// dest, capturing stdout. It returns the command error and the printed output.
func runUpdate(t *testing.T, dest, registry string, extraArgs ...string) (error, string) {
	t.Helper()
	withFlags(t)
	flagPacksDir = []string{dest}

	cmd := packUpdateCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs(append([]string{"--registry", registry}, extraArgs...))
	var err error
	out := captureStdout(t, func() { err = cmd.Execute() })
	return err, out
}

// closes RUN-020-T02
//
// A pack whose installed hash equals the registry's is reported "up to date"
// and left untouched (packupdate.go:98-103) — update never rewrites bytes that
// already match, so a reload isn't forced for nothing.
func TestPackUpdate_UpToDateSkipped(t *testing.T) {
	dest := t.TempDir()
	hash := installPackInto(t, dest, "redis")
	mtimeBefore := mtime(t, filepath.Join(dest, "redis", "pack.yaml"))

	registry := fakeRegistry(t, []registryPack{{ID: "redis", Version: "0.0.1", Hash: hash}}, nil)

	err, out := runUpdate(t, dest, registry)
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if !strings.Contains(out, "up to date") {
		t.Errorf("a matching-hash pack should report up to date; output:\n%s", out)
	}
	if mtime(t, filepath.Join(dest, "redis", "pack.yaml")) != mtimeBefore {
		t.Error("an up-to-date pack must not be rewritten")
	}
}

// closes RUN-020-T03
//
// A locally-authored pack absent from the registry index is left as-is, not
// treated as an error (packupdate.go:91-96) — update only manages packs the
// registry knows about, so a private pack survives an update run.
func TestPackUpdate_NotInRegistryLeftAsIs(t *testing.T) {
	dest := t.TempDir()
	installPackInto(t, dest, "homegrown")

	// Registry knows a different pack, so "homegrown" is not in the index.
	registry := fakeRegistry(t, []registryPack{{ID: "redis", Version: "1", Hash: "sha256:" + strings.Repeat("a", 64)}}, nil)

	err, out := runUpdate(t, dest, registry)
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if !strings.Contains(out, "homegrown") || !strings.Contains(out, "not in registry") {
		t.Errorf("an unknown-to-registry pack should be left as-is; output:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(dest, "homegrown", "pack.yaml")); err != nil {
		t.Fatalf("a not-in-registry pack must be untouched: %v", err)
	}
}

// closes RUN-020-T06 / RUN-020-T13
//
// `pack update --dry-run` reports the available move (vX → vY) but touches
// nothing on disk (packupdate.go:105-109), and leaves no staging dir behind.
// The installed hash differs from the index's, so a real run would update — the
// dry run must stop short of any filesystem change.
func TestPackUpdate_DryRunTouchesNothing(t *testing.T) {
	dest := t.TempDir()
	installPackInto(t, dest, "redis")
	pinned := mtime(t, filepath.Join(dest, "redis", "pack.yaml"))

	// Index advertises a different hash → an update is "available".
	registry := fakeRegistry(t, []registryPack{
		{ID: "redis", Version: "9.9.9", Hash: "sha256:" + strings.Repeat("b", 64)},
	}, nil)

	err, out := runUpdate(t, dest, registry, "--dry-run")
	if err != nil {
		t.Fatalf("update --dry-run: %v", err)
	}
	if !strings.Contains(out, "update available") {
		t.Errorf("--dry-run should report the available update; output:\n%s", out)
	}
	if mtime(t, filepath.Join(dest, "redis", "pack.yaml")) != pinned {
		t.Error("--dry-run must not modify the installed pack")
	}
	if _, err := os.Stat(filepath.Join(dest, "redis.tmp-update")); !os.IsNotExist(err) {
		t.Error("--dry-run must not create a staging dir")
	}
}

// closes RUN-020-T07
//
// A requested id that isn't installed anywhere is surfaced as "not installed"
// rather than a silent no-op (packupdate.go:122-127), so an operator's typo is
// visible instead of looking like "nothing to do".
func TestPackUpdate_TypoReportedNotInstalled(t *testing.T) {
	dest := t.TempDir()
	hash := installPackInto(t, dest, "redis")
	registry := fakeRegistry(t, []registryPack{{ID: "redis", Version: "0.0.1", Hash: hash}}, nil)

	// Ask to update an id that isn't installed.
	err, out := runUpdate(t, dest, registry, "notreal")
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if !strings.Contains(out, "notreal") || !strings.Contains(out, "not installed") {
		t.Errorf("a typo'd id should be reported not installed; output:\n%s", out)
	}
}

// closes RUN-020-T09
//
// With an empty packs dir, update prints "No packs installed in <dir>" and
// exits cleanly (packupdate.go:129-132) — there's nothing to do and that's not
// an error.
func TestPackUpdate_NoPacksInstalled(t *testing.T) {
	dest := t.TempDir()
	registry := fakeRegistry(t, nil, nil)

	err, out := runUpdate(t, dest, registry)
	if err != nil {
		t.Fatalf("update with no packs: %v", err)
	}
	if !strings.Contains(out, "No packs installed") {
		t.Errorf("an empty packs dir should report no packs installed; output:\n%s", out)
	}
}

// closes RUN-020-T10
//
// When one pack updates and another fails (the registry serves a tarball whose
// hash doesn't match its index entry), update tallies the result and returns a
// non-zero error so a CI/automation caller sees the partial failure
// (packupdate.go:148-150) — the good pack still swaps in, the bad one is left
// intact.
func TestPackUpdate_PartialFailureNonZeroExit(t *testing.T) {
	dest := t.TempDir()

	// "good": a clean source whose tarball matches its index hash. We install
	// it, then mutate the installed copy so its hash differs from the index —
	// forcing a real fetch+swap that succeeds (the fetched bytes match goodHash).
	goodSrc := writeSourcePack(t, "good")
	goodHash := packHashOnDisk(t, goodSrc, "good")
	if err := copyTree(goodSrc, filepath.Join(dest, "good")); err != nil {
		t.Fatal(err)
	}
	mutateInstalledHash(t, dest, "good")

	// "bad": installed and in the index, but the index advertises a hash the
	// served tarball won't match → updateOnePack rejects it, leaving it intact.
	badSrc := writeSourcePack(t, "bad")
	if err := copyTree(badSrc, filepath.Join(dest, "bad")); err != nil {
		t.Fatal(err)
	}

	registry := fakeRegistry(t,
		[]registryPack{
			{ID: "good", Version: "9.9.9", Hash: goodHash},
			{ID: "bad", Version: "9.9.9", Hash: "sha256:" + strings.Repeat("c", 64)},
		},
		map[string][]byte{
			"good": tarDir(t, goodSrc),
			"bad":  tarDir(t, badSrc),
		},
	)

	err, out := runUpdate(t, dest, registry)
	if err == nil {
		t.Fatal("a partial failure must return a non-zero error")
	}
	if !strings.Contains(out, "FAILED") {
		t.Errorf("the failing pack should be reported as FAILED; output:\n%s", out)
	}
	// The good pack swapped in (its on-disk hash now equals goodHash); the bad
	// pack's tree is still present (left intact on failure).
	if h := packHashOnDisk(t, filepath.Join(dest, "good"), "good"); h != goodHash {
		t.Errorf("the good pack should have updated to the registry version (hash %s, got %s)", goodHash, h)
	}
	if _, err := os.Stat(filepath.Join(dest, "bad", "pack.yaml")); err != nil {
		t.Errorf("the failed pack must be left intact: %v", err)
	}
}

// mtime returns a file's modification time for "was it rewritten?" assertions.
func mtime(t *testing.T, path string) int64 {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat %s: %v", path, err)
	}
	return fi.ModTime().UnixNano()
}

// mutateInstalledHash appends a byte to the installed pack's pack.yaml comment
// so its content hash no longer matches the registry index, forcing a real
// update on the next run. (A trailing comment line keeps the YAML valid.)
func mutateInstalledHash(t *testing.T, dest, id string) {
	t.Helper()
	p := filepath.Join(dest, id, "pack.yaml")
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, append(data, []byte("\n# local edit\n")...), 0o644); err != nil {
		t.Fatal(err)
	}
}

// writeSourcePack builds a minimal, valid pack (pack.yaml + one action) under a
// temp dir and returns its root. Self-contained on purpose: loading a shipped
// pack by path is what red-flagged this test when packs moved to the repo root,
// so the source the update flow exercises lives entirely inside the test.
func writeSourcePack(t *testing.T, id string) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), id)
	files := map[string]string{
		"pack.yaml": `schema_version: 1
id: ` + id + `
name: t
version: 0.0.1
description: t
actions:
  - actions/a.yaml
`,
		"actions/a.yaml": `schema_version: 1
id: ` + id + `.a
title: t
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/echo
    argv: ["hi"]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`,
	}
	for rel, body := range files {
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}
