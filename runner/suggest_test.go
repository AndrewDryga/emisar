package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeCatalogFile drops a suggest.json with the given pack entries under a
// temp dir and returns its path. The shape mirrors the registry's
// /packs/suggest.json (catalogPack), so `pack suggest --catalog <file>` parses
// it offline through the exact decoder the registry path uses.
func writeCatalogFile(t *testing.T, packs string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "suggest.json")
	if err := os.WriteFile(p, []byte(`{"packs":[`+packs+`]}`), 0o644); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	return p
}

// runSuggest drives `pack suggest --catalog <file>` with --packs-dir pointed at
// packsDir (which determines which packs are excluded as already-installed),
// capturing stdout.
func runSuggest(t *testing.T, catalog, packsDir string, extraArgs ...string) (error, string) {
	t.Helper()
	withFlags(t)
	flagPacksDir = []string{packsDir}
	withJSONOut(t, false)

	cmd := packSuggestCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs(append([]string{"--catalog", catalog}, extraArgs...))
	var err error
	out := captureStdout(t, func() { err = cmd.Execute() })
	return err, out
}

// Offline against a --catalog file, the read-only baseline (linux-core,
// debugging) is always recommended on a matching-OS host, with no detect signal
// needed (suggest.go baselineSuggestions). The catalog's service pack is given
// an implausible port and process so it cannot fire on the test host, isolating
// the assertion to the deterministic baseline.
func TestPackSuggest_BaselineRecommended(t *testing.T) {
	// Baseline packs carry no detect signal (host-scan adds nothing for them);
	// the "ghost" service pack lists a port/process that won't be present.
	catalog := writeCatalogFile(t, `
		{"id":"linux-core","name":"Linux core","os":[],"detect":{}},
		{"id":"debugging","name":"Debugging","os":[],"detect":{}},
		{"id":"ghost","name":"Ghost","os":[],"detect":{"ports":[59999],"processes":["definitely-not-running-xyzzy"]}}
	`)
	err, out := runSuggest(t, catalog, t.TempDir()) // empty packs dir → no exclusions
	if err != nil {
		t.Fatalf("suggest: %v", err)
	}
	for _, want := range []string{"linux-core", "debugging"} {
		if !strings.Contains(out, want) {
			t.Errorf("baseline pack %q should be recommended; output:\n%s", want, out)
		}
	}
	if strings.Contains(out, "ghost") {
		t.Errorf("a pack with no firing signal must not be suggested; output:\n%s", out)
	}
	// The install line is part of the human guide.
	if !strings.Contains(out, "emisar pack install linux-core") {
		t.Errorf("suggest should print an install line per pack; output:\n%s", out)
	}
}

// `--names-only` prints just the ids, one per line, for scripting
// (suggest.go:82-85) — no headers, no evidence, no install lines.
func TestPackSuggest_NamesOnly(t *testing.T) {
	catalog := writeCatalogFile(t, `
		{"id":"linux-core","name":"Linux core","os":[],"detect":{}},
		{"id":"debugging","name":"Debugging","os":[],"detect":{}}
	`)
	err, out := runSuggest(t, catalog, t.TempDir(), "--names-only")
	if err != nil {
		t.Fatalf("suggest --names-only: %v", err)
	}
	lines := strings.Fields(strings.TrimSpace(out))
	for _, l := range lines {
		if strings.ContainsAny(l, " \t") {
			t.Fatalf("--names-only line %q should be a bare id", l)
		}
	}
	if !strings.Contains(out, "linux-core") || strings.Contains(out, "Install:") {
		t.Errorf("--names-only should print bare ids and no guide; output:\n%s", out)
	}
}

// With nothing to suggest, `--json` emits {"suggestions": []} — a non-nil empty
// slice, not null (suggest.go combineSuggestions seeds out := []Suggestion{}).
// A null here would break a consumer doing `.suggestions | length`. Everything
// in the catalog is excluded by pointing --packs-dir at a dir that already
// "contains" those packs.
func TestPackSuggest_JSONEmitsEmptyArrayNotNull(t *testing.T) {
	catalog := writeCatalogFile(t, `
		{"id":"linux-core","name":"Linux core","os":[],"detect":{}},
		{"id":"debugging","name":"Debugging","os":[],"detect":{}}
	`)
	// Mark both packs already-installed so they're excluded → empty suggestions.
	installed := t.TempDir()
	for _, id := range []string{"linux-core", "debugging"} {
		if err := os.Mkdir(filepath.Join(installed, id), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	withFlags(t)
	flagPacksDir = []string{installed}
	withJSONOut(t, true)

	cmd := packSuggestCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--catalog", catalog})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("suggest --json: %v", runErr)
	}

	var doc struct {
		Suggestions []map[string]any `json:"suggestions"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("suggest --json must emit valid JSON, got %q: %v", out, err)
	}
	if doc.Suggestions == nil {
		t.Fatalf("suggestions must be [] not null; raw output: %s", out)
	}
	if len(doc.Suggestions) != 0 {
		t.Fatalf("all packs were installed, so suggestions should be empty: %v", doc.Suggestions)
	}
	if !strings.Contains(out, "[]") {
		t.Errorf("the empty slice should serialize as []; output: %s", out)
	}
}

// `pack suggest --catalog <dir>` derives detection metadata from a local pack
// directory (catalogFromPackDir) instead of fetching the registry — fully
// offline. A baseline pack (linux-core) present in the dir is recommended on a
// matching-OS host with no network access. We point --catalog at a real pack
// dir built through the production loader, and use an empty --packs-dir so it
// isn't excluded as already-installed.
func TestPackSuggest_OfflineCatalogDir(t *testing.T) {
	catalogDir := t.TempDir()
	// A baseline pack id (no detect signal needed — baselineSuggestions adds it)
	// built through the same loader the runner uses, with an empty OS list so it
	// matches any host.
	writePack(t, catalogDir, "linux-core")

	err, out := runSuggest(t, catalogDir, t.TempDir()) // catalog = a DIR, empty installed
	if err != nil {
		t.Fatalf("suggest --catalog <dir>: %v", err)
	}
	if !strings.Contains(out, "linux-core") {
		t.Fatalf("offline dir catalog should recommend the baseline pack:\n%s", out)
	}
	if !strings.Contains(out, "emisar pack install linux-core") {
		t.Fatalf("offline dir catalog should print the install line:\n%s", out)
	}
}

// Already-installed packs are excluded from the suggestions: a baseline pack
// present in the catalog but also already installed (in the --packs-dir) is
// de-duped out, so a re-run doesn't recommend reinstalling it
// (combineSuggestions drops anything in `installed`).
func TestPackSuggest_AlreadyInstalledExcluded(t *testing.T) {
	catalog := writeCatalogFile(t, `
		{"id":"linux-core","name":"Linux core","os":[],"detect":{}},
		{"id":"debugging","name":"Debugging","os":[],"detect":{}}
	`)
	// Mark linux-core already installed; debugging is not.
	installed := t.TempDir()
	if err := os.Mkdir(filepath.Join(installed, "linux-core"), 0o755); err != nil {
		t.Fatal(err)
	}

	err, out := runSuggest(t, catalog, installed)
	if err != nil {
		t.Fatalf("suggest: %v", err)
	}
	// linux-core is installed → excluded; debugging is still recommended.
	if strings.Contains(out, "linux-core") {
		t.Fatalf("an already-installed pack must be excluded from suggestions:\n%s", out)
	}
	if !strings.Contains(out, "debugging") {
		t.Fatalf("a not-installed baseline pack should still be recommended:\n%s", out)
	}
}

// When the host is already covered (everything excluded), the human output is
// the "already cover this host" message plus a catalog link (suggest.go
// writeSuggestions) — not a blank screen.
func TestPackSuggest_NothingToSuggestMessage(t *testing.T) {
	catalog := writeCatalogFile(t, `{"id":"linux-core","name":"Linux core","os":[],"detect":{}}`)
	installed := t.TempDir()
	if err := os.Mkdir(filepath.Join(installed, "linux-core"), 0o755); err != nil {
		t.Fatal(err)
	}
	err, out := runSuggest(t, catalog, installed)
	if err != nil {
		t.Fatalf("suggest: %v", err)
	}
	if !strings.Contains(out, "already cover this host") {
		t.Errorf("a fully-covered host should get the nothing-to-suggest message; output:\n%s", out)
	}
	if !strings.Contains(out, "/packs") {
		t.Errorf("the nothing-to-suggest message should link the catalog; output:\n%s", out)
	}
}

// With no --catalog and an unreachable/erroring registry, suggest surfaces a
// hard error rather than silently recommending nothing (suggest.go fetchCatalog
// → loadCatalog). The fake registry 500s /packs/suggest.json.
func TestPackSuggest_RegistryFetchFailureErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	withFlags(t)
	flagPacksDir = []string{t.TempDir()}

	cmd := packSuggestCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--registry", srv.URL}) // no --catalog → registry fetch

	var err error
	captureStdout(t, func() { err = cmd.Execute() })
	if err == nil {
		t.Fatal("an erroring registry fetch must surface as an error")
	}
	if !strings.Contains(err.Error(), "suggest.json") {
		t.Fatalf("error %q should name the catalog fetch", err)
	}
}

// `pack suggest` takes no positional args (cobra.NoArgs) — an extra arg is a
// usage error, not silently ignored.
func TestPackSuggest_NoArgs(t *testing.T) {
	cmd := packSuggestCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"extra"})
	if err := cmd.Execute(); err == nil {
		t.Fatal("pack suggest must reject positional args")
	}
}
