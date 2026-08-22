package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/hostscan"
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
// capturing stdout. It returns the printed output and the command error.
func runSuggest(t *testing.T, catalog, packsDir string, extraArgs ...string) (string, error) {
	t.Helper()
	withFlags(t)
	flagPacksDir = []string{packsDir}
	withJSONOut(t, false)

	cmd := packSuggestCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs(append([]string{"--catalog", catalog}, extraArgs...))
	var err error
	out := captureStdout(t, func() { err = cmd.Execute() })
	return out, err
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
	out, err := runSuggest(t, catalog, t.TempDir()) // empty packs dir → no exclusions
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

// The reload guidance matches what installing actually does: `pack install`
// SIGHUPs a live daemon itself and prints the manual fallback only when that
// attempt fails. Suggest must not prescribe an unconditional extra step.
func TestWriteSuggestions_ReloadGuidance(t *testing.T) {
	suggestions := []hostscan.Suggestion{{ID: "linux-core", Name: "Linux core", Evidence: []string{"baseline"}}}

	var buf strings.Builder
	writeSuggestions(&buf, suggestions, nil)
	out := buf.String()
	for _, want := range []string{"reloads a running runner automatically", "if it cannot", "prints the manual reload step"} {
		if !strings.Contains(out, want) {
			t.Errorf("guidance should contain %q; output:\n%s", want, out)
		}
	}
	if strings.Contains(out, "Then reload") || strings.Contains(out, "systemctl reload emisar") {
		t.Errorf("suggest must not prescribe an unconditional manual reload; output:\n%s", out)
	}
}

// `--names-only` prints just the ids, one per line, for scripting
// (suggest.go:82-85) — no headers, no evidence, no install lines.
func TestPackSuggest_NamesOnly(t *testing.T) {
	catalog := writeCatalogFile(t, `
		{"id":"linux-core","name":"Linux core","os":[],"detect":{}},
		{"id":"debugging","name":"Debugging","os":[],"detect":{}}
	`)
	out, err := runSuggest(t, catalog, t.TempDir(), "--names-only")
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

	out, err := runSuggest(t, catalogDir, t.TempDir()) // catalog = a DIR, empty installed
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

// A local pack directory follows the same contract as the published suggest
// index: execution prerequisites are not service-discovery evidence. This is
// the offline path used by bundled installs, so it must not revive the
// dependency fallback removed from the catalog builder.
func TestCatalogFromPackDir_DoesNotPromoteRequirements(t *testing.T) {
	catalogDir := t.TempDir()
	writePack(t, catalogDir, "helper-only")
	manifest := `schema_version: 1
id: helper-only
name: Helper only
version: 0.0.1
description: d
requires:
  binaries: [git, timeout, base64, helper-tool]
actions:
  - actions/ping.yaml
`
	if err := os.WriteFile(filepath.Join(catalogDir, "helper-only", "pack.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatalf("write pack.yaml: %v", err)
	}

	catalog, err := catalogFromPackDir(catalogDir)
	if err != nil {
		t.Fatalf("catalogFromPackDir: %v", err)
	}
	if len(catalog) != 1 {
		t.Fatalf("catalog length = %d, want 1", len(catalog))
	}
	if got := catalog[0].Binaries; len(got) != 0 {
		t.Fatalf("detection binaries = %v, want []", got)
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

	out, err := runSuggest(t, catalog, installed)
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
	out, err := runSuggest(t, catalog, installed)
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

// serveCatalog publishes a fixture index at /v1/catalog.json on a loopback
// server and returns its URL. Loopback HTTP is what `pack suggest` accepts
// without an insecure opt-in, so the fetch path under test is the real one.
func serveCatalog(t *testing.T, body string) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/catalog.json" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv.URL + "/v1/catalog.json"
}

const fixtureHash = "sha256:1111111111111111111111111111111111111111111111111111111111111111"

// catalogFixture is a two-pack catalog.json: a baseline pack every host
// matches, and a baseline pack no host we build for matches. Both carry the
// immutable tarball URL and content hash a published catalog.json carries.
func catalogFixture() string {
	return `{"packs":[
		{"id":"linux-core","name":"Linux core","version":"0.1.0",
		 "requires":{"os":[]},"detect":{},
		 "tarball_url":"https://packs.acme.internal/v1/packs/linux-core/0.1.0/abc/pack.tar.gz",
		 "content_hash":"` + fixtureHash + `"},
		{"id":"debugging","name":"Debugging","version":"0.1.0",
		 "requires":{"os":["plan9"]},"detect":{},
		 "tarball_url":"https://packs.acme.internal/v1/packs/debugging/0.1.0/def/pack.tar.gz",
		 "content_hash":"` + fixtureHash + `"}
	]}`
}

// `--catalog <url>` fetches the index instead of requiring a hand-downloaded
// copy, and a catalog.json source prints the immutable tarball URL pinned to
// its published hash. A bare `pack install <id>` line would resolve against the
// PUBLIC registry — a 404 for a private-only pack, or someone else's bytes for
// a shared id — so the name form must not appear for a pack the catalog placed.
func TestPackSuggest_CatalogURLPrintsPinnedInstallLines(t *testing.T) {
	out, err := runSuggest(t, serveCatalog(t, catalogFixture()), t.TempDir())
	if err != nil {
		t.Fatalf("suggest --catalog <url>: %v", err)
	}
	want := "emisar pack install https://packs.acme.internal/v1/packs/linux-core/0.1.0/abc/pack.tar.gz --hash " + fixtureHash
	if !strings.Contains(out, want) {
		t.Errorf("want pinned install line %q; output:\n%s", want, out)
	}
	if strings.Contains(out, "emisar pack install linux-core") {
		t.Errorf("a pack the catalog gave a tarball for must not print the name form; output:\n%s", out)
	}
}

// catalog.json keeps the OS allowlist under `requires`, where suggest.json
// keeps it at the top level. Reading only the top level would leave every entry
// with an empty allowlist, and an empty allowlist matches ANY host — so a linux
// pack would be recommended on macOS. The fixture's second baseline pack allows
// only plan9, a host this suite never runs on, so it may never be suggested.
func TestPackSuggest_CatalogURLHonorsRequiresOS(t *testing.T) {
	out, err := runSuggest(t, serveCatalog(t, catalogFixture()), t.TempDir())
	if err != nil {
		t.Fatalf("suggest --catalog <url>: %v", err)
	}
	if !strings.Contains(out, "linux-core") {
		t.Errorf("a baseline pack matching this host's OS should be recommended; output:\n%s", out)
	}
	if strings.Contains(out, "debugging") {
		t.Errorf("requires.os must exclude a pack this host does not match; output:\n%s", out)
	}
}

// --json carries the same install source the human guide prints, so a script
// installs the bytes the operator would have.
func TestPackSuggest_CatalogURLJSONCarriesInstallSource(t *testing.T) {
	withFlags(t)
	flagPacksDir = []string{t.TempDir()}
	withJSONOut(t, true)

	cmd := packSuggestCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--catalog", serveCatalog(t, catalogFixture())})

	var err error
	out := captureStdout(t, func() { err = cmd.Execute() })
	if err != nil {
		t.Fatalf("suggest --json --catalog <url>: %v", err)
	}
	var doc struct {
		Suggestions []struct {
			ID          string `json:"id"`
			TarballURL  string `json:"tarball_url"`
			ContentHash string `json:"content_hash"`
		} `json:"suggestions"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("invalid JSON %q: %v", out, err)
	}
	if len(doc.Suggestions) != 1 || doc.Suggestions[0].ID != "linux-core" {
		t.Fatalf("want the single OS-matching baseline pack, got %+v", doc.Suggestions)
	}
	if doc.Suggestions[0].TarballURL == "" || doc.Suggestions[0].ContentHash != fixtureHash {
		t.Fatalf("suggestion should carry its pinned install source: %+v", doc.Suggestions[0])
	}
}

// The printed install line is a command an operator pastes as root, so a
// catalog-supplied tarball URL faces the same transport gate as the fetch that
// returned it: a cleartext URL to a non-loopback host fails the whole run
// rather than being printed. A tampered catalog cannot forge a plaintext
// download the operator then runs.
func TestDecodeCatalog_RejectsCleartextTarballURL(t *testing.T) {
	_, err := decodeCatalog(strings.NewReader(`{"packs":[
		{"id":"linux-core","name":"Linux core","requires":{"os":[]},"detect":{},
		 "tarball_url":"http://packs.acme.internal/v1/packs/linux-core/0.1.0/abc/pack.tar.gz",
		 "content_hash":"` + fixtureHash + `"}]}`))
	if err == nil {
		t.Fatal("a cleartext tarball URL must fail the catalog")
	}
	if !strings.Contains(err.Error(), "linux-core") || !strings.Contains(err.Error(), "tarball_url") {
		t.Fatalf("error %q should name the pack and the field", err)
	}
}

// An unpinned install line is worse than no install line: the operator would
// fetch whatever that URL serves today. A tarball URL without a hash fails.
func TestDecodeCatalog_RejectsTarballWithoutHash(t *testing.T) {
	_, err := decodeCatalog(strings.NewReader(`{"packs":[
		{"id":"linux-core","name":"Linux core","requires":{"os":[]},"detect":{},
		 "tarball_url":"https://packs.acme.internal/v1/packs/linux-core/0.1.0/abc/pack.tar.gz"}]}`))
	if err == nil {
		t.Fatal("a tarball URL with no content hash must fail the catalog")
	}
	if !strings.Contains(err.Error(), "content_hash") {
		t.Fatalf("error %q should name the missing field", err)
	}
}

// A suggest.json source carries no tarball, so its packs keep the name-based
// install line that resolves against the public registry facade.
func TestPackSuggest_SuggestIndexKeepsNameInstallLine(t *testing.T) {
	catalog := writeCatalogFile(t, `{"id":"linux-core","name":"Linux core","os":[],"detect":{}}`)
	out, err := runSuggest(t, catalog, t.TempDir())
	if err != nil {
		t.Fatalf("suggest: %v", err)
	}
	if !strings.Contains(out, "emisar pack install linux-core") {
		t.Errorf("a lean index should still print the name form; output:\n%s", out)
	}
	if strings.Contains(out, "--hash") {
		t.Errorf("nothing to pin from a lean index; output:\n%s", out)
	}
}
