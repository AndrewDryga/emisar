package devtool

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// install.sh and install-mcp.sh are two `curl | bash` artifacts that must stay
// single-file, so they cannot source one library — and they share about
// twenty helper functions that must behave identically: the release-mirror
// lookup, immutable-release refusal, checksum attestation, the consent
// prompt. A founder decision about verifier behaviour has had to be applied to
// every installer at once, and nothing noticed when one copy drifted in style
// or, once, in where a log line went. This check extracts every function both
// scripts define, replaces the product nouns with one token, folds whitespace,
// and fails on any remaining difference outside the small set that is
// genuinely component-specific.
var installerScripts = [2]string{"install.sh", "install-mcp.sh"}

// The helpers both installers define today. The comparison below is only as
// wide as what installerFunctions extracts, so a style drift that hides a
// helper from it — `function name {`, or a body whose closing brace is
// indented — would quietly shrink the compared set and let a copy drift
// unnoticed. Pinning the set turns that into a failure. Adding or retiring a
// shared helper is a deliberate edit to this list.
var installerSharedFunctions = []string{
	"accept_missing_verifier",
	"confirm",
	"die",
	"do_uninstall",
	"fetch_release_files",
	"github_api",
	"github_release_base",
	"log",
	"mirror_release_base",
	"normalize_version",
	"release_manifest_tag",
	"require_immutable_release",
	"require_value",
	"resolve_latest_from_github",
	"resolve_latest_version",
	"select_attestation_policy",
	"truthy",
	"tty_available",
	"usage",
	"verify_checksum_attestation",
	"warn",
}

// Functions the two installers implement differently on purpose.
var installerDivergentFunctions = map[string]string{
	"usage":                      "each installer documents its own flags",
	"do_uninstall":               "the runner removes a service, packs, and state; the bridge removes a binary and client config",
	"fetch_release_files":        "the bridge downloads its own archive name from an env-selected platform",
	"resolve_latest_from_github": "the runner dies on API failure; the bridge returns so its caller can fall back",
}

var installerNounRewrites = []struct {
	pattern *regexp.Regexp
	replace string
}{
	{regexp.MustCompile(`runner-release-trusted|mcp-release-trusted`), "X-release-trusted"},
	{regexp.MustCompile(`\[install-mcp\]`), "[install]"},
	{regexp.MustCompile(`SHA256SUMS-MCP`), "SHA256SUMS"},
	{regexp.MustCompile(`emisar-mcp`), "emisar-X"},
	{regexp.MustCompile(`runner-v|mcp-v`), "X-v"},
	{regexp.MustCompile(`\bMCP bridge\b|\bMCP\b|\bmcp\b|\bRunner\b|\brunner\b`), "X"},
}

var installerFunctionStart = regexp.MustCompile(`^([a-z_][a-z0-9_]*)\(\)\s*\{`)

// installerFunctions maps each function name in a bash script to its body,
// covering both the multi-line `name() {` … `}` form and the one-line
// `name() { …; }` form the log helpers use.
func installerFunctions(script string) map[string]string {
	functions := map[string]string{}
	lines := strings.Split(script, "\n")
	for i := 0; i < len(lines); i++ {
		match := installerFunctionStart.FindStringSubmatch(lines[i])
		if match == nil {
			continue
		}
		name := match[1]
		if strings.HasSuffix(strings.TrimSpace(lines[i]), "}") && strings.Count(lines[i], "{") == strings.Count(lines[i], "}") {
			functions[name] = lines[i]
			continue
		}
		var body []string
		for i++; i < len(lines); i++ {
			body = append(body, lines[i])
			if lines[i] == "}" {
				break
			}
		}
		functions[name] = strings.Join(body, "\n")
	}
	return functions
}

func normalizeInstallerFunction(body string) string {
	for _, rewrite := range installerNounRewrites {
		body = rewrite.pattern.ReplaceAllString(body, rewrite.replace)
	}
	var lines []string
	for _, line := range strings.Split(body, "\n") {
		lines = append(lines, strings.Join(strings.Fields(line), " "))
	}
	return strings.Join(lines, "\n")
}

func (a *App) checkInstallerSharedFunctions() error {
	scripts := [2]map[string]string{}
	for i, name := range installerScripts {
		data, err := os.ReadFile(filepath.Join(a.Root, name))
		if err != nil {
			return err
		}
		scripts[i] = installerFunctions(string(data))
	}
	var shared, problems []string
	for name := range scripts[0] {
		if _, ok := scripts[1][name]; ok {
			shared = append(shared, name)
		}
	}
	sort.Strings(shared)
	pinned := map[string]bool{}
	for _, name := range installerSharedFunctions {
		pinned[name] = true
	}
	for _, name := range shared {
		if !pinned[name] {
			problems = append(problems, name+" (shared by both installers but missing from installerSharedFunctions)")
		}
		delete(pinned, name)
		if _, ok := installerDivergentFunctions[name]; ok {
			continue
		}
		if normalizeInstallerFunction(scripts[0][name]) != normalizeInstallerFunction(scripts[1][name]) {
			problems = append(problems, name+" (bodies differ beyond the product noun)")
		}
	}
	for name := range pinned {
		problems = append(problems, name+" (pinned as shared but no longer extracted from both installers; a `function name {` header or an indented closing brace hides a helper from the comparison)")
	}
	for name := range installerDivergentFunctions {
		if _, ok := scripts[0][name]; !ok {
			problems = append(problems, name+" (listed as divergent but no longer defined in both installers)")
		} else if _, ok := scripts[1][name]; !ok {
			problems = append(problems, name+" (listed as divergent but no longer defined in both installers)")
		}
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		return fmt.Errorf("install.sh and install-mcp.sh no longer share the helpers they are pinned to share, or share one they implement differently beyond the product noun; make the bodies identical, or record the change in installerSharedFunctions and installerDivergentFunctions:\n  %s",
			strings.Join(problems, "\n  "))
	}
	fmt.Fprintf(a.Out, "verified: %d helpers shared by install.sh and install-mcp.sh agree (%d recorded as divergent on purpose)\n",
		len(shared)-len(installerDivergentFunctions), len(installerDivergentFunctions))
	return nil
}
