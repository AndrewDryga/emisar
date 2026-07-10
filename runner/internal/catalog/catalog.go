// Package catalog builds the published pack-registry artifacts from a
// loaded pack set: the machine-readable catalog.json, the lean
// suggest.json index, the JSON schemas, and one immutable gzip tarball
// per pack. The runner's own loader (internal/packs) is the single source
// of the content hash — this package never re-hashes a pack differently,
// so the portal, the runner, and the published catalog agree byte-for-byte.
//
// Immutability falls out of content-addressing: a pack tarball lives at
// v1/packs/<id>/<version>/<sha256hex>/pack.tar.gz, so identical bytes
// always resolve to the same object and a byte change without a version
// bump lands at a different path (and is rejected at build time by the
// drift check). The mutable pointers (catalog.json, suggest.json) are
// overwritten each publish; the GCS bucket's object versioning keeps every
// prior generation fetchable.
package catalog

import (
	"fmt"
	"sort"
	"strings"

	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// SchemaVersion is the catalog.json document schema version. It is
// independent of the pack/action on-disk schema versions.
const SchemaVersion = 1

// DefaultRepoURL is the public source repository the catalog links back to
// for pack and action source. Overridable via BuildOptions.
const DefaultRepoURL = "https://github.com/andrewdryga/emisar"

// genericBinaries are ubiquitous helpers present on nearly every host and
// used only to TALK to a service (curl hits an HTTP API). They say nothing
// about which services run here, so they are stripped when a pack's detect
// signal is derived from its `requires` binaries. This mirrors the portal's
// server-side list (EmisarWeb.PacksRegistry @generic_binaries) — the filter
// lives on the build/catalog side, not the runner, so it evolves with a
// publish rather than a runner upgrade.
var genericBinaries = map[string]struct{}{
	"curl": {}, "wget": {}, "nc": {}, "ncat": {}, "netcat": {},
	"socat": {}, "jq": {}, "openssl": {},
}

// Catalog is the full published catalog.json document.
type Catalog struct {
	SchemaVersion int    `json:"schema_version"`
	Packs         []Pack `json:"packs"`
}

// Pack is one catalog entry. It carries everything the portal pack pages,
// install snippets, command preview, and suggest index need without the
// pack bytes themselves — those live in the immutable tarball at TarballURL.
type Pack struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Version     string   `json:"version"`
	Description string   `json:"description"`
	Vendor      string   `json:"vendor"`
	Homepage    string   `json:"homepage"`
	SourceURL   string   `json:"source_url"`
	ContentHash string   `json:"content_hash"`
	TarballURL  string   `json:"tarball_url"`
	Requires    Requires `json:"requires"`
	Detect      Detect   `json:"detect"`
	Actions     []Action `json:"actions"`
}

// Requires mirrors the pack's declared host requirements.
type Requires struct {
	OS       []string `json:"os"`
	Binaries []string `json:"binaries"`
}

// Detect is the derived service-presence signal used by `emisar pack
// suggest`: an explicit detect block wins, otherwise binaries fall back to
// `requires` minus generic helpers. Processes/ports are always the declared
// values.
type Detect struct {
	Binaries  []string `json:"binaries"`
	Processes []string `json:"processes"`
	Ports     []int    `json:"ports"`
}

func (d Detect) empty() bool {
	return len(d.Binaries) == 0 && len(d.Processes) == 0 && len(d.Ports) == 0
}

// Action is a catalog action summary — enough for the catalog action list,
// risk display, and the approval-page command preview, without the full arg
// schema (that stays in the pack YAML the runner loads).
type Action struct {
	ID      string   `json:"id"`
	Title   string   `json:"title"`
	Kind    string   `json:"kind"`
	Risk    string   `json:"risk"`
	Command *Command `json:"command,omitempty"`
}

// Command is an exec action's binary + argv template (placeholders intact),
// nil for a script-kind action (no single-line invocation to preview).
type Command struct {
	Binary string   `json:"binary"`
	Argv   []string `json:"argv"`
}

// BuildOptions parameterizes catalog construction.
type BuildOptions struct {
	// BaseURL is the public HTTPS base the tarball URLs join onto, e.g.
	// https://storage.googleapis.com/emisar-pack-registry. Required.
	BaseURL string
	// RepoURL is the source repo for source_url links. Defaults to
	// DefaultRepoURL when empty.
	RepoURL string
	// Previous, when non-nil, is the currently-published catalog. Build
	// fails if any pack changed bytes for an already-published id+version
	// (the "preserve every version/hash" guarantee) — bump the version to
	// publish new bytes.
	Previous *Catalog
}

// Build turns a loaded pack registry into a Catalog. The registry must have
// been loaded WITHOUT SkipScriptChecksum so the content hash matches what
// the runner and portal compute.
func Build(reg *packs.Registry, opts BuildOptions) (*Catalog, error) {
	if opts.BaseURL == "" {
		return nil, fmt.Errorf("catalog: BaseURL is required")
	}
	repoURL := opts.RepoURL
	if repoURL == "" {
		repoURL = DefaultRepoURL
	}
	base := strings.TrimRight(opts.BaseURL, "/")

	actionsByPack := map[string][]Action{}
	for _, a := range reg.Actions() {
		actionsByPack[a.PackID] = append(actionsByPack[a.PackID], catalogAction(a))
	}

	cat := &Catalog{SchemaVersion: SchemaVersion, Packs: []Pack{}}
	for _, p := range reg.Packs() {
		hash, ok := reg.PackHash(p.ID)
		if !ok {
			return nil, fmt.Errorf("catalog: no content hash for pack %q", p.ID)
		}
		actions := actionsByPack[p.ID]
		if actions == nil {
			actions = []Action{}
		}
		cat.Packs = append(cat.Packs, Pack{
			ID:          p.ID,
			Name:        p.Name,
			Version:     p.Version,
			Description: normalizeDescription(p.Description),
			Vendor:      vendorOr(p.Vendor),
			Homepage:    homepageOr(p.Homepage, repoURL),
			SourceURL:   repoURL + "/tree/main/packs/" + p.ID,
			ContentHash: hash,
			TarballURL:  base + "/" + TarballObject(p.ID, p.Version, hash),
			Requires:    Requires{OS: nonNil(p.Requires.OS), Binaries: nonNil(p.Requires.Binaries)},
			Detect:      deriveDetect(p.Requires.Binaries, p.Detect.Binaries, p.Detect.Processes, p.Detect.Ports),
			Actions:     actions,
		})
	}
	sort.Slice(cat.Packs, func(i, j int) bool { return cat.Packs[i].ID < cat.Packs[j].ID })

	if err := cat.checkDrift(opts.Previous); err != nil {
		return nil, err
	}
	return cat, nil
}

// SuggestIndex is the lean per-pack index `emisar pack suggest` matches
// against: id, name, OS, and the derived detect signal. Packs whose detect
// is all-empty are omitted — with no signal there is nothing to suggest them
// on. Mirrors EmisarWeb.PacksRegistry.suggest_index.
type SuggestIndex struct {
	Packs []SuggestPack `json:"packs"`
}

// SuggestPack is one suggest.json entry.
type SuggestPack struct {
	ID     string   `json:"id"`
	Name   string   `json:"name"`
	OS     []string `json:"os"`
	Detect Detect   `json:"detect"`
}

// Suggest derives the suggest.json index from the catalog.
func (c *Catalog) Suggest() SuggestIndex {
	out := SuggestIndex{Packs: []SuggestPack{}}
	for _, p := range c.Packs {
		if p.Detect.empty() {
			continue
		}
		out.Packs = append(out.Packs, SuggestPack{
			ID:     p.ID,
			Name:   p.Name,
			OS:     p.Requires.OS,
			Detect: p.Detect,
		})
	}
	return out
}

func (c *Catalog) checkDrift(prev *Catalog) error {
	if prev == nil {
		return nil
	}
	prevHash := make(map[string]string, len(prev.Packs))
	for _, p := range prev.Packs {
		prevHash[p.ID+"\x00"+p.Version] = p.ContentHash
	}
	var drift []string
	for _, p := range c.Packs {
		if h, ok := prevHash[p.ID+"\x00"+p.Version]; ok && h != p.ContentHash {
			drift = append(drift, fmt.Sprintf(
				"pack %q version %q changed bytes (%s → %s) — bump the version to publish new content",
				p.ID, p.Version, h, p.ContentHash))
		}
	}
	if len(drift) > 0 {
		return fmt.Errorf("pack registry drift vs previous catalog:\n  %s", strings.Join(drift, "\n  "))
	}
	return nil
}

func catalogAction(a *actionspec.Action) Action {
	out := Action{
		ID:    a.ID,
		Title: a.Title,
		Kind:  string(a.Kind),
		Risk:  string(a.Risk),
	}
	if a.Kind == actionspec.KindExec && a.Execution.Command != nil {
		out.Command = &Command{
			Binary: a.Execution.Command.Binary,
			Argv:   nonNil(a.Execution.Command.Argv),
		}
	}
	return out
}

// deriveDetect mirrors the portal's detect_signal: an explicit
// detect.binaries wins; otherwise derive from requires binaries minus
// generic helpers. Declared processes/ports are always kept.
func deriveDetect(requiresBinaries, detectBinaries, processes []string, ports []int) Detect {
	binaries := detectBinaries
	if len(binaries) == 0 {
		binaries = stripGeneric(requiresBinaries)
	}
	return Detect{
		Binaries:  nonNil(binaries),
		Processes: nonNil(processes),
		Ports:     nonNilInts(ports),
	}
}

func stripGeneric(binaries []string) []string {
	out := []string{}
	for _, b := range binaries {
		if _, generic := genericBinaries[strings.ToLower(b)]; generic {
			continue
		}
		out = append(out, b)
	}
	return out
}

// normalizeDescription trims and collapses internal whitespace, matching the
// portal's `String.trim |> String.replace(~r/\s+/, " ")`.
func normalizeDescription(s string) string { return strings.Join(strings.Fields(s), " ") }

func vendorOr(v string) string {
	if v == "" {
		return "emisar"
	}
	return v
}

func homepageOr(v, repoURL string) string {
	if v == "" {
		return repoURL
	}
	return v
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func nonNilInts(s []int) []int {
	if s == nil {
		return []int{}
	}
	return s
}
