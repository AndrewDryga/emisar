package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/repo"
)

// Age windows in days, keyed by bump type, mirroring .github/dependabot.yml
// `cooldown`. "new" = a dependency not present on the base branch; "unknown" =
// a version string we could not parse as semver. Both fall back to the
// most-conservative-that-stays-usable default (7d), matching cooldown's
// `default-days`. Keep the two in sync when either changes.
var windows = map[string]int{"major": 30, "minor": 14, "patch": 7, "new": 7, "unknown": 7}

// manifest is one gated lockfile: its ecosystem decides the parser and the
// registry the publish timestamps come from.
type manifest struct {
	eco  string
	path string
}

var manifests = []manifest{
	{"hex", "portal/mix.lock"},
	{"go", "runner/go.mod"},
	{"go", "mcp/go.mod"},
	{"go", "tools/go.mod"},
	{"npm", "portal/.agent/scripts/package-lock.json"},
}

const allowlistPath = ".dep-age-allow"

// --------------------------------------------------------------------------
// Lockfile parsing: manifest text -> {package: version}
// --------------------------------------------------------------------------

var (
	hexLine       = regexp.MustCompile(`^\s*"([^"]+)":\s*\{:hex,\s*:[^,]+,\s*"([^"]+)"`)
	hexNonregLine = regexp.MustCompile(`^\s*"([^"]+)":\s*\{:(git|path)\b`)
	goRequireLine = regexp.MustCompile(`^\s*([^\s()]+)\s+(v[^\s]+)`)
)

// parseHex maps mix.lock to {package: version}, hex packages only. :git /
// :path entries have no registry release date to check; parseNonregistry
// surfaces them for review instead.
func parseHex(text string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		if m := hexLine.FindStringSubmatch(line); m != nil {
			out[m[1]] = m[2]
		}
	}
	return out
}

// parseGo maps go.mod to {module: version} across every require entry (direct
// and // indirect). replace / exclude / retract directives are ignored here —
// replace targets are pinned locally and carry no proxy release date.
func parseGo(text string) map[string]string {
	out := map[string]string{}
	inBlock := false
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		switch {
		case strings.HasPrefix(line, "require ("):
			inBlock = true
		case inBlock:
			if line == ")" {
				inBlock = false
			} else if m := goRequireLine.FindStringSubmatch(line); m != nil {
				out[m[1]] = m[2]
			}
		case strings.HasPrefix(line, "require "):
			if m := goRequireLine.FindStringSubmatch(line[len("require "):]); m != nil {
				out[m[1]] = m[2]
			}
		}
	}
	return out
}

// npmLock is the slice of package-lock.json (lockfileVersion 2/3) this gate
// reads: the packages map keyed by node_modules path.
type npmLock struct {
	Packages map[string]struct {
		Name     string `json:"name"`
		Version  string `json:"version"`
		Resolved string `json:"resolved"`
		Link     bool   `json:"link"`
	} `json:"packages"`
}

func npmEntryName(path, declared string) string {
	if declared != "" {
		return declared
	}
	if i := strings.LastIndex(path, "node_modules/"); i >= 0 {
		return path[i+len("node_modules/"):]
	}
	return path
}

// parseNpm maps package-lock.json to {package: version}, npm-registry entries
// only. The "" key is the project itself; link entries and non-registry
// resolved URLs (git/file/tarball) have no registry release date and are
// surfaced by parseNonregistry.
func parseNpm(text string) (map[string]string, error) {
	var lock npmLock
	if err := json.Unmarshal([]byte(text), &lock); err != nil {
		return nil, fmt.Errorf("parsing package-lock.json: %w", err)
	}
	out := map[string]string{}
	for path, meta := range lock.Packages {
		if !strings.HasPrefix(path, "node_modules/") || meta.Link || meta.Version == "" {
			continue
		}
		if meta.Resolved != "" && !strings.HasPrefix(meta.Resolved, "https://registry.npmjs.org/") {
			continue
		}
		out[npmEntryName(path, meta.Name)] = meta.Version
	}
	return out, nil
}

func parseManifest(eco, text string) (map[string]string, error) {
	switch eco {
	case "hex":
		return parseHex(text), nil
	case "go":
		return parseGo(text), nil
	case "npm":
		return parseNpm(text)
	}
	return nil, fmt.Errorf("unknown ecosystem %q", eco)
}

// parseNonregistry maps a manifest to {name: source-descriptor} for deps with
// NO registry release date — hex :git/:path packages, go replace targets, npm
// link/git/file entries. These bypass age enforcement entirely (there is
// nothing to age-check), which is exactly the shape a malicious dependency
// takes to slip a lockfile gate; an added or changed one FAILS for human
// review rather than being silently trusted.
func parseNonregistry(eco, text string) map[string]string {
	out := map[string]string{}
	switch eco {
	case "hex":
		for _, line := range strings.Split(text, "\n") {
			if m := hexNonregLine.FindStringSubmatch(line); m != nil {
				out[m[1]] = m[2] + ": " + strings.TrimSpace(line)
			}
		}
	case "go":
		inBlock := false
		for _, raw := range strings.Split(text, "\n") {
			line := strings.TrimSpace(raw)
			switch {
			case strings.HasPrefix(line, "replace ("):
				inBlock = true
			case inBlock:
				if line == ")" {
					inBlock = false
				} else if before, after, ok := strings.Cut(line, "=>"); ok {
					out[strings.Fields(before)[0]] = "replace: " + strings.TrimSpace(after)
				}
			case strings.HasPrefix(line, "replace "):
				if before, after, ok := strings.Cut(line[len("replace "):], "=>"); ok {
					out[strings.Fields(before)[0]] = "replace: " + strings.TrimSpace(after)
				}
			}
		}
	case "npm":
		var lock npmLock
		if err := json.Unmarshal([]byte(text), &lock); err != nil {
			return out
		}
		for path, meta := range lock.Packages {
			if !strings.HasPrefix(path, "node_modules/") {
				continue
			}
			if meta.Link || (meta.Resolved != "" && !strings.HasPrefix(meta.Resolved, "https://registry.npmjs.org/")) {
				src := meta.Resolved
				if src == "" {
					src = "link"
				}
				out[npmEntryName(path, meta.Name)] = "non-registry: " + src
			}
		}
	}
	return out
}

// --------------------------------------------------------------------------
// Semver bump classification
// --------------------------------------------------------------------------

var semverRe = regexp.MustCompile(`^v?(\d+)\.(\d+)\.(\d+)`)

// bumpType classifies old->new as major/minor/patch/downgrade, "new" when there
// was no prior version, or "unknown" when either side isn't parseable semver
// (e.g. a Go pseudo-version bump we can't rank — treated conservatively).
func bumpType(old, new string) string {
	if old == "" {
		return "new"
	}
	mo, mn := semverRe.FindStringSubmatch(old), semverRe.FindStringSubmatch(new)
	if mo == nil || mn == nil {
		return "unknown"
	}
	toInts := func(m []string) [3]int {
		var out [3]int
		for i := 0; i < 3; i++ {
			out[i], _ = strconv.Atoi(m[i+1])
		}
		return out
	}
	o, n := toInts(mo), toInts(mn)
	for i := 0; i < len(o); i++ {
		if n[i] < o[i] {
			return "downgrade"
		}
		if n[i] > o[i] {
			break
		}
	}
	switch {
	case o[0] != n[0]:
		return "major"
	case o[1] != n[1]:
		return "minor"
	default:
		return "patch"
	}
}

// --------------------------------------------------------------------------
// Registry lookups: (ecosystem, package, version) -> published-at (UTC)
// --------------------------------------------------------------------------

var httpClient = &http.Client{Timeout: 20 * time.Second}

func getJSON(url string, out any) error {
	var last error
	for attempt := 0; attempt < 3; attempt++ {
		req, err := http.NewRequest(http.MethodGet, url, nil)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", "emisar-dep-age-gate")
		resp, err := httpClient.Do(req)
		if err != nil {
			last = err
			continue
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
		resp.Body.Close()
		if err != nil {
			last = err
			continue
		}
		if resp.StatusCode != http.StatusOK {
			last = fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
			continue
		}
		if err := json.Unmarshal(body, out); err != nil {
			last = err
			continue
		}
		return nil
	}
	return fmt.Errorf("could not fetch %s after 3 attempts: %w", url, last)
}

// goEscape applies the Go module proxy's case-encoding: every uppercase
// letter becomes '!' + lowercase.
func goEscape(path string) string {
	var b strings.Builder
	for _, r := range path {
		if r >= 'A' && r <= 'Z' {
			b.WriteByte('!')
			b.WriteRune(r + ('a' - 'A'))
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func parseRegistryTime(ts string) (time.Time, error) {
	t, err := time.Parse(time.RFC3339Nano, ts)
	if err != nil {
		return time.Time{}, err
	}
	return t.UTC(), nil
}

// publishedAt returns the registry publish timestamp for a package version.
// An error means the age is unverifiable — the caller fails closed.
func publishedAt(eco, pkg, version string) (time.Time, error) {
	switch eco {
	case "hex":
		var data struct {
			InsertedAt string `json:"inserted_at"`
		}
		if err := getJSON(fmt.Sprintf("https://hex.pm/api/packages/%s/releases/%s", pkg, version), &data); err != nil {
			return time.Time{}, err
		}
		return parseRegistryTime(data.InsertedAt)
	case "go":
		var data struct {
			Time string `json:"Time"`
		}
		if err := getJSON(fmt.Sprintf("https://proxy.golang.org/%s/@v/%s.info", goEscape(pkg), version), &data); err != nil {
			return time.Time{}, err
		}
		return parseRegistryTime(data.Time)
	case "npm":
		// Scoped names keep the "@" but escape the "/" (@scope%2Fname).
		var data struct {
			Time map[string]string `json:"time"`
		}
		if err := getJSON("https://registry.npmjs.org/"+strings.ReplaceAll(pkg, "/", "%2F"), &data); err != nil {
			return time.Time{}, err
		}
		ts, ok := data.Time[version]
		if !ok {
			return time.Time{}, fmt.Errorf("npm packument for %s has no time for %s", pkg, version)
		}
		return parseRegistryTime(ts)
	}
	return time.Time{}, fmt.Errorf("unknown ecosystem %q", eco)
}

// --------------------------------------------------------------------------
// Allowlist (urgent-security-fix escape hatch)
// --------------------------------------------------------------------------

type allowKey struct{ eco, pkg, version string }

// loadAllowlist parses .dep-age-allow. A line must carry a non-empty reason
// after the version or it is rejected — the whole point is an auditable
// justification, so a bare exemption is a hard error.
func loadAllowlist(root string) (map[allowKey]bool, error) {
	allowed := map[allowKey]bool{}
	data, err := os.ReadFile(filepath.Join(root, allowlistPath))
	if err != nil {
		if os.IsNotExist(err) {
			return allowed, nil
		}
		return nil, err
	}
	for n, raw := range strings.Split(string(data), "\n") {
		line, _, _ := strings.Cut(raw, "#")
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) < 4 {
			return nil, fmt.Errorf("%s:%d: expected `ecosystem package version reason`, got: %q", allowlistPath, n+1, strings.TrimSpace(raw))
		}
		allowed[allowKey{parts[0], parts[1], parts[2]}] = true
	}
	return allowed, nil
}

// --------------------------------------------------------------------------
// Policy engine (pure — the tests drive this without a network)
// --------------------------------------------------------------------------

type candidate struct {
	eco, pkg, old, new string // old == "" means added
}

type violation struct {
	eco, pkg, version, bump string
	publishedAt             time.Time
	ageDays                 float64
	windowDays              int
	downgrade               bool
}

func evaluate(candidates []candidate, ages map[allowKey]time.Time, allowed map[allowKey]bool, now time.Time) []violation {
	var out []violation
	for _, c := range candidates {
		key := allowKey{c.eco, c.pkg, c.new}
		if allowed[key] {
			continue
		}
		kind := bumpType(c.old, c.new)
		if kind == "downgrade" {
			out = append(out, violation{eco: c.eco, pkg: c.pkg, version: c.new, bump: kind, downgrade: true})
			continue
		}
		window := windows[kind]
		pub := ages[key]
		ageDays := now.Sub(pub).Hours() / 24
		if ageDays < float64(window) {
			out = append(out, violation{
				eco: c.eco, pkg: c.pkg, version: c.new, bump: kind,
				publishedAt: pub, ageDays: ageDays, windowDays: window,
			})
		}
	}
	return out
}

// --------------------------------------------------------------------------
// check: diff the manifests vs a base ref, query registries, enforce
// --------------------------------------------------------------------------

// gitShow returns path's contents at ref, or "" and false when the file is
// absent there (a brand-new lockfile: every entry is treated as newly added).
func gitShow(root, ref, path string) (string, bool) {
	out, err := exec.Command("git", "-C", root, "show", ref+":"+path).Output()
	if err != nil {
		return "", false
	}
	return string(out), true
}

func refExists(root, ref string) bool {
	return exec.Command("git", "-C", root, "rev-parse", "--verify", "--quiet", ref+"^{commit}").Run() == nil
}

func readManifest(root, path string) (string, bool) {
	data, err := os.ReadFile(filepath.Join(root, path))
	if err != nil {
		return "", false
	}
	return string(data), true
}

// runCheck is the `check` subcommand body. Exit codes: 0 clean, 1 a too-fresh
// or unverifiable dependency (or an unvetted non-registry source), 2 internal.
func runCheck(baseRef string) int {
	root, err := repo.Root()
	if err != nil {
		fmt.Fprintf(os.Stderr, "::error::dep-age-gate: %v\n", err)
		return 2
	}

	if !refExists(root, baseRef) {
		// No resolvable base (e.g. a zero SHA on an initial/force push) means we
		// can't tell which versions this change *introduced*. Treating every
		// existing dep as newly added would flag deps that already merged through
		// the PR gate, so skip instead — the PR path is the real enforcement point.
		fmt.Printf("dep-age-gate: base ref %q does not resolve; nothing to diff, skipping.\n", baseRef)
		return 0
	}

	allowed, err := loadAllowlist(root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "::error::dep-age-gate: %v\n", err)
		return 2
	}

	// A non-registry source (hex :git/:path, go replace, npm link/git) has no
	// release date to age-check, so it would sail through the age gate — the
	// exact bypass a malicious dep uses. Fail on any added/changed one unless
	// it's audited in the allowlist under the `nonregistry` keyword.
	var nonreg []string
	for _, m := range manifests {
		head, ok := readManifest(root, m.path)
		if !ok {
			continue
		}
		headSrc := parseNonregistry(m.eco, head)
		baseSrc := map[string]string{}
		if baseText, ok := gitShow(root, baseRef, m.path); ok {
			baseSrc = parseNonregistry(m.eco, baseText)
		}
		for name, src := range headSrc {
			if baseSrc[name] != src && !allowed[allowKey{m.eco, name, "nonregistry"}] {
				nonreg = append(nonreg, fmt.Sprintf("  - %s %s: %s", m.eco, name, src))
			}
		}
	}
	if len(nonreg) > 0 {
		sort.Strings(nonreg)
		fmt.Println("::error::dep-age-gate: added/changed non-registry dependency source(s) — cannot age-verify, needs review:")
		fmt.Println(strings.Join(nonreg, "\n"))
		fmt.Println("\nA :git/:path (hex), replace (go), or link/git (npm) dependency bypasses release-age enforcement. " +
			"Vet it (/deps-audit), then add `<eco> <name> nonregistry <reason>` to " + allowlistPath + ".")
		return 1
	}

	var candidates []candidate
	for _, m := range manifests {
		headText, ok := readManifest(root, m.path)
		if !ok {
			continue
		}
		head, err := parseManifest(m.eco, headText)
		if err != nil {
			fmt.Fprintf(os.Stderr, "::error::dep-age-gate: %s: %v\n", m.path, err)
			return 2
		}
		base := map[string]string{}
		if baseText, ok := gitShow(root, baseRef, m.path); ok {
			if base, err = parseManifest(m.eco, baseText); err != nil {
				base = map[string]string{} // unparseable base: treat everything as added
			}
		}
		for pkg, newVer := range head {
			if base[pkg] != newVer {
				candidates = append(candidates, candidate{m.eco, pkg, base[pkg], newVer})
			}
		}
	}
	if len(candidates) == 0 {
		fmt.Printf("dep-age-gate: no dependency version changes vs %s.\n", baseRef)
		return 0
	}
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].eco+candidates[i].pkg < candidates[j].eco+candidates[j].pkg
	})

	fmt.Printf("dep-age-gate: checking %d changed dependency version(s) vs %s…\n", len(candidates), baseRef)

	ages := map[allowKey]time.Time{}
	for _, c := range candidates {
		key := allowKey{c.eco, c.pkg, c.new}
		if allowed[key] || bumpType(c.old, c.new) == "downgrade" || !ages[key].IsZero() {
			continue
		}
		pub, err := publishedAt(c.eco, c.pkg, c.new)
		if err != nil {
			// Fail closed: an unverifiable age blocks the PR.
			fmt.Printf("::error::dep-age-gate: cannot verify release age for %s %s %s: %v\n", c.eco, c.pkg, c.new, err)
			return 1
		}
		ages[key] = pub
	}

	violations := evaluate(candidates, ages, allowed, time.Now().UTC())
	if len(violations) == 0 {
		skipped := 0
		for _, c := range candidates {
			if allowed[allowKey{c.eco, c.pkg, c.new}] {
				skipped++
			}
		}
		note := ""
		if skipped > 0 {
			note = fmt.Sprintf(" (%d allow-listed)", skipped)
		}
		fmt.Printf("dep-age-gate: all changed dependencies are past their release-age window%s.\n", note)
		return 0
	}

	sort.Slice(violations, func(i, j int) bool { return violations[i].ageDays < violations[j].ageDays })
	fmt.Println("::error::dep-age-gate: unsafe dependency version change(s):")
	for _, v := range violations {
		if v.downgrade {
			fmt.Printf("  - %s %s %s: version downgrade requires an audited allowlist entry\n",
				v.eco, v.pkg, v.version)
			continue
		}
		fmt.Printf("  - %s %s %s (%s): published %s, %.1fd old, needs >= %dd\n",
			v.eco, v.pkg, v.version, v.bump, v.publishedAt.Format(time.RFC3339), v.ageDays, v.windowDays)
	}
	fmt.Println("\nWait until fresh versions clear their windows (which mirror .github/dependabot.yml cooldown). " +
		"Downgrades require explicit review. Add an audited entry to " + allowlistPath + " only when the exception is intentional.")
	return 1
}
