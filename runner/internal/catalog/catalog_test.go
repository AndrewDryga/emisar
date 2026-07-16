package catalog

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// --- fixtures ---------------------------------------------------------

func packYAML(id, version string, extra string) string {
	return "schema_version: 1\nid: " + id + "\nname: " + strings.ToUpper(id) +
		"\nversion: " + version + "\ndescription: the  " + id + "   pack\n" + extra +
		"actions:\n  - actions/a.yaml\n"
}

func execAction(id string) string {
	return `schema_version: 1
id: ` + id + `.read
title: Read thing
kind: exec
risk: low
description: reads
side_effects: [none]
args:
  - name: path
    type: path
    required: true
execution:
  command:
    binary: cat
    argv: ["{{ args.path }}"]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`
}

// writePack writes one pack's files under root/<id>/.
func writePack(t *testing.T, root, id string, files map[string]string) {
	t.Helper()
	for rel, body := range files {
		full := filepath.Join(root, id, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func loadReg(t *testing.T, root string) *packs.Registry {
	t.Helper()
	reg, err := packs.LoadAll([]string{root}, packs.LoadOptions{})
	if err != nil {
		t.Fatalf("LoadAll: %v", err)
	}
	return reg
}

// threePackRoot writes: alpha (generic-only requires → stripped detect),
// beta (explicit detect wins), remote (no detect signal → suggest omits it).
func threePackRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	writePack(t, root, "alpha", map[string]string{
		"pack.yaml":      packYAML("alpha", "1.0.0", "requires:\n  os: [linux]\n  binaries: [curl, alpha-tool]\n"),
		"actions/a.yaml": execAction("alpha"),
	})
	writePack(t, root, "beta", map[string]string{
		"pack.yaml": packYAML("beta", "2.1.0",
			"requires:\n  binaries: [curl]\ndetect:\n  binaries: [beta-bin]\n  processes: [betad]\n  ports: [1234]\n"),
		"actions/a.yaml": execAction("beta"),
	})
	writePack(t, root, "remote", map[string]string{
		"pack.yaml":      packYAML("remote", "0.1.0", "requires:\n  binaries: [curl]\n"),
		"actions/a.yaml": execAction("remote"),
	})
	return root
}

const testBaseURL = "https://cdn.example/registry"

// --- tests ------------------------------------------------------------

func TestBuild(t *testing.T) {
	reg := loadReg(t, threePackRoot(t))
	cat, err := Build(reg, BuildOptions{BaseURL: testBaseURL + "/"})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	if cat.SchemaVersion != SchemaVersion {
		t.Errorf("schema_version = %d, want %d", cat.SchemaVersion, SchemaVersion)
	}
	if len(cat.Packs) != 3 {
		t.Fatalf("got %d packs, want 3", len(cat.Packs))
	}
	// Sorted by id.
	if cat.Packs[0].ID != "alpha" || cat.Packs[1].ID != "beta" || cat.Packs[2].ID != "remote" {
		t.Fatalf("packs not sorted by id: %v", []string{cat.Packs[0].ID, cat.Packs[1].ID, cat.Packs[2].ID})
	}

	alpha := cat.Packs[0]
	wantHash, _ := reg.PackHash("alpha")
	if alpha.ContentHash != wantHash {
		t.Errorf("content_hash = %s, want %s (must match loader)", alpha.ContentHash, wantHash)
	}
	if alpha.Vendor != "emisar" {
		t.Errorf("vendor = %q, want default emisar", alpha.Vendor)
	}
	if alpha.Homepage != DefaultRepoURL {
		t.Errorf("homepage = %q, want default repo", alpha.Homepage)
	}
	if alpha.SourceURL != DefaultRepoURL+"/tree/main/packs/alpha" {
		t.Errorf("source_url = %q", alpha.SourceURL)
	}
	if alpha.Description != "the alpha pack" {
		t.Errorf("description = %q, want whitespace-collapsed", alpha.Description)
	}
	// BaseURL trailing slash trimmed; tarball path content-addressed.
	wantTarball := testBaseURL + "/v1/packs/alpha/1.0.0/" + strings.TrimPrefix(wantHash, "sha256:") + "/pack.tar.gz"
	if alpha.TarballURL != wantTarball {
		t.Errorf("tarball_url = %q, want %q", alpha.TarballURL, wantTarball)
	}
	// Generic helper stripped, real tool kept.
	if got := alpha.Detect.Binaries; len(got) != 1 || got[0] != "alpha-tool" {
		t.Errorf("alpha detect.binaries = %v, want [alpha-tool] (curl stripped)", got)
	}
	if len(alpha.Actions) != 1 || alpha.Actions[0].Command == nil || alpha.Actions[0].Command.Binary != "cat" {
		t.Errorf("alpha action command not carried: %+v", alpha.Actions)
	}

	// Explicit detect wins over requires-derived binaries.
	beta := cat.Packs[1]
	if got := beta.Detect.Binaries; len(got) != 1 || got[0] != "beta-bin" {
		t.Errorf("beta detect.binaries = %v, want [beta-bin]", got)
	}
	if len(beta.Detect.Ports) != 1 || beta.Detect.Ports[0] != 1234 {
		t.Errorf("beta detect.ports = %v, want [1234]", beta.Detect.Ports)
	}
}

func TestBuild_MissingBaseURL(t *testing.T) {
	reg := loadReg(t, threePackRoot(t))
	if _, err := Build(reg, BuildOptions{}); err == nil {
		t.Fatal("expected error when BaseURL is empty")
	}
}

func TestCatalogActionCarriesCompleteReviewedContract(t *testing.T) {
	minDuration := actionspec.Duration(5 * time.Second)
	action, err := catalogAction(&actionspec.Action{
		ID:          "test.inspect",
		Title:       "Inspect  state",
		Kind:        actionspec.KindExec,
		Risk:        actionspec.RiskLow,
		Description: "Reports current state.",
		SideEffects: []string{"none"},
		SearchTerms: []string{"inspect state"},
		Args: []actionspec.Arg{{
			Name:        "window",
			Type:        actionspec.ArgDuration,
			Required:    true,
			Description: "Observation  window",
			Validation:  &actionspec.Validation{MinDuration: &minDuration},
		}},
		Examples: []actionspec.Example{{
			Title: "Short window",
			Args:  map[string]any{"window": "30s"},
		}},
	})
	if err != nil {
		t.Fatalf("catalogAction: %v", err)
	}

	if action.Title != "Inspect state" || action.Summary != "Reports current state." {
		t.Errorf("normalized title/derived summary = %q / %q", action.Title, action.Summary)
	}
	if len(action.SideEffects) != 0 {
		t.Errorf("side_effects = %v, want semantic empty list", action.SideEffects)
	}
	if len(action.Args) != 1 || action.Args[0].Description != "Observation window" {
		t.Fatalf("args not carried completely: %+v", action.Args)
	}
	if got := action.Args[0].Validation.MinDuration; got == nil || *got != "5s" {
		t.Errorf("min_duration = %v, want 5s", got)
	}
	if !reflect.DeepEqual(action.Examples, []Example{{
		Title: "Short window",
		Args:  map[string]any{"window": "30s"},
	}}) {
		t.Errorf("examples = %#v", action.Examples)
	}
}

func TestCatalogActionRequiresBoundedSummaryAndDescriptor(t *testing.T) {
	base := &actionspec.Action{
		ID:          "test.inspect",
		Title:       "Inspect",
		Kind:        actionspec.KindExec,
		Risk:        actionspec.RiskLow,
		Description: strings.Repeat("a", 513) + ". Later sentence.",
		SideEffects: []string{"none"},
	}
	if _, err := catalogAction(base); err == nil || !strings.Contains(err.Error(), "explicit summary") {
		t.Fatalf("expected explicit-summary error, got %v", err)
	}

	base.Summary = "Inspect state"
	base.Examples = []actionspec.Example{{
		Title: "Oversized",
		Args:  map[string]any{"payload": strings.Repeat("x", MaxActionBytes)},
	}}
	if _, err := catalogAction(base); err == nil || !strings.Contains(err.Error(), "descriptor") {
		t.Fatalf("expected descriptor-size error, got %v", err)
	}
}

func TestSuggest_OmitsDetectlessPacks(t *testing.T) {
	reg := loadReg(t, threePackRoot(t))
	cat, err := Build(reg, BuildOptions{BaseURL: testBaseURL})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, p := range cat.Suggest().Packs {
		got[p.ID] = true
	}
	if !got["alpha"] || !got["beta"] {
		t.Errorf("suggest should include alpha and beta, got %v", got)
	}
	if got["remote"] {
		t.Error("suggest must omit remote (no detect signal)")
	}
}

func TestBuild_DriftCheck(t *testing.T) {
	root := threePackRoot(t)
	base, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL})
	if err != nil {
		t.Fatal(err)
	}

	t.Run("same bytes same version passes", func(t *testing.T) {
		if _, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: base}); err != nil {
			t.Errorf("republish of identical packs should pass: %v", err)
		}
	})

	t.Run("changed bytes same version fails", func(t *testing.T) {
		// Mutate alpha's action WITHOUT bumping the version → new hash, same id+version.
		writePack(t, root, "alpha", map[string]string{
			"actions/a.yaml": strings.Replace(execAction("alpha"), "reads", "reads more", 1),
		})
		_, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: base})
		if err == nil {
			t.Fatal("expected drift error for changed bytes at same version")
		}
		if !strings.Contains(err.Error(), "alpha") || !strings.Contains(err.Error(), "bump the version") {
			t.Errorf("drift error should name the pack and advise a version bump: %v", err)
		}
	})

	t.Run("changed bytes with version bump passes", func(t *testing.T) {
		writePack(t, root, "alpha", map[string]string{
			"pack.yaml":      packYAML("alpha", "1.0.1", "requires:\n  os: [linux]\n  binaries: [curl, alpha-tool]\n"),
			"actions/a.yaml": strings.Replace(execAction("alpha"), "reads", "reads more", 1),
		})
		if _, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: base}); err != nil {
			t.Errorf("changed bytes at a new version should pass: %v", err)
		}
	})
}

// --- version window (S1) ---------------------------------------------

// writeSolo writes a single "solo" pack at the given version under root.
func writeSolo(t *testing.T, root, version string) {
	t.Helper()
	writePack(t, root, "solo", map[string]string{
		"pack.yaml":      packYAML("solo", version, "requires:\n  binaries: [solo-bin]\n"),
		"actions/a.yaml": execAction("solo"),
	})
}

// writeSoloRetiring writes the solo pack at version, declaring a retired_below
// floor in its manifest.
func writeSoloRetiring(t *testing.T, root, version, retiredBelow string) {
	t.Helper()
	writePack(t, root, "solo", map[string]string{
		"pack.yaml":      packYAML("solo", version, "retired_below: "+retiredBelow+"\nrequires:\n  binaries: [solo-bin]\n"),
		"actions/a.yaml": execAction("solo"),
	})
}

func soloPack(t *testing.T, cat *Catalog) Pack {
	t.Helper()
	for _, p := range cat.Packs {
		if p.ID == "solo" {
			return p
		}
	}
	t.Fatalf("no solo pack in catalog")
	return Pack{}
}

func historyVersions(p Pack) []string {
	vs := make([]string, len(p.PreviousVersions))
	for i, pv := range p.PreviousVersions {
		vs[i] = pv.Version
	}
	return vs
}

func TestBuild_CarryForwardWindow(t *testing.T) {
	root := t.TempDir()
	var prev *Catalog
	byVersion := map[string]Pack{}
	// Publish 1.0.0 → 1.0.4 in sequence, each carrying the last from --previous.
	for _, v := range []string{"1.0.0", "1.0.1", "1.0.2", "1.0.3", "1.0.4"} {
		writeSolo(t, root, v)
		cat, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: prev})
		if err != nil {
			t.Fatalf("build %s: %v", v, err)
		}
		p := soloPack(t, cat)
		byVersion[v] = p
		// Current version never appears in its own history; no dup versions.
		seen := map[string]bool{}
		for _, hv := range historyVersions(p) {
			if hv == v {
				t.Errorf("%s: history contains the current version", v)
			}
			if seen[hv] {
				t.Errorf("%s: history has %s twice", v, hv)
			}
			seen[hv] = true
		}
		prev = cat
	}

	wantHistory := map[string][]string{
		"1.0.0": {},
		"1.0.1": {"1.0.0"},
		"1.0.2": {"1.0.1", "1.0.0"},
		"1.0.3": {"1.0.2", "1.0.1", "1.0.0"},
		"1.0.4": {"1.0.3", "1.0.2", "1.0.1"}, // K-cap = 3 drops 1.0.0
	}
	for v, want := range wantHistory {
		got := historyVersions(byVersion[v])
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("history(%s) = %v, want %v", v, got, want)
		}
	}

	// A carried entry reproduces the prior build's current version/hash/tarball.
	head := byVersion["1.0.4"].PreviousVersions[0]
	prior := byVersion["1.0.3"]
	if head.Version != prior.Version || head.ContentHash != prior.ContentHash || head.TarballURL != prior.TarballURL {
		t.Errorf("carried head = %+v, want current of prior build (%s / %s / %s)",
			head, prior.Version, prior.ContentHash, prior.TarballURL)
	}
	if !reflect.DeepEqual(head.Actions, prior.Actions) {
		t.Errorf("carried head lost its trusted action snapshot")
	}
}

func TestBuild_CarryForwardRehomesTarballURLs(t *testing.T) {
	root := t.TempDir()

	// Two publishes on the original base fill the history with old-base URLs.
	writeSolo(t, root, "1.0.0")
	first, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL})
	if err != nil {
		t.Fatalf("build 1.0.0: %v", err)
	}
	writeSolo(t, root, "1.0.1")
	second, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: first})
	if err != nil {
		t.Fatalf("build 1.0.1: %v", err)
	}

	// The next build moves the serving base: every carried entry must re-home
	// onto it (same content-addressed path, new host) — a verbatim copy would
	// mix hosts and trip the portal's tarball-base pin.
	newBase := "https://registry.example"
	writeSolo(t, root, "1.0.2")
	moved, err := Build(loadReg(t, root), BuildOptions{BaseURL: newBase, Previous: second})
	if err != nil {
		t.Fatalf("build 1.0.2 on new base: %v", err)
	}
	p := soloPack(t, moved)
	if got := historyVersions(p); strings.Join(got, ",") != "1.0.1,1.0.0" {
		t.Fatalf("history = %v, want [1.0.1 1.0.0]", got)
	}
	for _, pv := range p.PreviousVersions {
		want := newBase + "/" + TarballObject("solo", pv.Version, pv.ContentHash)
		if pv.TarballURL != want {
			t.Errorf("carried %s tarball_url = %q, want %q", pv.Version, pv.TarballURL, want)
		}
	}

	// Version + hash survive the re-home untouched.
	if p.PreviousVersions[0].ContentHash != soloPack(t, second).ContentHash {
		t.Errorf("re-home changed the carried head's content hash")
	}
}

func TestBuild_RetiredBelowFromPackSetsWatermarkAndPrunes(t *testing.T) {
	root := t.TempDir()
	var prev *Catalog
	for _, v := range []string{"1.0.0", "1.0.1", "1.0.2"} {
		writeSolo(t, root, v)
		cat, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: prev})
		if err != nil {
			t.Fatalf("build %s: %v", v, err)
		}
		prev = cat
	}
	// Critical fix at 1.0.3 that retires everything older: the manifest declares
	// retired_below 1.0.3, so the catalog's floor becomes 1.0.3 and history below
	// it is pruned.
	writeSoloRetiring(t, root, "1.0.3", "1.0.3")
	retired, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: prev})
	if err != nil {
		t.Fatalf("retire build: %v", err)
	}
	rp := soloPack(t, retired)
	if rp.RetiredBelow != "1.0.3" {
		t.Errorf("retired_below = %q, want 1.0.3", rp.RetiredBelow)
	}
	if len(rp.PreviousVersions) != 0 {
		t.Errorf("retiring below the current version prunes all history, got %v", historyVersions(rp))
	}

	// The floor sticks and versions at/above it accumulate normally: the manifest
	// keeps declaring 1.0.3, and 1.0.4 carries 1.0.3 as its history head without
	// resurrecting the pruned 1.0.0/1.0.1/1.0.2.
	writeSoloRetiring(t, root, "1.0.4", "1.0.3")
	next, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: retired})
	if err != nil {
		t.Fatalf("post-retire build: %v", err)
	}
	np := soloPack(t, next)
	if np.RetiredBelow != "1.0.3" {
		t.Errorf("post-retire retired_below = %q, want 1.0.3", np.RetiredBelow)
	}
	if got := historyVersions(np); strings.Join(got, ",") != "1.0.3" {
		t.Errorf("post-retire history = %v, want [1.0.3] (below-floor pruned)", got)
	}
}

func TestBuild_RetiredBelowGuards(t *testing.T) {
	dummyHash := "sha256:" + strings.Repeat("a", 64)

	t.Run("floor may not regress", func(t *testing.T) {
		root := t.TempDir()
		writeSoloRetiring(t, root, "9.9.9", "1.5.0")
		prev := &Catalog{SchemaVersion: SchemaVersion, Packs: []Pack{
			{ID: "solo", Version: "9.9.8", ContentHash: dummyHash, RetiredBelow: "2.0.0"},
		}}
		// Declaring 1.5.0 would lower the published floor from 2.0.0 → 1.5.0.
		_, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: prev})
		if err == nil || !strings.Contains(err.Error(), "regress") {
			t.Fatalf("expected floor regression error, got %v", err)
		}
	})

	t.Run("floor may not be dropped", func(t *testing.T) {
		root := t.TempDir()
		writeSolo(t, root, "9.9.9") // no retired_below
		prev := &Catalog{SchemaVersion: SchemaVersion, Packs: []Pack{
			{ID: "solo", Version: "9.9.8", ContentHash: dummyHash, RetiredBelow: "2.0.0"},
		}}
		_, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: prev})
		if err == nil || !strings.Contains(err.Error(), "may not be dropped") {
			t.Fatalf("expected floor-dropped error, got %v", err)
		}
	})

	t.Run("current may not be below the floor", func(t *testing.T) {
		root := t.TempDir()
		writeSoloRetiring(t, root, "1.5.0", "2.0.0")
		_, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL})
		if err == nil || !strings.Contains(err.Error(), "below retired_below") {
			t.Fatalf("expected current-below-floor error, got %v", err)
		}
	})
}

func TestBuild_UnparseableVersionFailsBuild(t *testing.T) {
	root := t.TempDir()
	writeSolo(t, root, "1.2.x")
	_, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL})
	if err == nil || !strings.Contains(err.Error(), "1.2.x") {
		t.Fatalf("expected unparseable-version build error, got %v", err)
	}
}

func TestBuild_DriftAcrossHistory(t *testing.T) {
	root := t.TempDir()
	writeSolo(t, root, "1.0.0") // real pack → real hash H0 at version 1.0.0
	wrongHash := "sha256:" + strings.Repeat("b", 64)
	// Previously-published catalog claims 1.0.0 shipped different bytes (in its
	// history). Republishing 1.0.0 with today's real bytes is drift.
	prev := &Catalog{SchemaVersion: SchemaVersion, Packs: []Pack{
		{ID: "solo", Version: "2.0.0", ContentHash: "sha256:" + strings.Repeat("c", 64),
			PreviousVersions: []PreviousVersion{{Version: "1.0.0", ContentHash: wrongHash, TarballURL: "https://x/old"}}},
	}}
	_, err := Build(loadReg(t, root), BuildOptions{BaseURL: testBaseURL, Previous: prev})
	if err == nil || !strings.Contains(err.Error(), "1.0.0") || !strings.Contains(err.Error(), "bump the version") {
		t.Fatalf("expected drift error against a historical version, got %v", err)
	}
}

func TestCompareVersion(t *testing.T) {
	cases := []struct {
		a, b    string
		want    int
		wantErr bool
	}{
		{"1.0.0", "1.0.1", -1, false},
		{"1.0.1", "1.0.0", 1, false},
		{"1.2.3", "1.2.3", 0, false},
		{"1.2", "1.2.0", 0, false},    // shorter padded with zeros
		{"2.0", "1.9.9", 1, false},    // major dominates
		{"1.10.0", "1.9.0", 1, false}, // numeric, not lexical
		{"1.0.x", "1.0.0", 0, true},
		{"1.0.0", "", 0, true},
	}
	for _, tc := range cases {
		got, err := compareVersion(tc.a, tc.b)
		if tc.wantErr {
			if err == nil {
				t.Errorf("compareVersion(%q,%q): want error", tc.a, tc.b)
			}
			continue
		}
		if err != nil {
			t.Errorf("compareVersion(%q,%q): unexpected error %v", tc.a, tc.b, err)
			continue
		}
		if got != tc.want {
			t.Errorf("compareVersion(%q,%q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}
