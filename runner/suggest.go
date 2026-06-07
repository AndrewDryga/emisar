package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/hostscan"
	"github.com/andrewdryga/emisar/runner/internal/packs"
)

// baselinePackIDs are recommended on every host of a matching OS,
// regardless of which services run — the read-only core every operator
// wants. systemdPackID is added when the host runs systemd.
var baselinePackIDs = []string{"linux-core", "debugging"}

const systemdPackID = "systemd-deep"

// catalogPack mirrors one entry of the registry's /packs/suggest.json
// index: the per-pack detect signal, with ubiquitous helpers already
// stripped server-side, plus id/name/os. No description/hash/tarball —
// suggestion doesn't need them.
type catalogPack struct {
	ID     string        `json:"id"`
	Name   string        `json:"name"`
	OS     []string      `json:"os"`
	Detect catalogDetect `json:"detect"`
}

type catalogDetect struct {
	Binaries  []string `json:"binaries"`
	Processes []string `json:"processes"`
	Ports     []int    `json:"ports"`
}

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

For each pack it checks a detection signal — a service-specific binary
present (on $PATH, in the standard bin dirs, or running as a process), a
service process running, or a service port listening — and recommends the
pack when any of those fire. So a host running Nomad is pointed at the nomad
pack, one with Grafana on :3000 at grafana, and so on. The read-only core
(linux-core, debugging, and systemd-deep on a systemd host) is always
recommended.

The detection metadata comes from the registry's /packs/suggest.json by
default (the curated list of which binaries are too generic to be a signal
lives server-side, so it evolves without a runner upgrade); --catalog points
at a local suggest.json file or a directory of packs instead (offline, e.g.
the bundle install.sh ships). Packs already installed are left out.

  emisar pack suggest                       # from the registry
  emisar pack suggest --names-only          # just ids, one per line (scripts)
  emisar pack suggest --catalog ./packs     # match against a local pack dir`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			catalog, err := loadCatalog(cmd.Context(), catalogSrc, registry)
			if err != nil {
				return err
			}

			facts := hostscan.Detect(unionBinaries(catalog))
			suggestions := combineSuggestions(catalog, facts, installedPackIDs())

			switch {
			case namesOnly:
				for _, s := range suggestions {
					fmt.Println(s.ID)
				}
			case flagJSONOut:
				return printJSON(map[string]any{"suggestions": suggestions})
			default:
				writeSuggestions(os.Stdout, suggestions)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&catalogSrc, "catalog", "", "local suggest.json file or pack directory to match against (default: registry /packs/suggest.json)")
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

// loadCatalog resolves the candidate pack set: a local file/dir when
// --catalog is given, otherwise the registry's /packs/suggest.json.
func loadCatalog(ctx context.Context, src, registry string) ([]hostscan.PackReq, error) {
	if src != "" {
		if fi, err := os.Stat(src); err == nil && fi.IsDir() {
			return catalogFromPackDir(src)
		}
		return catalogFromFile(src)
	}
	if registry == "" {
		registry = os.Getenv("EMISAR_PACKS_REGISTRY")
	}
	if registry == "" {
		registry = defaultRegistry
	}
	return fetchCatalog(ctx, registry)
}

func catalogFromPackDir(dir string) ([]hostscan.PackReq, error) {
	reg, err := packs.LoadAll([]string{dir}, packs.LoadOptions{})
	if err != nil {
		return nil, fmt.Errorf("load catalog from %s: %w", dir, err)
	}
	var out []hostscan.PackReq
	for _, p := range reg.Packs() {
		req := hostscan.PackReq{ID: p.ID, Name: p.Name, OS: p.Requires.OS}
		// A pack that declares a detect block defines its own signal
		// exactly (e.g. processes/ports for a service it only reaches via
		// curl). Otherwise fall back to its required binaries: the offline
		// catalog is the install bundle, which has no generic-helper-only
		// packs, so no server-side stripping is needed here.
		if d := p.Detect; len(d.Binaries) > 0 || len(d.Processes) > 0 || len(d.Ports) > 0 {
			req.Binaries, req.Processes, req.Ports = d.Binaries, d.Processes, d.Ports
		} else {
			req.Binaries = p.Requires.Binaries
		}
		out = append(out, req)
	}
	return out, nil
}

func catalogFromFile(path string) ([]hostscan.PackReq, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open catalog %s: %w", path, err)
	}
	defer f.Close()
	return decodeCatalog(f)
}

func fetchCatalog(ctx context.Context, registry string) ([]hostscan.PackReq, error) {
	url := strings.TrimRight(registry, "/") + "/packs/suggest.json"
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch catalog %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetch catalog %s: HTTP %d", url, resp.StatusCode)
	}
	// 4 MiB bounds the index (~58 packs is a few KB) against a runaway body.
	return decodeCatalog(io.LimitReader(resp.Body, 4<<20))
}

func decodeCatalog(r io.Reader) ([]hostscan.PackReq, error) {
	var doc struct {
		Packs []catalogPack `json:"packs"`
	}
	if err := json.NewDecoder(r).Decode(&doc); err != nil {
		return nil, fmt.Errorf("parse catalog: %w", err)
	}
	out := make([]hostscan.PackReq, 0, len(doc.Packs))
	for _, p := range doc.Packs {
		out = append(out, hostscan.PackReq{
			ID:        p.ID,
			Name:      p.Name,
			OS:        p.OS,
			Binaries:  p.Detect.Binaries,
			Processes: p.Detect.Processes,
			Ports:     p.Detect.Ports,
		})
	}
	return out, nil
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

func writeSuggestions(w io.Writer, suggestions []hostscan.Suggestion) {
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
		fmt.Fprintf(w, "  emisar pack install %s\n", s.ID)
	}
	fmt.Fprintln(w, "\nThen reload the runner: sudo systemctl reload emisar")
	fmt.Fprintln(w, "Browse the full catalog: "+defaultRegistry+"/packs")
}
