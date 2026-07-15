package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/packs"
)

// writeValidPack drops a minimal, loadable pack into a fresh dir under tmp
// and returns its root. The pack is the smallest shape LoadOne accepts, so
// PackHash returns a real content hash the install/uninstall guards key off.
func writeValidPack(t *testing.T, tmp, id string) string {
	t.Helper()
	root := filepath.Join(tmp, id)
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, "actions"), 0o755))
	must(os.WriteFile(filepath.Join(root, "pack.yaml"), []byte(`schema_version: 1
id: `+id+`
name: t
version: 0.0.1
description: t
actions:
  - actions/a.yaml
`), 0o644))
	must(os.WriteFile(filepath.Join(root, "actions", "a.yaml"), []byte(`schema_version: 1
id: `+id+`.a
title: t
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: echo
    argv: ["hi"]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`), 0o644))
	return root
}

// packHashOnDisk loads a pack from src and returns its content hash, the same
// value `pack install --hash` compares against.
func packHashOnDisk(t *testing.T, src, id string) string {
	t.Helper()
	reg, err := packs.LoadOne(src, packs.LoadOptions{})
	if err != nil {
		t.Fatalf("LoadOne(%s): %v", src, err)
	}
	h, ok := reg.PackHash(id)
	if !ok {
		t.Fatalf("no hash for pack %q", id)
	}
	return h
}

// safePackName is the guard that keeps `pack uninstall` from turning a
// hostile id into a RemoveAll outside the packs dir, so its edge cases
// are worth pinning.
func TestSafePackName(t *testing.T) {
	ok := []string{"redis", "linux-core", "aws-ec2", "pack.with.dots", "a"}
	for _, n := range ok {
		if !safePackName(n) {
			t.Errorf("safePackName(%q) = false, want true", n)
		}
	}

	bad := []string{
		"",            // empty
		".",           // current dir
		"..",          // parent
		"../etc",      // traversal
		"../../etc",   // deeper traversal
		"a/b",         // separator
		"/etc/passwd", // absolute
		"foo/",        // trailing sep
		"./foo",       // dot-prefixed (not Clean'd form)
	}
	for _, n := range bad {
		if safePackName(n) {
			t.Errorf("safePackName(%q) = true, want false", n)
		}
	}
}

// copyTree must produce a world-readable pack tree even from a restrictive
// source: a fetched pack lands in a 0700 os.MkdirTemp dir, and preserving that
// would leave a `sudo pack install/update` pack unreadable to the non-root
// runner service user (the "only 2 of N packs loaded" bug).
func TestCopyTree_NormalizesModesForServiceUser(t *testing.T) {
	src := t.TempDir()
	if err := os.Chmod(src, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "pack.yaml"), []byte("id: x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(src, "actions"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "actions", "a.yaml"), []byte("id: x.a\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	dst := filepath.Join(t.TempDir(), "pack")
	if err := copyTree(src, dst); err != nil {
		t.Fatalf("copyTree: %v", err)
	}

	for _, dir := range []string{dst, filepath.Join(dst, "actions")} {
		fi, err := os.Stat(dir)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != 0o755 {
			t.Errorf("dir %s mode = %o, want 0755", dir, fi.Mode().Perm())
		}
	}
	for _, f := range []string{filepath.Join(dst, "pack.yaml"), filepath.Join(dst, "actions", "a.yaml")} {
		fi, err := os.Stat(f)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != 0o644 {
			t.Errorf("file %s mode = %o, want 0644", f, fi.Mode().Perm())
		}
	}
}

// `pack install --hash`: a matching hash installs, a mismatch aborts with
// nothing copied. The --hash flag pins the install to the exact bytes the
// portal advertised (pack.go:223-229): the pack is loaded and content-hashed,
// and if --hash is given the install must abort unless it matches — so a
// tampered or wrong copy is rejected before any file lands in the packs dir.
// Driven through the real `pack install` command with a local source and an
// explicit --dest, so the production gate runs verbatim (no config/network).
func TestPackInstall_HashGate(t *testing.T) {
	src := writeValidPack(t, t.TempDir(), "redis")
	good := packHashOnDisk(t, src, "redis")

	t.Run("matching hash installs", func(t *testing.T) {
		dest := t.TempDir()
		cmd := packInstallCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{src, "--hash", good, "--dest", dest})
		if err := cmd.Execute(); err != nil {
			t.Fatalf("install with matching hash should succeed: %v", err)
		}
		// The pack landed under <dest>/<id> with its files.
		if _, err := os.Stat(filepath.Join(dest, "redis", "pack.yaml")); err != nil {
			t.Fatalf("matching-hash install should have copied the pack: %v", err)
		}
	})

	t.Run("mismatched hash aborts, nothing copied", func(t *testing.T) {
		dest := t.TempDir()
		cmd := packInstallCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{src, "--hash", "sha256:0000000000000000000000000000000000000000000000000000000000000000", "--dest", dest})
		err := cmd.Execute()
		if err == nil {
			t.Fatal("install with a mismatched hash must abort")
		}
		if !strings.Contains(err.Error(), "refusing to install") {
			t.Fatalf("error %q should explain the install was refused on hash mismatch", err)
		}
		// The crucial security property: the abort happens BEFORE any copy, so
		// the target must not exist.
		if _, statErr := os.Stat(filepath.Join(dest, "redis")); statErr == nil {
			t.Fatal("a mismatched-hash install must copy nothing — the target dir exists")
		}
	})
}

// `pack uninstall` refuses a directory that has no pack.yaml ("not a pack"),
// so a misconfigured packs dir can't make it RemoveAll an unrelated tree
// (pack.go:362-367). The id passes the safe-segment guard and the target
// exists and is a directory, but without a pack.yaml the command bails out
// and leaves the directory and its contents untouched.
func TestPackUninstall_RefusesNonPackDir(t *testing.T) {
	dest := t.TempDir()

	// A directory that is NOT a pack: it has the right name but no pack.yaml,
	// and holds an unrelated file we must not lose.
	notAPack := filepath.Join(dest, "redis")
	if err := os.MkdirAll(notAPack, 0o755); err != nil {
		t.Fatal(err)
	}
	bystander := filepath.Join(notAPack, "important.txt")
	if err := os.WriteFile(bystander, []byte("do not delete"), 0o644); err != nil {
		t.Fatal(err)
	}

	cmd := packUninstallCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"redis", "--dest", dest})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("uninstall must refuse a directory with no pack.yaml")
	}
	if !strings.Contains(err.Error(), "not a pack") {
		t.Fatalf("error %q should explain the dir isn't a pack", err)
	}
	// The directory and its bystander file must survive — no RemoveAll ran.
	if _, statErr := os.Stat(bystander); statErr != nil {
		t.Fatalf("uninstall refused but deleted the unrelated dir anyway: %v", statErr)
	}
}

// `pack install ./local-dir`: a local path is used as-is (no fetch),
// validated, and copied to <dest>/<id> (pack.go:280-311 resolvePackSource →
// LoadOne → copyTree). The whole install gate runs without a registry or
// network. Output is captured because install prints the info summary to the
// real os.Stdout.
func TestPackInstall_FromLocalPath(t *testing.T) {
	src := writeValidPack(t, t.TempDir(), "redis")
	dest := t.TempDir()

	cmd := packInstallCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{src, "--dest", dest})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("install from local path: %v", runErr)
	}
	if _, err := os.Stat(filepath.Join(dest, "redis", "pack.yaml")); err != nil {
		t.Fatalf("install should have copied the pack to <dest>/<id>: %v", err)
	}
	if !strings.Contains(out, "installed redis") {
		t.Errorf("install should report the installed pack; output:\n%s", out)
	}
	// The reload reminder is the operator's next step.
	if !strings.Contains(out, "reload emisar") {
		t.Errorf("install should remind the operator to reload; output:\n%s", out)
	}
}

// (tarball variant) /
//
// `pack install <url>` over a loopback registry: the runner does NOT install a
// local tarball *path* (LoadOne requires a directory), so the realistic
// tarball path is a fetch — packs.Fetch downloads + extracts the .tar.gz, then
// LoadOne/copyTree run. A loopback http:// URL passes the cleartext gate
// , so an httptest server stands in for the registry with no
// production change.
func TestPackInstall_FromTarballURL(t *testing.T) {
	src := writeValidPack(t, t.TempDir(), "redis")
	tarball := tarDir(t, src)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/packs/redis/pack.tar.gz" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(tarball)
	}))
	defer srv.Close()

	dest := t.TempDir()
	cmd := packInstallCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{srv.URL + "/packs/redis/pack.tar.gz", "--dest", dest})
	if out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("install from tarball URL: %v", err)
		}
	}); !strings.Contains(out, "installed redis") {
		t.Errorf("install should report the installed pack; output:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(dest, "redis", "actions", "a.yaml")); err != nil {
		t.Fatalf("tarball install should have extracted+copied the pack files: %v", err)
	}
}

// Re-installing an already-present pack id is refused unless --force is given;
// with --force the old install is replaced through the rollback-safe staging path.
// This stops a silent overwrite of a trusted pack while still letting an
// operator deliberately replace one.
func TestPackInstall_AlreadyInstalledNeedsForce(t *testing.T) {
	src := writeValidPack(t, t.TempDir(), "redis")
	dest := t.TempDir()

	install := func(extra ...string) error {
		cmd := packInstallCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(append([]string{src, "--dest", dest}, extra...))
		// Swallow the info summary printed to stdout.
		var err error
		captureStdout(t, func() { err = cmd.Execute() })
		return err
	}

	if err := install(); err != nil {
		t.Fatalf("first install: %v", err)
	}
	// Drop a sentinel so we can tell whether --force actually replaced the tree.
	sentinel := filepath.Join(dest, "redis", "SENTINEL")
	if err := os.WriteFile(sentinel, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	err := install()
	if err == nil {
		t.Fatal("re-installing an already-installed pack must error without --force")
	}
	if !strings.Contains(err.Error(), "--force") {
		t.Fatalf("error %q should tell the operator to pass --force", err)
	}
	// Without --force nothing was touched — the sentinel survives.
	if _, statErr := os.Stat(sentinel); statErr != nil {
		t.Fatalf("a refused re-install must not modify the existing pack: %v", statErr)
	}

	if err := install("--force"); err != nil {
		t.Fatalf("install --force must overwrite: %v", err)
	}
	// --force replaced the old tree, so the sentinel is gone but the real pack
	// files are back.
	if _, statErr := os.Stat(sentinel); !os.IsNotExist(statErr) {
		t.Errorf("--force should replace the old install (sentinel should be gone): %v", statErr)
	}
	if _, err := os.Stat(filepath.Join(dest, "redis", "pack.yaml")); err != nil {
		t.Fatalf("--force should have re-copied the pack: %v", err)
	}
}

func TestReplacePackTree_RestoresPreviousTreeOnActivationFailure(t *testing.T) {
	src := writeValidPack(t, t.TempDir(), "redis")
	parent := t.TempDir()
	target := filepath.Join(parent, "redis")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(target, "OLD")
	if err := os.WriteFile(sentinel, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}

	renames := 0
	err := replacePackTreeWithRename(src, target, true, func(oldPath, newPath string) error {
		renames++
		if renames == 2 {
			return errors.New("injected activation failure")
		}
		return os.Rename(oldPath, newPath)
	})
	if err == nil || !strings.Contains(err.Error(), "activate pack") {
		t.Fatalf("activation error=%v", err)
	}
	if body, err := os.ReadFile(sentinel); err != nil || string(body) != "old" {
		t.Fatalf("previous pack was not restored: body=%q err=%v", body, err)
	}
	if _, err := os.Stat(filepath.Join(parent, ".redis.previous")); !os.IsNotExist(err) {
		t.Fatalf("rollback backup remains after restore: %v", err)
	}
	staging, err := filepath.Glob(filepath.Join(parent, ".redis.stage-*"))
	if err != nil || len(staging) != 0 {
		t.Fatalf("staging remains after rollback: paths=%v err=%v", staging, err)
	}
}

func TestReplacePackTree_RecoversInterruptedBackupBeforeRefusingOverwrite(t *testing.T) {
	src := writeValidPack(t, t.TempDir(), "redis")
	parent := t.TempDir()
	target := filepath.Join(parent, "redis")
	backup := filepath.Join(parent, ".redis.previous")
	if err := os.MkdirAll(backup, 0o755); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(backup, "OLD")
	if err := os.WriteFile(sentinel, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}

	err := replacePackTree(src, target, false)
	if err == nil || !strings.Contains(err.Error(), "--force") {
		t.Fatalf("recovered install error=%v, want existing-pack refusal", err)
	}
	if body, err := os.ReadFile(filepath.Join(target, "OLD")); err != nil || string(body) != "old" {
		t.Fatalf("interrupted backup was not restored: body=%q err=%v", body, err)
	}
	if _, err := os.Stat(backup); !os.IsNotExist(err) {
		t.Fatalf("backup path remains after recovery: %v", err)
	}
}

// `pack install` with neither --dest nor a resolvable config errors rather than
// silently choosing a default packs dir (pack.go:235-244) — installing into the
// wrong place silently is worse than asking. The pack still validates (a local
// source), so the failure is specifically about an unresolved destination.
func TestPackInstall_NoDestNoConfigErrors(t *testing.T) {
	withFlags(t) // clears the --config flag + EMISAR_CONFIG
	t.Setenv("HOME", t.TempDir())
	flagConfig = ""

	src := writeValidPack(t, t.TempDir(), "redis")
	cmd := packInstallCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{src}) // no --dest

	var err error
	captureStdout(t, func() { err = cmd.Execute() })
	if err == nil {
		t.Fatal("install with no --dest and no config must error")
	}
	if !strings.Contains(err.Error(), "no --dest") {
		t.Fatalf("error %q should explain there's no --dest and no config", err)
	}
}

// `pack uninstall <id>` RemoveAll's the installed pack dir and prints the
// reload reminder (pack.go:369-374). The pack has a pack.yaml so it clears the
// not-a-pack guard, and the safe-segment guard, so the happy path runs to the
// removal.
func TestPackUninstall_RemovesAndReminds(t *testing.T) {
	dest := t.TempDir()
	src := writeValidPack(t, t.TempDir(), "redis")
	if err := copyTree(src, filepath.Join(dest, "redis")); err != nil {
		t.Fatalf("seed installed pack: %v", err)
	}

	cmd := packUninstallCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"redis", "--dest", dest})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("uninstall: %v", runErr)
	}
	if _, err := os.Stat(filepath.Join(dest, "redis")); !os.IsNotExist(err) {
		t.Fatalf("uninstall should have removed the pack dir: %v", err)
	}
	if !strings.Contains(out, "removed pack redis") || !strings.Contains(out, "reload") {
		t.Errorf("uninstall should report removal + remind to reload; output:\n%s", out)
	}
}

// Uninstalling an id that isn't present reports "is not installed" rather than
// failing opaquely (pack.go:351-356) — the operator learns the pack was already
// gone (or mistyped), not that something broke.
func TestPackUninstall_NotInstalled(t *testing.T) {
	dest := t.TempDir()
	cmd := packUninstallCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"redis", "--dest", dest})

	err := cmd.Execute()
	if err == nil {
		t.Fatal("uninstall of an absent pack must error")
	}
	if !strings.Contains(err.Error(), "not installed") {
		t.Fatalf("error %q should say the pack is not installed", err)
	}
}

// A plain file (not a directory) where the pack dir would be is refused as "not
// a pack directory" (pack.go:358-360) — uninstall only ever RemoveAll's a real
// pack directory, never an arbitrary file at that path.
func TestPackUninstall_FileAtPathRefused(t *testing.T) {
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, "redis"), []byte("not a dir"), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := packUninstallCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"redis", "--dest", dest})

	err := cmd.Execute()
	if err == nil {
		t.Fatal("uninstall must refuse a non-directory at the pack path")
	}
	if !strings.Contains(err.Error(), "not a pack directory") {
		t.Fatalf("error %q should explain it's not a pack directory", err)
	}
	// The file is left in place — nothing was removed.
	if _, statErr := os.Stat(filepath.Join(dest, "redis")); statErr != nil {
		t.Fatalf("a refused uninstall must not delete the file: %v", statErr)
	}
}

// `pack uninstall` with neither --dest nor a resolvable config errors — the
// destination is resolved exactly like install, with no silent default
// (pack.go:339-348). The safe-name guard passes first, so the failure is
// specifically the unresolved dest.
func TestPackUninstall_NoDestNoConfigErrors(t *testing.T) {
	withFlags(t)
	t.Setenv("HOME", t.TempDir())
	flagConfig = ""

	cmd := packUninstallCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"redis"}) // no --dest

	err := cmd.Execute()
	if err == nil {
		t.Fatal("uninstall with no --dest and no config must error")
	}
	if !strings.Contains(err.Error(), "no --dest") {
		t.Fatalf("error %q should explain there's no --dest and no config", err)
	}
}

// `pack remove`/`rm`/`delete` are aliases for uninstall (pack.go Aliases) — an
// operator's muscle memory ("remove") routes to the same RunE. Verified by
// resolving each alias off the parent `pack` command and confirming it lands on
// the uninstall subcommand.
func TestPackUninstall_Aliases(t *testing.T) {
	for _, alias := range []string{"remove", "rm", "delete"} {
		c, _, err := packCmd().Find([]string{alias})
		if err != nil {
			t.Fatalf("alias %q did not resolve: %v", alias, err)
		}
		if c.Name() != "uninstall" {
			t.Errorf("alias %q routed to %q, want uninstall", alias, c.Name())
		}
	}
}

// `pack install <name>=<version>` fetches a specific published version from
// <registry>/packs/<name>/versions/<version>/pack.tar.gz (S2). The httptest
// server serves ONLY the versioned path, so the install only succeeds if the
// versioned URL was built exactly right.
func TestPackInstall_VersionedName(t *testing.T) {
	src := writeValidPack(t, t.TempDir(), "redis")
	tarball := tarDir(t, src)

	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		if r.URL.Path != "/packs/redis/versions/0.2.3/pack.tar.gz" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(tarball)
	}))
	defer srv.Close()

	dest := t.TempDir()
	cmd := packInstallCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"redis=0.2.3", "--registry", srv.URL, "--dest", dest})
	if out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("versioned install: %v (server saw %q)", err, gotPath)
		}
	}); !strings.Contains(out, "installed redis") {
		t.Errorf("versioned install should report the installed pack; output:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(dest, "redis", "pack.yaml")); err != nil {
		t.Fatalf("versioned install should have copied the pack: %v", err)
	}
}

// A bare name still resolves to the current-version registry path, unchanged
// by the name=version support.
func TestPackInstall_BareNameCurrentVersion(t *testing.T) {
	src := writeValidPack(t, t.TempDir(), "redis")
	tarball := tarDir(t, src)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/packs/redis/pack.tar.gz" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(tarball)
	}))
	defer srv.Close()

	dest := t.TempDir()
	cmd := packInstallCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"redis", "--registry", srv.URL, "--dest", dest})
	if out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("bare-name install: %v", err)
		}
	}); !strings.Contains(out, "installed redis") {
		t.Errorf("bare-name install should report the installed pack; output:\n%s", out)
	}
}

// resolvePackSource rejects malformed name=version specs BEFORE any fetch, and
// never misreads a local path that happens to contain '=' as a versioned name.
func TestResolvePackSource_VersionedParsing(t *testing.T) {
	const reg = "https://reg.example"

	t.Run("malformed specs rejected", func(t *testing.T) {
		// Note: an arg containing '/' (e.g. "redis=../x") is caught by the
		// local-path branch first, so path escapes never reach version parsing.
		for _, arg := range []string{"redis=", "=0.1.0", "a=b=c", "redis=0.2 3", "redis=v1;rm"} {
			if _, _, err := resolvePackSource(context.Background(), arg, reg); err == nil {
				t.Errorf("resolvePackSource(%q) should reject the spec", arg)
			}
		}
	})

	t.Run("local path with '=' stays a path", func(t *testing.T) {
		dir := filepath.Join(t.TempDir(), "my=pack")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		got, cleanup, err := resolvePackSource(context.Background(), dir, reg)
		if err != nil {
			t.Fatalf("absolute path with '=' should resolve as a path, not a version spec: %v", err)
		}
		if cleanup != nil {
			cleanup()
		}
		if got != dir {
			t.Errorf("resolvePackSource returned %q, want the path %q verbatim", got, dir)
		}
	})
}
