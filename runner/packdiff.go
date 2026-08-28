package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"text/tabwriter"
	"unicode/utf8"

	"github.com/spf13/cobra"

	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// maxDiffFileBytes is the per-file ceiling for rendering changed lines. The
// largest script in the pack catalog is around 30 KB, so this is ample; past it
// a file reports as changed without printing, because packs.Fetch admits files
// up to 8 MiB and one of those would bury the diff an operator came to read.
const maxDiffFileBytes = 256 << 10

// packDiffSide identifies one end of the comparison.
type packDiffSide struct {
	Version string `json:"version"`
	Hash    string `json:"hash"`
}

// packDiffNote is one security-relevant change, called out above the diff
// because it is the kind of line that is easy to skim past in raw YAML.
type packDiffNote struct {
	Kind     string `json:"kind"`
	ActionID string `json:"action_id,omitempty"`
	Detail   string `json:"detail"`
}

// packDiffFile is one changed file. Status is added, removed, or modified.
type packDiffFile struct {
	Path    string `json:"path"`
	Status  string `json:"status"`
	Unified string `json:"unified"`
}

type packDiffReport struct {
	PackID string       `json:"pack_id"`
	From   packDiffSide `json:"from"`
	To     packDiffSide `json:"to"`
	// SameVersionNewHash means the installed tree was edited locally or the
	// registry republished this version — either way `pack update` overwrites it.
	SameVersionNewHash bool           `json:"same_version_new_hash"`
	InstalledLoadError string         `json:"installed_load_error,omitempty"`
	FilesModified      int            `json:"files_modified"`
	FilesAdded         int            `json:"files_added"`
	FilesRemoved       int            `json:"files_removed"`
	Insertions         int            `json:"insertions"`
	Deletions          int            `json:"deletions"`
	Notes              []packDiffNote `json:"notes"`
	Files              []packDiffFile `json:"files"`
}

func packDiffCmd() *cobra.Command {
	var (
		registry string
		to       string
		stat     bool
	)
	cmd := &cobra.Command{
		Use:   "diff <id>",
		Short: "Show the changed lines between an installed pack and the registry's",
		Long: `Print what a pack upgrade would change, before it changes anything.

The candidate is fetched and hash-verified exactly the way 'pack update'
fetches it, then compared line by line against the installed copy. Nothing
is written: the packs dir is untouched and the daemon is not reloaded.

The diff covers exactly the files that form the pack's content hash —
pack.yaml, its referenced action YAMLs, and its referenced scripts. A
pack's test fixtures, Dockerfile, and docs are neither loaded by the
runner nor covered by the hash, so they never appear.

Above the diff, changes that alter what this host may do are called out:
an escalated risk tier, a dropped redaction rule, a changed execution
user, an argument that is no longer marked sensitive, a widened path
allowlist, symlinks enabled, or a newly required setup variable.

  emisar pack diff redis              # vs the registry's current version
  emisar pack diff redis --to 0.5.0   # vs a specific published version
  emisar pack diff redis --stat       # the summary and callouts only`,
		Args: requireOne("<id>"),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			if !packspec.ValidPackID(id) {
				return fmt.Errorf("invalid pack name %q", id)
			}
			if to != "" && !packspec.ValidVersion(to) {
				return fmt.Errorf("invalid version %q", to)
			}
			registry = resolveRegistry(registry)

			dirs, err := resolvePackDirs()
			if err != nil {
				return err
			}
			installed, err := installedPackForDiff(dirs, id)
			if err != nil {
				return err
			}

			// The version-pinned URL carries no index entry to check against, so
			// only the bare-name path can verify the candidate. Fetch accordingly.
			source := id
			var indexHash string
			if to != "" {
				source = id + "=" + to
			} else {
				index, err := fetchPackIndex(cmd.Context(), registry)
				if err != nil {
					return err
				}
				rp, ok := index[id]
				if !ok {
					return fmt.Errorf("pack %q is not in the registry at %s — nothing to compare against", id, registry)
				}
				indexHash = rp.Hash
			}

			src, cleanup, err := resolvePackSource(cmd.Context(), source, registry)
			if err != nil {
				return err
			}
			if cleanup != nil {
				defer cleanup()
			}

			candidateReg, err := packs.LoadOne(src, packs.LoadOptions{})
			if err != nil {
				return err
			}
			candidate := candidateReg.Packs()[0]
			if candidate.ID != id {
				return fmt.Errorf("registry served pack %q, expected %q", candidate.ID, id)
			}
			candidateHash, _ := candidateReg.PackHash(candidate.ID)
			// The whole point of the command is to review the bytes `pack update`
			// would install, so bytes the registry does not vouch for are refused
			// rather than diffed with a warning.
			if indexHash != "" && !hashEqual(candidateHash, indexHash) {
				return fmt.Errorf("hash mismatch: index advertised %s, tarball is %s", normalizeHash(indexHash), candidateHash)
			}

			report, err := buildPackDiff(installed, candidateReg, candidate, candidateHash)
			if err != nil {
				return err
			}
			if flagJSONOut {
				return printJSON(report)
			}
			writePackDiff(os.Stdout, report, stat)
			return nil
		},
	}
	cmd.Flags().StringVar(&to, "to", "", "compare against this published version instead of the registry's current one")
	cmd.Flags().BoolVar(&stat, "stat", false, "print the summary and callouts without the changed lines")
	cmd.Flags().StringVar(&registry, "registry", "", "pack registry base URL (default $EMISAR_PACKS_REGISTRY or "+defaultRegistry+")")
	return cmd
}

// installedSide is the installed end of the comparison. A pack that fails to
// load keeps its loadErr and a nil registry: the diff then shows every file the
// candidate would put in its place, which is more use than refusing to run.
type installedSide struct {
	reg     *packs.Registry
	pack    *packspec.Pack
	loadErr error
}

// installedPackForDiff finds one installed pack across the configured dirs. It
// loads each root independently, the way inspectInstalledPacks does, so one
// broken pack elsewhere in the dir cannot hide the one being asked about.
func installedPackForDiff(dirs []string, id string) (installedSide, error) {
	for _, dir := range dirs {
		roots, err := installedPackRoots(dir)
		if err != nil {
			return installedSide{}, err
		}
		for _, root := range roots {
			reg, err := packs.LoadOne(root, packs.LoadOptions{})
			if err != nil {
				// Fall back to the directory name: a pack too broken to parse
				// still needs to be diffable against the version that repairs it.
				if filepath.Base(root) == id {
					return installedSide{loadErr: err}, nil
				}
				continue
			}
			if p := reg.Packs()[0]; p.ID == id {
				return installedSide{reg: reg, pack: p}, nil
			}
		}
	}
	return installedSide{}, fmt.Errorf("pack %q is not installed (looked in %s)", id, strings.Join(dirs, ", "))
}

// hashedFiles returns the files that form a pack's content hash — pack.yaml,
// its referenced action YAMLs, and its referenced scripts — keyed by pack-
// relative path.
//
// Keying by path is also what deduplicates: the loader appends one hash entry
// per script-kind action, so two actions sharing a script yield the same path
// twice (internal/packs/loader.go).
func hashedFiles(reg *packs.Registry, id string) (map[string][]byte, error) {
	if reg == nil {
		return map[string][]byte{}, nil
	}
	files, err := reg.PackFiles(id)
	if err != nil {
		return nil, err
	}
	out := make(map[string][]byte, len(files))
	for _, f := range files {
		out[f.Rel] = f.Data
	}
	return out, nil
}

func buildPackDiff(installed installedSide, candidateReg *packs.Registry, candidate *packspec.Pack, candidateHash string) (packDiffReport, error) {
	oldFiles, err := hashedFiles(installed.reg, candidate.ID)
	if err != nil {
		return packDiffReport{}, err
	}
	newFiles, err := hashedFiles(candidateReg, candidate.ID)
	if err != nil {
		return packDiffReport{}, err
	}

	report := packDiffReport{
		PackID: candidate.ID,
		To:     packDiffSide{Version: candidate.Version, Hash: candidateHash},
		// Non-nil so an unchanged pack serializes as [] rather than null, which
		// a `jq '.files[]'` consumer would fail on.
		Notes: []packDiffNote{},
		Files: []packDiffFile{},
	}
	if installed.loadErr != nil {
		report.InstalledLoadError = installed.loadErr.Error()
		report.From = packDiffSide{Version: "unreadable"}
	} else {
		hash, _ := installed.reg.PackHash(candidate.ID)
		report.From = packDiffSide{Version: installed.pack.Version, Hash: hash}
		report.SameVersionNewHash = installed.pack.Version == candidate.Version && !hashEqual(hash, candidateHash)
		report.Notes = packDiffNotes(installed.reg, candidateReg, installed.pack, candidate)
	}

	paths := make([]string, 0, len(oldFiles)+len(newFiles))
	for p := range oldFiles {
		paths = append(paths, p)
	}
	for p := range newFiles {
		if _, both := oldFiles[p]; !both {
			paths = append(paths, p)
		}
	}
	sort.Strings(paths)

	for _, path := range paths {
		oldData, hadOld := oldFiles[path]
		newData, hasNew := newFiles[path]
		if hadOld && hasNew && bytes.Equal(oldData, newData) {
			continue
		}

		file := packDiffFile{Path: path, Status: "modified"}
		switch {
		case !hadOld:
			file.Status = "added"
			report.FilesAdded++
		case !hasNew:
			file.Status = "removed"
			report.FilesRemoved++
		default:
			report.FilesModified++
		}

		if !utf8.Valid(oldData) || !utf8.Valid(newData) {
			file.Unified = "binary file differs\n"
		} else if len(oldData) > maxDiffFileBytes || len(newData) > maxDiffFileBytes {
			file.Unified = fmt.Sprintf("file is larger than %d KiB — not rendered\n", maxDiffFileBytes>>10)
		} else {
			script := diffLines(splitLines(oldData), splitLines(newData))
			insertions, deletions := countEdits(script)
			report.Insertions += insertions
			report.Deletions += deletions
			file.Unified = unifiedDiff(script, diffContext)
			// Identical lines with different bytes means the trailing newline
			// moved. Say so rather than list a changed file with an empty diff.
			if file.Unified == "" {
				file.Unified = "trailing newline differs\n"
			}
		}
		report.Files = append(report.Files, file)
	}
	return report, nil
}

var riskRank = map[actionspec.Risk]int{
	actionspec.RiskLow:      0,
	actionspec.RiskMedium:   1,
	actionspec.RiskHigh:     2,
	actionspec.RiskCritical: 3,
}

// packDiffNotes reports the changes that alter what this host may do. They are
// all visible in the diff itself; they are lifted out because each is a single
// line that an operator scrolling a few hundred lines of YAML will miss.
func packDiffNotes(oldReg, newReg *packs.Registry, oldPack, newPack *packspec.Pack) []packDiffNote {
	notes := []packDiffNote{}
	oldActions := actionsByID(oldReg, oldPack.ID)
	newActions := actionsByID(newReg, newPack.ID)

	ids := make([]string, 0, len(newActions))
	for id := range newActions {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	var added []string
	for _, id := range ids {
		o, existed := oldActions[id]
		if !existed {
			added = append(added, id)
			continue
		}
		n := newActions[id]

		if riskRank[n.Risk] > riskRank[o.Risk] {
			notes = append(notes, packDiffNote{"risk_escalated", id, fmt.Sprintf("%s → %s", o.Risk, n.Risk)})
		}
		if o.Execution.User != n.Execution.User {
			notes = append(notes, packDiffNote{"user_changed", id,
				fmt.Sprintf("%s → %s", orDefaultUser(o.Execution.User), orDefaultUser(n.Execution.User))})
		}
		for _, name := range removedRedactions(o, n) {
			notes = append(notes, packDiffNote{"redaction_removed", id, name})
		}
		for _, name := range droppedSensitive(o, n) {
			notes = append(notes, packDiffNote{"sensitive_dropped", id, "arg " + name})
		}
		for _, detail := range widenedPaths(o, n) {
			notes = append(notes, packDiffNote{"paths_widened", id, detail})
		}
	}

	var removed []string
	for id := range oldActions {
		if _, ok := newActions[id]; !ok {
			removed = append(removed, id)
		}
	}
	sort.Strings(removed)

	if !oldPack.AllowSymlinks && newPack.AllowSymlinks {
		notes = append(notes, packDiffNote{Kind: "symlinks_enabled", Detail: "the pack now ships symlinks"})
	}
	for _, name := range newRequiredEnv(oldPack, newPack) {
		notes = append(notes, packDiffNote{Kind: "setup_env_required", Detail: name + " must be set and added to inherit_env"})
	}
	if len(added) > 0 {
		notes = append(notes, packDiffNote{Kind: "actions_added", Detail: strings.Join(added, ", ")})
	}
	if len(removed) > 0 {
		notes = append(notes, packDiffNote{Kind: "actions_removed", Detail: strings.Join(removed, ", ")})
	}
	return notes
}

func actionsByID(reg *packs.Registry, packID string) map[string]*actionspec.Action {
	out := map[string]*actionspec.Action{}
	if reg == nil {
		return out
	}
	for _, a := range reg.Actions() {
		if a.PackID == packID {
			out[a.ID] = a
		}
	}
	return out
}

// orDefaultUser names the empty execution.user, which means "the service user".
func orDefaultUser(user string) string {
	if user == "" {
		return "the runner's own user"
	}
	return user
}

// removedRedactions returns the redaction rules the new action no longer
// applies. Losing one un-masks whatever it used to cover, in both the cloud
// payload and the local audit journal.
func removedRedactions(o, n *actionspec.Action) []string {
	kept := make(map[string]struct{}, len(n.Output.Redact))
	for _, r := range n.Output.Redact {
		kept[r.Name] = struct{}{}
	}
	var out []string
	for _, r := range o.Output.Redact {
		if _, ok := kept[r.Name]; !ok {
			out = append(out, r.Name)
		}
	}
	return out
}

// droppedSensitive returns args that were marked sensitive and no longer are.
// The value then appears verbatim in execution.argv and the recorded command.
func droppedSensitive(o, n *actionspec.Action) []string {
	now := make(map[string]bool, len(n.Args))
	present := make(map[string]bool, len(n.Args))
	for _, a := range n.Args {
		now[a.Name] = a.Sensitive
		present[a.Name] = true
	}
	var out []string
	for _, a := range o.Args {
		if a.Sensitive && present[a.Name] && !now[a.Name] {
			out = append(out, a.Name)
		}
	}
	return out
}

// widenedPaths reports path constraints that admit more than they used to. An
// allowlist widens by gaining entries or disappearing; a denylist widens by
// losing them.
func widenedPaths(o, n *actionspec.Action) []string {
	old := make(map[string]actionspec.Arg, len(o.Args))
	for _, a := range o.Args {
		old[a.Name] = a
	}

	var out []string
	for _, na := range n.Args {
		oa, ok := old[na.Name]
		if !ok || oa.Validation == nil {
			continue
		}
		ov := oa.Validation
		nv := na.Validation
		if nv == nil {
			nv = &actionspec.Validation{}
		}

		for _, l := range []struct {
			field    string
			old, new []string
		}{
			{"allowed_paths", ov.AllowedPaths, nv.AllowedPaths},
			{"allowed_prefixes", ov.AllowedPrefixes, nv.AllowedPrefixes},
		} {
			gained := missingFrom(l.new, l.old)
			switch {
			case len(l.old) > 0 && len(l.new) == 0:
				out = append(out, "arg "+na.Name+": "+l.field+" removed")
			case len(gained) > 0:
				out = append(out, "arg "+na.Name+": "+l.field+" gained "+strings.Join(gained, ", "))
			}
		}
		for _, l := range []struct {
			field    string
			old, new []string
		}{
			{"denied_paths", ov.DeniedPaths, nv.DeniedPaths},
			{"denied_prefixes", ov.DeniedPrefixes, nv.DeniedPrefixes},
		} {
			if lost := missingFrom(l.old, l.new); len(lost) > 0 {
				out = append(out, "arg "+na.Name+": "+l.field+" no longer blocks "+strings.Join(lost, ", "))
			}
		}
	}
	return out
}

// missingFrom returns the entries of have that are absent from want.
func missingFrom(have, want []string) []string {
	set := make(map[string]struct{}, len(want))
	for _, s := range want {
		set[s] = struct{}{}
	}
	var out []string
	for _, s := range have {
		if _, ok := set[s]; !ok {
			out = append(out, s)
		}
	}
	return out
}

// newRequiredEnv returns setup vars the operator must now provide — work the
// pack cannot authenticate without, and the most common reason a fresh install
// fails to reach its target.
func newRequiredEnv(oldPack, newPack *packspec.Pack) []string {
	had := make(map[string]bool, len(oldPack.Setup.Env))
	for _, e := range oldPack.Setup.Env {
		had[e.Name] = e.Required
	}
	var out []string
	for _, e := range newPack.Setup.Env {
		if e.Required && !had[e.Name] {
			out = append(out, e.Name)
		}
	}
	return out
}

// noteLabels are the operator-facing headings for each note kind, in the order
// they print — the changes that widen what a host may do come first.
var noteLabels = []struct{ kind, label string }{
	{"risk_escalated", "risk escalated"},
	{"redaction_removed", "redaction rule gone"},
	{"user_changed", "runs as a different user"},
	{"sensitive_dropped", "no longer sensitive"},
	{"paths_widened", "path limits widened"},
	{"symlinks_enabled", "symlinks enabled"},
	{"setup_env_required", "new required setup var"},
	{"actions_added", "actions added"},
	{"actions_removed", "actions removed"},
}

func writePackDiff(w io.Writer, r packDiffReport, stat bool) {
	style := newStyler(w)

	fmt.Fprintf(w, "\n%s  %s → %s   %s → %s\n",
		style.bold(r.PackID), r.From.Version, r.To.Version,
		style.dim(shortHash(r.From.Hash)), style.dim(shortHash(r.To.Hash)))

	var parts []string
	for _, c := range []struct {
		n     int
		label string
	}{
		{r.FilesModified, "files changed"},
		{r.FilesAdded, "added"},
		{r.FilesRemoved, "removed"},
	} {
		if c.n > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", c.n, c.label))
		}
	}
	if len(parts) == 0 {
		fmt.Fprintf(w, "No changes.\n")
		return
	}
	fmt.Fprintf(w, "%s · %s, %s\n", strings.Join(parts, ", "),
		style.ok(fmt.Sprintf("%d insertions(+)", r.Insertions)),
		style.fail(fmt.Sprintf("%d deletions(-)", r.Deletions)))

	if r.InstalledLoadError != "" {
		fmt.Fprintf(w, "\n  %s\n    %s\n", style.warn("! the installed pack does not load"), r.InstalledLoadError)
		fmt.Fprintf(w, "    Everything below is what `pack update` would put in its place.\n")
	}
	if r.SameVersionNewHash {
		fmt.Fprintf(w, "\n  %s\n", style.warn("! same version, different hash"))
		fmt.Fprintf(w, "    The installed pack was modified locally, or the registry republished\n")
		fmt.Fprintf(w, "    this version. `pack update` would overwrite the installed copy.\n")
	}

	if len(r.Notes) > 0 {
		// Aligned first, colored second: tabwriter measures a cell with len(),
		// so an ANSI escape inside one counts toward the column width and skews
		// every row after it.
		var aligned bytes.Buffer
		tw := tabwriter.NewWriter(&aligned, 0, 2, 2, ' ', 0)
		for _, l := range noteLabels {
			for _, note := range r.Notes {
				if note.Kind != l.kind {
					continue
				}
				fmt.Fprintf(tw, "  ! %s\t%s\t%s\n", l.label, note.ActionID, note.Detail)
			}
		}
		tw.Flush()
		fmt.Fprintln(w)
		for _, line := range strings.Split(strings.TrimSuffix(aligned.String(), "\n"), "\n") {
			fmt.Fprintln(w, style.warn(strings.TrimRight(line, " ")))
		}
	}

	if stat {
		fmt.Fprintf(w, "\nChanged files:\n")
		for _, f := range r.Files {
			fmt.Fprintf(w, "  %-10s %s\n", f.Status, f.Path)
		}
		return
	}

	for _, f := range r.Files {
		fmt.Fprintf(w, "\n%s\n%s\n",
			style.bold("--- a/"+f.Path), style.bold("+++ b/"+f.Path))
		writeUnified(w, style, f.Unified)
	}
}

// writeUnified colors the diff at print time so the report's own text stays
// plain — the --json path serializes the same strings.
func writeUnified(w io.Writer, style styler, unified string) {
	for _, line := range strings.Split(strings.TrimSuffix(unified, "\n"), "\n") {
		switch {
		case strings.HasPrefix(line, "+"):
			fmt.Fprintln(w, style.ok(line))
		case strings.HasPrefix(line, "-"):
			fmt.Fprintln(w, style.fail(line))
		case strings.HasPrefix(line, "@@"):
			fmt.Fprintln(w, style.dim(line))
		default:
			fmt.Fprintln(w, line)
		}
	}
}
