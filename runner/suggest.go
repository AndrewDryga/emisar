package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/hostscan"
	"github.com/andrewdryga/emisar/runner/internal/packs"
)

// baselinePackIDs are recommended on every host of a matching OS,
// regardless of which services run — the read-only core every operator
// wants. systemdPackID is added when the host runs systemd.
var baselinePackIDs = []string{"linux-core", "debugging"}

const systemdPackID = "systemd-deep"

// catalogPack mirrors one entry of a published registry index. Both
// published documents share the {"packs": [...]} envelope: the lean
// suggest.json carries id/name/os plus the pack-authored detect signal, and
// the full catalog.json keeps the OS allowlist under requires and adds the
// immutable tarball URL with its content hash — what suggest needs to print
// an install line that resolves against THAT registry.
type catalogPack struct {
	ID          string          `json:"id"`
	Name        string          `json:"name"`
	OS          []string        `json:"os"`
	Requires    catalogRequires `json:"requires"`
	Detect      catalogDetect   `json:"detect"`
	TarballURL  string          `json:"tarball_url"`
	ContentHash string          `json:"content_hash"`
}

type catalogRequires struct {
	OS []string `json:"os"`
}

type catalogDetect struct {
	Binaries  []string `json:"binaries"`
	Processes []string `json:"processes"`
	Ports     []int    `json:"ports"`
}

// packSource is where one pack's bytes come from — the immutable tarball URL
// it was published at and the hash to pin the install to. Only catalog.json
// carries these; a suggest.json index or a local pack directory does not, so
// suggestions from those fall back to a name-based install line.
type packSource struct {
	TarballURL  string
	ContentHash string
}

// catalogSet is a resolved candidate pack set: the detect signals to match
// this host against, plus each pack's install source where the source
// document published one.
type catalogSet struct {
	packs   []hostscan.PackReq
	sources map[string]packSource
}

// maxCatalogBytes bounds a fetched index. A suggest.json is a few KB; a full
// catalog.json carries every action descriptor and already runs to several MB,
// so the cap only has to stop a runaway body, not size today's catalog.
const maxCatalogBytes = 32 << 20

func packSuggestCmd() *cobra.Command {
	var (
		catalogSrc string
		registry   string
		namesOnly  bool
	)
	cmd := &cobra.Command{
		Use:   "suggest",
		Short: "Recommend packs to install based on what's running on this host",
		Long: `Inspect this host and recommend which action packs to install.

For each pack it checks the detection signals that identify a service — a
service-specific binary present (on $PATH, in the standard bin dirs, or
running as a process), or a service process running — and recommends the
pack when one of those fires. So a host running Nomad is pointed at the
nomad pack. A listening port identifies nobody (any process can bind it),
so a pack's declared ports only corroborate a pack already recommended;
a pack declaring ports alone is never auto-suggested. The read-only core
(linux-core, debugging, and systemd-deep on a systemd host) is always
recommended.

The detection metadata comes from the registry's /packs/suggest.json by
default. --catalog reads it from somewhere else: a suggest.json or catalog.json
URL, either document on disk, or a directory of packs (offline, e.g. the bundle
install.sh ships). Point it at your own registry's v1/catalog.json to suggest
from a private tree — that document carries each pack's immutable tarball URL
and hash, so the install lines it prints resolve against YOUR registry instead
of the public one. Only explicit detect metadata is used; runtime requirements are
never treated as evidence. Packs already installed are left out.

  emisar pack suggest                       # from the registry
  emisar pack suggest --names-only          # just ids, one per line (scripts)
  emisar pack suggest --catalog ./packs     # match against a local pack dir
  emisar pack suggest --catalog https://packs.acme.internal/v1/catalog.json`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			// Two output modes, and --names-only silently won. A `| jq` pipeline
			// asking for both got bare ids and exit 0 — the exact failure the
			// --json annotation exists to prevent, one flag away from the
			// commands that refuse the flag outright. Refuse the contradiction
			// instead of picking a winner.
			if namesOnly && flagJSONOut {
				return usageError{errors.New("--names-only and --json are different output modes; choose one")}
			}

			catalog, err := loadCatalog(cmd.Context(), catalogSrc, registry)
			if err != nil {
				return err
			}

			facts := hostscan.Detect(unionBinaries(catalog.packs))
			suggestions := combineSuggestions(catalog.packs, facts, installedPackIDs())

			switch {
			case namesOnly:
				for _, s := range suggestions {
					fmt.Println(s.ID)
				}
			case flagJSONOut:
				return printJSON(map[string]any{"suggestions": withSources(suggestions, catalog.sources)})
			default:
				writeSuggestions(os.Stdout, suggestions, catalog.sources)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&catalogSrc, "catalog", "", "suggest.json/catalog.json URL or file, or a pack directory, to match against (default: registry /packs/suggest.json)")
	cmd.Flags().StringVar(&registry, "registry", "", "pack registry base URL (default $EMISAR_PACKS_REGISTRY or "+defaultRegistry+")")
	cmd.Flags().BoolVar(&namesOnly, "names-only", false, "print only pack ids, one per line")
	return cmd
}

// combineSuggestions merges the always-on baseline with the host-matched
// service packs, drops anything already installed, and de-duplicates —
// baseline first, then service packs in id order.
func combineSuggestions(catalog []hostscan.PackReq, facts hostscan.Facts, installed map[string]bool) []hostscan.Suggestion {
	out := []hostscan.Suggestion{} // non-nil so --json emits [] not null
	seen := map[string]bool{}
	add := func(s hostscan.Suggestion) {
		if seen[s.ID] || installed[s.ID] {
			return
		}
		seen[s.ID] = true
		out = append(out, s)
	}
	for _, s := range baselineSuggestions(catalog) {
		add(s)
	}
	for _, s := range hostscan.Match(catalog, facts) {
		add(s)
	}
	return out
}

// baselineSuggestions returns the core packs that exist in the catalog
// and match this host's OS, plus systemd-deep on a systemd host.
func baselineSuggestions(catalog []hostscan.PackReq) []hostscan.Suggestion {
	byID := make(map[string]hostscan.PackReq, len(catalog))
	for _, p := range catalog {
		byID[p.ID] = p
	}
	mk := func(id, why string) (hostscan.Suggestion, bool) {
		p, ok := byID[id]
		if !ok || !p.MatchesHostOS() {
			return hostscan.Suggestion{}, false
		}
		return hostscan.Suggestion{ID: p.ID, Name: p.Name, Evidence: []string{why}}, true
	}

	var out []hostscan.Suggestion
	for _, id := range baselinePackIDs {
		if s, ok := mk(id, "core baseline"); ok {
			out = append(out, s)
		}
	}
	if hostscan.SystemdPresent() {
		if s, ok := mk(systemdPackID, "systemd host"); ok {
			out = append(out, s)
		}
	}
	return out
}

func unionBinaries(catalog []hostscan.PackReq) []string {
	seen := map[string]bool{}
	var out []string
	for _, p := range catalog {
		for _, b := range p.Binaries {
			lb := strings.ToLower(b)
			if lb != "" && !seen[lb] {
				seen[lb] = true
				out = append(out, b)
			}
		}
	}
	return out
}

// loadCatalog resolves the candidate pack set: whatever --catalog names — a
// URL, a document on disk, or a pack directory — otherwise the registry's
// /packs/suggest.json.
func loadCatalog(ctx context.Context, src, registry string) (catalogSet, error) {
	if src != "" {
		if isHTTPURL(src) {
			return fetchCatalog(ctx, src)
		}
		if fi, err := os.Stat(src); err == nil && fi.IsDir() {
			packs, err := catalogFromPackDir(src)
			if err != nil {
				return catalogSet{}, err
			}
			return catalogSet{packs: packs}, nil
		}
		return catalogFromFile(src)
	}
	if registry == "" {
		registry = os.Getenv("EMISAR_PACKS_REGISTRY")
	}
	if registry == "" {
		registry = defaultRegistry
	}
	return fetchCatalog(ctx, strings.TrimRight(registry, "/")+"/packs/suggest.json")
}

// isHTTPURL reports whether --catalog named an index to fetch rather than a
// path. Anything else falls through to the filesystem, where a typo fails with
// a plain open error naming exactly what the operator typed.
func isHTTPURL(src string) bool {
	lower := strings.ToLower(src)
	return strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://")
}

func catalogFromPackDir(dir string) ([]hostscan.PackReq, error) {
	reg, err := packs.LoadAll([]string{dir}, packs.LoadOptions{})
	if err != nil {
		return nil, fmt.Errorf("load catalog from %s: %w", dir, err)
	}
	var out []hostscan.PackReq
	for _, p := range reg.Packs() {
		// Mirror the published catalog exactly: only pack-authored detect
		// evidence participates in suggestions. Requirements describe what
		// actions need at runtime, not what service exists on this host.
		req := hostscan.PackReq{
			ID:        p.ID,
			Name:      p.Name,
			OS:        p.Requires.OS,
			Binaries:  p.Detect.Binaries,
			Processes: p.Detect.Processes,
			Ports:     p.Detect.Ports,
		}
		out = append(out, req)
	}
	return out, nil
}

func catalogFromFile(path string) (catalogSet, error) {
	f, err := os.Open(path)
	if err != nil {
		return catalogSet{}, fmt.Errorf("open catalog %s: %w", path, err)
	}
	defer f.Close()
	return decodeCatalog(f)
}

// fetchCatalog reads a published index — a lean suggest.json or a full
// catalog.json — over HTTP.
func fetchCatalog(ctx context.Context, url string) (catalogSet, error) {
	// Same transport rule as the two sibling registry fetches: refuse cleartext
	// to a non-loopback host, and refuse a redirect that downgrades off HTTPS.
	// This output is printed as `emisar pack install …` lines an operator
	// pastes, so an on-path answer here is an instruction-forging primitive.
	if err := config.CheckEndpointScheme(url, false); err != nil {
		return catalogSet{}, fmt.Errorf("fetch catalog: %w", err)
	}
	// Generous enough for a multi-MB catalog.json over a slow link; the lean
	// index it replaces arrives in one round trip.
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return catalogSet{}, err
	}
	resp, err := packRegistryHTTPClient().Do(req)
	if err != nil {
		return catalogSet{}, fmt.Errorf("fetch catalog %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return catalogSet{}, fmt.Errorf("fetch catalog %s: HTTP %d", url, resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxCatalogBytes+1))
	if err != nil {
		return catalogSet{}, fmt.Errorf("fetch catalog %s: %w", url, err)
	}
	// Read one byte past the cap so an oversized body fails by name instead of
	// as a truncated-JSON parse error.
	if len(body) > maxCatalogBytes {
		return catalogSet{}, fmt.Errorf("fetch catalog %s: index exceeds %d bytes", url, maxCatalogBytes)
	}
	return decodeCatalog(bytes.NewReader(body))
}

func decodeCatalog(r io.Reader) (catalogSet, error) {
	var doc struct {
		Packs []catalogPack `json:"packs"`
	}
	if err := json.NewDecoder(r).Decode(&doc); err != nil {
		return catalogSet{}, fmt.Errorf("parse catalog: %w", err)
	}
	set := catalogSet{
		packs:   make([]hostscan.PackReq, 0, len(doc.Packs)),
		sources: make(map[string]packSource),
	}
	for _, p := range doc.Packs {
		allowedOS := p.OS
		if len(allowedOS) == 0 {
			allowedOS = p.Requires.OS // catalog.json keeps the allowlist under requires
		}
		set.packs = append(set.packs, hostscan.PackReq{
			ID:        p.ID,
			Name:      p.Name,
			OS:        allowedOS,
			Binaries:  p.Detect.Binaries,
			Processes: p.Detect.Processes,
			Ports:     p.Detect.Ports,
		})
		if p.TarballURL == "" {
			continue
		}
		// A tarball URL becomes an install command the operator runs as root, so
		// hold it to the same transport rule as the fetch, and refuse to print
		// one we cannot pin to a hash. It may legitimately live on a different
		// host than the catalog (a CDN base URL), so same-origin is not required
		// — the hash, not the host, is what fixes the bytes.
		if err := config.CheckEndpointScheme(p.TarballURL, false); err != nil {
			return catalogSet{}, fmt.Errorf("catalog entry %q: tarball_url: %w", p.ID, err)
		}
		if p.ContentHash == "" {
			return catalogSet{}, fmt.Errorf("catalog entry %q: tarball_url with no content_hash", p.ID)
		}
		set.sources[p.ID] = packSource{TarballURL: p.TarballURL, ContentHash: p.ContentHash}
	}
	return set, nil
}

// installedPackIDs lists pack ids already present in the runner's packs
// dir so suggest doesn't recommend reinstalling them. Best-effort: any
// failure to resolve or read the dir just yields no exclusions.
func installedPackIDs() map[string]bool {
	out := map[string]bool{}
	dirs, err := resolvePackDirs()
	if err != nil {
		return out
	}
	for _, d := range dirs {
		entries, err := os.ReadDir(d)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				out[e.Name()] = true
			}
		}
	}
	return out
}

// suggestionOut is one suggestion as --json emits it: the match, plus the
// immutable tarball URL and hash when the catalog published them, so a script
// installs the same bytes the human guide prints.
type suggestionOut struct {
	hostscan.Suggestion
	TarballURL  string `json:"tarball_url,omitempty"`
	ContentHash string `json:"content_hash,omitempty"`
}

func withSources(suggestions []hostscan.Suggestion, sources map[string]packSource) []suggestionOut {
	out := make([]suggestionOut, 0, len(suggestions)) // non-nil so --json emits [] not null
	for _, s := range suggestions {
		src := sources[s.ID]
		out = append(out, suggestionOut{Suggestion: s, TarballURL: src.TarballURL, ContentHash: src.ContentHash})
	}
	return out
}

// writeSuggestions renders the human guide. Each resulting `pack install`
// attempts the reload itself and prints a manual fallback only when needed,
// so suggest describes that conditional behavior without prescribing a
// separate reload step.
func writeSuggestions(w io.Writer, suggestions []hostscan.Suggestion, sources map[string]packSource) {
	if len(suggestions) == 0 {
		fmt.Fprintln(w, "No new packs to suggest — the installed packs already cover this host.")
		fmt.Fprintln(w, "Browse the full catalog: "+defaultRegistry+"/packs")
		return
	}

	fmt.Fprintln(w, "Recommended packs for this host:")
	fmt.Fprintln(w)
	width := 0
	for _, s := range suggestions {
		if len(s.ID) > width {
			width = len(s.ID)
		}
	}
	for _, s := range suggestions {
		fmt.Fprintf(w, "  %-*s  %s\n", width, s.ID, strings.Join(s.Evidence, ", "))
	}
	fmt.Fprintln(w, "\nInstall:")
	for _, s := range suggestions {
		// A pack name resolves against the public registry's name facade, which a
		// private tree does not have — so where the catalog published an exact
		// tarball, install from that, pinned to the hash published with it.
		if src, ok := sources[s.ID]; ok {
			fmt.Fprintf(w, "  emisar pack install %s --hash %s\n", src.TarballURL, src.ContentHash)
			continue
		}
		fmt.Fprintf(w, "  emisar pack install %s\n", s.ID)
	}
	fmt.Fprintln(w, "\nEach install reloads a running runner automatically; if it cannot,")
	fmt.Fprintln(w, "the install command prints the manual reload step.")
	fmt.Fprintln(w, "Browse the full catalog: "+defaultRegistry+"/packs")
}
