package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// writePackTree writes an arbitrary set of pack files under a fresh temp dir.
// Tests spell out the YAML they are asserting on rather than mutating a shared
// fixture, so each case reads as the exact contract it pins.
func writePackTree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, body := range files {
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		mode := fs.FileMode(0o644)
		if strings.HasSuffix(rel, ".sh") {
			mode = 0o755
		}
		if err := os.WriteFile(full, []byte(body), mode); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func diffPackYAML(version string, actionPaths ...string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "schema_version: 1\nid: redis\nname: t\nversion: %s\ndescription: t\nactions:\n", version)
	for _, p := range actionPaths {
		fmt.Fprintf(&b, "  - %s\n", p)
	}
	return b.String()
}

// diffActionYAML is a valid exec action with `extra` spliced under execution,
// which is where every callout this command makes actually lives.
func diffActionYAML(id, risk, extra string) string {
	return fmt.Sprintf(`schema_version: 1
id: %s
title: t
kind: exec
risk: %s
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: echo
    argv: ["hi"]
  timeout: 5s
%soutput:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`, id, risk, extra)
}

// diffRegistry serves /packs.json plus tarballs at explicit URL paths, so a
// test can drive both the current-version URL and the --to <version> one.
func diffRegistry(t *testing.T, index []registryPack, tarballs map[string][]byte) string {
	t.Helper()
	var buf bytes.Buffer
	buf.WriteString(`{"packs":[`)
	for i, rp := range index {
		if i > 0 {
			buf.WriteByte(',')
		}
		fmt.Fprintf(&buf, `{"id":%q,"version":%q,"hash":%q}`, rp.ID, rp.Version, rp.Hash)
	}
	buf.WriteString(`]}`)
	indexJSON := buf.Bytes()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/packs.json" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(indexJSON)
			return
		}
		if tb, ok := tarballs[r.URL.Path]; ok {
			_, _ = w.Write(tb)
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// diffSetup installs `installedFiles` as the on-disk pack and publishes
// `candidateFiles` as the registry's current redis, returning the packs dir and
// the registry URL.
func diffSetup(t *testing.T, installedFiles, candidateFiles map[string]string) (dest, registry string) {
	t.Helper()
	dest = t.TempDir()
	installed := writePackTree(t, installedFiles)
	if err := copyTree(installed, filepath.Join(dest, "redis")); err != nil {
		t.Fatalf("seed installed pack: %v", err)
	}

	candidate := writePackTree(t, candidateFiles)
	tarball := tarDir(t, candidate)
	hash := packHashOnDisk(t, candidate, "redis")
	registry = diffRegistry(t,
		[]registryPack{{ID: "redis", Version: "0.4.0", Hash: hash}},
		map[string][]byte{"/packs/redis/pack.tar.gz": tarball})
	return dest, registry
}

func runDiff(t *testing.T, dest, registry string, extraArgs ...string) (string, error) {
	t.Helper()
	withFlags(t)
	flagPacksDir = []string{dest}

	cmd := packDiffCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs(append([]string{"redis", "--registry", registry}, extraArgs...))
	var err error
	out := captureStdout(t, func() { err = cmd.Execute() })
	return out, err
}

// The diff covers exactly the files that form the content hash. A pack's test
// fixtures, its Dockerfile SUT, and its docs are neither loaded by the runner
// nor hashed — and a locally installed pack carries them, because
// `pack install ./dir` copies the whole source tree through copyTree.
func TestPackDiff_ExcludesEverythingOutsideTheContentHash(t *testing.T) {
	installed := map[string]string{
		"pack.yaml":            diffPackYAML("0.3.0", "actions/a.yaml"),
		"actions/a.yaml":       diffActionYAML("redis.a", "low", ""),
		"test/cases.yaml":      "cases: [{name: old}]\n",
		"test/compose.yaml":    "services: {redis: {image: redis:7}}\n",
		"Dockerfile":           "FROM redis:7\n",
		"README.md":            "old readme\n",
		"scripts/unreferenced": "not referenced by any action\n",
	}
	candidate := map[string]string{
		"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
		"actions/a.yaml": diffActionYAML("redis.a", "medium", ""),
	}
	dest, registry := diffSetup(t, installed, candidate)

	out, err := runDiff(t, dest, registry)
	if err != nil {
		t.Fatalf("pack diff: %v\n%s", err, out)
	}
	for _, unwanted := range []string{"test/cases.yaml", "test/compose.yaml", "Dockerfile", "README.md", "unreferenced"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("diff mentions %q, which is outside the content hash:\n%s", unwanted, out)
		}
	}
	if !strings.Contains(out, "actions/a.yaml") {
		t.Errorf("diff is missing the changed action file:\n%s", out)
	}
}

// The loader appends one hash entry per script-kind action, so two actions
// sharing a script yield the same path twice. It must appear once.
func TestPackDiff_SharedScriptAppearsOnce(t *testing.T) {
	scriptAction := func(id, body string) string {
		return fmt.Sprintf(`schema_version: 1
id: %s
title: t
kind: script
risk: low
description: d
side_effects: [none]
args: []
execution:
  script:
    path: scripts/shared.sh
    interpreter: /bin/sh
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`, id) + body
	}
	files := func(version, script string) map[string]string {
		return map[string]string{
			"pack.yaml":         diffPackYAML(version, "actions/a.yaml", "actions/b.yaml"),
			"actions/a.yaml":    scriptAction("redis.a", ""),
			"actions/b.yaml":    scriptAction("redis.b", ""),
			"scripts/shared.sh": script,
		}
	}
	dest, registry := diffSetup(t,
		files("0.3.0", "#!/bin/sh\necho old\n"),
		files("0.4.0", "#!/bin/sh\necho new\n"))

	out, err := runDiff(t, dest, registry)
	if err != nil {
		t.Fatalf("pack diff: %v\n%s", err, out)
	}
	if n := strings.Count(out, "--- a/scripts/shared.sh"); n != 1 {
		t.Fatalf("shared script appears %d times, want 1:\n%s", n, out)
	}
	if !strings.Contains(out, "-echo old") || !strings.Contains(out, "+echo new") {
		t.Fatalf("script diff is missing its changed lines:\n%s", out)
	}
}

func TestPackDiff_RendersChangedLines(t *testing.T) {
	dest, registry := diffSetup(t,
		map[string]string{
			"pack.yaml":      diffPackYAML("0.3.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "low", ""),
		},
		map[string]string{
			"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "high", ""),
		})

	out, err := runDiff(t, dest, registry)
	if err != nil {
		t.Fatalf("pack diff: %v\n%s", err, out)
	}
	for _, want := range []string{"@@ -", "-risk: low", "+risk: high", "-version: 0.3.0", "+version: 0.4.0"} {
		if !strings.Contains(out, want) {
			t.Errorf("diff is missing %q:\n%s", want, out)
		}
	}
}

func TestPackDiff_AddedAndRemovedFiles(t *testing.T) {
	dest, registry := diffSetup(t,
		map[string]string{
			"pack.yaml":         diffPackYAML("0.3.0", "actions/gone.yaml"),
			"actions/gone.yaml": diffActionYAML("redis.gone", "low", ""),
		},
		map[string]string{
			"pack.yaml":          diffPackYAML("0.4.0", "actions/fresh.yaml"),
			"actions/fresh.yaml": diffActionYAML("redis.fresh", "low", ""),
		})

	out, err := runDiff(t, dest, registry, "--stat")
	if err != nil {
		t.Fatalf("pack diff: %v\n%s", err, out)
	}
	if !strings.Contains(out, "added      actions/fresh.yaml") {
		t.Errorf("want actions/fresh.yaml listed as added:\n%s", out)
	}
	if !strings.Contains(out, "removed    actions/gone.yaml") {
		t.Errorf("want actions/gone.yaml listed as removed:\n%s", out)
	}
}

// Each callout is a single line an operator scrolling raw YAML would miss, so
// each gets its own case rather than sharing one fixture.
func TestPackDiff_Callouts(t *testing.T) {
	tests := []struct {
		name         string
		oldAction    string
		newAction    string
		wantContains string
	}{
		{
			name:         "risk escalated",
			oldAction:    diffActionYAML("redis.a", "medium", ""),
			newAction:    diffActionYAML("redis.a", "critical", ""),
			wantContains: "risk escalated",
		},
		{
			name:      "execution user changed",
			oldAction: diffActionYAML("redis.a", "low", "  user: emisar\n"),
			newAction: diffActionYAML("redis.a", "low", "  user: root\n"),

			wantContains: "runs as a different user",
		},
		{
			name: "redaction rule removed",
			oldAction: strings.Replace(diffActionYAML("redis.a", "low", ""),
				"  max_stderr_bytes: 1024\n",
				"  max_stderr_bytes: 1024\n  redact:\n    - name: masks_requirepass\n      type: regex\n      pattern: 'requirepass \\S+'\n", 1),
			newAction:    diffActionYAML("redis.a", "low", ""),
			wantContains: "redaction rule gone",
		},
		{
			name: "sensitive dropped from an arg",
			oldAction: strings.Replace(diffActionYAML("redis.a", "low", ""),
				"args: []\n",
				"args:\n  - name: token\n    type: string\n    required: false\n    sensitive: true\n", 1),
			newAction: strings.Replace(diffActionYAML("redis.a", "low", ""),
				"args: []\n",
				"args:\n  - name: token\n    type: string\n    required: false\n", 1),
			wantContains: "no longer sensitive",
		},
		{
			name: "path allowlist gained an entry",
			oldAction: strings.Replace(diffActionYAML("redis.a", "low", ""),
				"args: []\n",
				"args:\n  - name: conf\n    type: path\n    required: false\n    validation:\n      allowed_paths: [\"/etc/redis/*\"]\n", 1),
			newAction: strings.Replace(diffActionYAML("redis.a", "low", ""),
				"args: []\n",
				"args:\n  - name: conf\n    type: path\n    required: false\n    validation:\n      allowed_paths: [\"/etc/redis/*\", \"/etc/*\"]\n", 1),
			wantContains: "path limits widened",
		},
		{
			name: "path allowlist removed entirely",
			oldAction: strings.Replace(diffActionYAML("redis.a", "low", ""),
				"args: []\n",
				"args:\n  - name: conf\n    type: path\n    required: false\n    validation:\n      allowed_paths: [\"/etc/redis/*\"]\n", 1),
			newAction: strings.Replace(diffActionYAML("redis.a", "low", ""),
				"args: []\n",
				"args:\n  - name: conf\n    type: path\n    required: false\n", 1),
			wantContains: "path limits widened",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dest, registry := diffSetup(t,
				map[string]string{
					"pack.yaml":      diffPackYAML("0.3.0", "actions/a.yaml"),
					"actions/a.yaml": tt.oldAction,
				},
				map[string]string{
					"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
					"actions/a.yaml": tt.newAction,
				})

			out, err := runDiff(t, dest, registry)
			if err != nil {
				t.Fatalf("pack diff: %v\n%s", err, out)
			}
			if !strings.Contains(out, tt.wantContains) {
				t.Fatalf("want callout %q:\n%s", tt.wantContains, out)
			}
		})
	}
}

func TestPackDiff_CalloutsForActionsAddedAndRemoved(t *testing.T) {
	dest, registry := diffSetup(t,
		map[string]string{
			"pack.yaml":      diffPackYAML("0.3.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.gone", "low", ""),
		},
		map[string]string{
			"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.fresh", "low", ""),
		})

	out, err := runDiff(t, dest, registry)
	if err != nil {
		t.Fatalf("pack diff: %v\n%s", err, out)
	}
	if !strings.Contains(out, "actions added") || !strings.Contains(out, "redis.fresh") {
		t.Errorf("want an actions-added callout naming redis.fresh:\n%s", out)
	}
	if !strings.Contains(out, "actions removed") || !strings.Contains(out, "redis.gone") {
		t.Errorf("want an actions-removed callout naming redis.gone:\n%s", out)
	}
}

func TestPackDiff_StatOmitsHunks(t *testing.T) {
	dest, registry := diffSetup(t,
		map[string]string{
			"pack.yaml":      diffPackYAML("0.3.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "low", ""),
		},
		map[string]string{
			"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "high", ""),
		})

	out, err := runDiff(t, dest, registry, "--stat")
	if err != nil {
		t.Fatalf("pack diff: %v\n%s", err, out)
	}
	if strings.Contains(out, "@@ -") {
		t.Errorf("--stat printed hunks:\n%s", out)
	}
	if !strings.Contains(out, "risk escalated") {
		t.Errorf("--stat dropped the callouts:\n%s", out)
	}
	if !strings.Contains(out, "modified   actions/a.yaml") {
		t.Errorf("--stat is missing the file list:\n%s", out)
	}
}

// --to pins a published version, which lives at a different URL and carries no
// index entry to verify against.
func TestPackDiff_ToVersionFetchesTheVersionedURL(t *testing.T) {
	dest := t.TempDir()
	installed := writePackTree(t, map[string]string{
		"pack.yaml":      diffPackYAML("0.3.0", "actions/a.yaml"),
		"actions/a.yaml": diffActionYAML("redis.a", "low", ""),
	})
	if err := copyTree(installed, filepath.Join(dest, "redis")); err != nil {
		t.Fatal(err)
	}
	pinned := writePackTree(t, map[string]string{
		"pack.yaml":      diffPackYAML("0.5.0", "actions/a.yaml"),
		"actions/a.yaml": diffActionYAML("redis.a", "critical", ""),
	})
	registry := diffRegistry(t,
		[]registryPack{{ID: "redis", Version: "0.4.0", Hash: "sha256:unused"}},
		map[string][]byte{"/packs/redis/versions/0.5.0/pack.tar.gz": tarDir(t, pinned)})

	out, err := runDiff(t, dest, registry, "--to", "0.5.0")
	if err != nil {
		t.Fatalf("pack diff --to: %v\n%s", err, out)
	}
	if !strings.Contains(out, "0.3.0 → 0.5.0") {
		t.Errorf("want the pinned version in the header:\n%s", out)
	}
	if !strings.Contains(out, "+risk: critical") {
		t.Errorf("want the pinned version's changed lines:\n%s", out)
	}
}

// Reviewing bytes the registry does not vouch for defeats the reason the
// command exists, so a mismatch is refused rather than diffed with a warning.
func TestPackDiff_RefusesCandidateWhoseHashMissesTheIndex(t *testing.T) {
	dest := t.TempDir()
	installed := writePackTree(t, map[string]string{
		"pack.yaml":      diffPackYAML("0.3.0", "actions/a.yaml"),
		"actions/a.yaml": diffActionYAML("redis.a", "low", ""),
	})
	if err := copyTree(installed, filepath.Join(dest, "redis")); err != nil {
		t.Fatal(err)
	}
	candidate := writePackTree(t, map[string]string{
		"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
		"actions/a.yaml": diffActionYAML("redis.a", "critical", ""),
	})
	registry := diffRegistry(t,
		[]registryPack{{ID: "redis", Version: "0.4.0", Hash: "sha256:" + strings.Repeat("ab", 32)}},
		map[string][]byte{"/packs/redis/pack.tar.gz": tarDir(t, candidate)})

	out, err := runDiff(t, dest, registry)
	if err == nil {
		t.Fatalf("want a hash-mismatch error, got success:\n%s", out)
	}
	if !strings.Contains(err.Error(), "hash mismatch") {
		t.Fatalf("want a hash-mismatch error, got: %v", err)
	}
}

// The command is a report: it must leave the packs dir byte-identical.
func TestPackDiff_TouchesNothing(t *testing.T) {
	dest, registry := diffSetup(t,
		map[string]string{
			"pack.yaml":       diffPackYAML("0.3.0", "actions/a.yaml"),
			"actions/a.yaml":  diffActionYAML("redis.a", "low", ""),
			"test/cases.yaml": "cases: []\n",
		},
		map[string]string{
			"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "high", ""),
		})

	before := treeFingerprint(t, dest)
	if _, err := runDiff(t, dest, registry); err != nil {
		t.Fatalf("pack diff: %v", err)
	}
	if after := treeFingerprint(t, dest); after != before {
		t.Fatalf("pack diff modified the packs dir:\nbefore %s\nafter  %s", before, after)
	}
}

// treeFingerprint hashes every path, mode, and byte under root so any write —
// content, permission, or a new file — changes the result.
func treeFingerprint(t *testing.T, root string) string {
	t.Helper()
	var entries []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if d.IsDir() {
			entries = append(entries, fmt.Sprintf("d %s %o", rel, info.Mode().Perm()))
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		entries = append(entries, fmt.Sprintf("f %s %o %s", rel, info.Mode().Perm(), hex.EncodeToString(sum[:])))
		return nil
	})
	if err != nil {
		t.Fatalf("fingerprint %s: %v", root, err)
	}
	sort.Strings(entries)
	sum := sha256.Sum256([]byte(strings.Join(entries, "\n")))
	return hex.EncodeToString(sum[:])
}

// An unchanged pack must serialize its lists as [], not null — a `jq '.files[]'`
// consumer fails on null, the same trap already fixed in packupdate.go.
func TestPackDiff_JSONEmptyListsAndNoEscapes(t *testing.T) {
	same := map[string]string{
		"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
		"actions/a.yaml": diffActionYAML("redis.a", "low", ""),
	}
	dest, registry := diffSetup(t, same, same)

	withJSONOut(t, true)
	out, err := runDiff(t, dest, registry)
	if err != nil {
		t.Fatalf("pack diff --json: %v\n%s", err, out)
	}
	if strings.Contains(out, "\x1b[") {
		t.Fatalf("--json emitted ANSI escapes:\n%s", out)
	}

	var report packDiffReport
	if err := json.Unmarshal([]byte(out), &report); err != nil {
		t.Fatalf("parse --json: %v\n%s", err, out)
	}
	if report.Files == nil || report.Notes == nil {
		t.Fatalf("want [] for empty files/notes, got null:\n%s", out)
	}
	if len(report.Files) != 0 {
		t.Fatalf("want no changed files for an identical pack, got %d:\n%s", len(report.Files), out)
	}
	if report.PackID != "redis" || report.To.Version != "0.4.0" {
		t.Fatalf("unexpected report identity: %+v", report)
	}
}

func TestPackDiff_JSONCarriesUnifiedText(t *testing.T) {
	dest, registry := diffSetup(t,
		map[string]string{
			"pack.yaml":      diffPackYAML("0.3.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "low", ""),
		},
		map[string]string{
			"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "high", ""),
		})

	withJSONOut(t, true)
	out, err := runDiff(t, dest, registry)
	if err != nil {
		t.Fatalf("pack diff --json: %v\n%s", err, out)
	}
	var report packDiffReport
	if err := json.Unmarshal([]byte(out), &report); err != nil {
		t.Fatalf("parse --json: %v\n%s", err, out)
	}
	var action *packDiffFile
	for i := range report.Files {
		if report.Files[i].Path == "actions/a.yaml" {
			action = &report.Files[i]
		}
	}
	if action == nil {
		t.Fatalf("want actions/a.yaml in the report, got %+v", report.Files)
	}
	if !strings.Contains(action.Unified, "-risk: low") || !strings.Contains(action.Unified, "+risk: high") {
		t.Fatalf("unified text is missing the change:\n%s", action.Unified)
	}
	if report.Insertions == 0 || report.Deletions == 0 {
		t.Fatalf("want non-zero insertion/deletion counts, got %+v", report)
	}
}

// Same version with a different hash means the installed tree was edited or the
// registry republished — `pack update` silently overwrites either way.
func TestPackDiff_SameVersionDifferentHashIsCalledOut(t *testing.T) {
	dest, registry := diffSetup(t,
		map[string]string{
			"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "low", "  cwd: /var/lib/redis\n"),
		},
		map[string]string{
			"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "low", ""),
		})

	out, err := runDiff(t, dest, registry)
	if err != nil {
		t.Fatalf("pack diff: %v\n%s", err, out)
	}
	if !strings.Contains(out, "same version, different hash") {
		t.Fatalf("want the same-version callout:\n%s", out)
	}
}

// A pack too broken to parse is still diffable against the version that would
// repair it — refusing to run would leave the operator with no way to see what
// `pack update` is about to install.
func TestPackDiff_BrokenInstallDiffsAgainstItsRepair(t *testing.T) {
	dest, registry := diffSetup(t,
		map[string]string{
			"pack.yaml":      diffPackYAML("0.3.0", "actions/a.yaml"),
			"actions/a.yaml": "schema_version: 1\nid: redis.a\n",
		},
		map[string]string{
			"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "low", ""),
		})

	out, err := runDiff(t, dest, registry)
	if err != nil {
		t.Fatalf("pack diff on a broken install: %v\n%s", err, out)
	}
	if !strings.Contains(out, "the installed pack does not load") {
		t.Errorf("want the unreadable-install callout:\n%s", out)
	}
	if !strings.Contains(out, "+risk: low") {
		t.Errorf("want the repairing version's lines:\n%s", out)
	}
}

func TestPackDiff_UnknownPacks(t *testing.T) {
	dest, registry := diffSetup(t,
		map[string]string{
			"pack.yaml":      diffPackYAML("0.3.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "low", ""),
		},
		map[string]string{
			"pack.yaml":      diffPackYAML("0.4.0", "actions/a.yaml"),
			"actions/a.yaml": diffActionYAML("redis.a", "low", ""),
		})

	t.Run("not installed", func(t *testing.T) {
		withFlags(t)
		flagPacksDir = []string{dest}
		cmd := packDiffCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"postgres", "--registry", registry})
		err := cmd.Execute()
		if err == nil || !strings.Contains(err.Error(), "not installed") {
			t.Fatalf("want a not-installed error, got: %v", err)
		}
	})

	t.Run("not in registry", func(t *testing.T) {
		empty := diffRegistry(t, nil, nil)
		_, err := runDiff(t, dest, empty)
		if err == nil || !strings.Contains(err.Error(), "not in the registry") {
			t.Fatalf("want a not-in-registry error, got: %v", err)
		}
	})
}
