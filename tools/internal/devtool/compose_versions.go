package devtool

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// The e2e stack exists to demonstrate the coordinated release the portal calls
// current, and it stamps those versions into the runner and bridge binaries by
// hand. Nothing tied the two, and the bridge had already drifted four minors
// behind — pinned at mcp_minimum, so the stack demonstrated the oldest build
// still accepted rather than the one customers get, and a minimum bump would
// have made it non-compliant with no test noticing.
//
// The same check now also compares each `*_current` with the newest matching
// release tag in the clone. Compose and config agreeing proves nothing when
// both are behind: the portal shipped three runner releases while still telling
// operators 0.24.0 was current. A clone with no release tags (a shallow
// checkout) reports the comparison as skipped rather than silently passing.
func (a *App) checkComposeVersionsMatchCompat(ctx context.Context) error {
	config, err := os.ReadFile(filepath.Join(a.Root, "portal", "config", "config.exs"))
	if err != nil {
		return err
	}
	compose, err := os.ReadFile(filepath.Join(a.Root, "docker-compose.yml"))
	if err != nil {
		return err
	}
	for _, component := range []struct{ setting, buildArg, tagPrefix string }{
		{"runner_current", "RUNNER_VERSION", "runner-v"},
		{"mcp_current", "MCP_VERSION", "mcp-v"},
	} {
		want := firstSubmatch(config, `(?m)^\s*`+component.setting+`:\s*"([^"]+)"`)
		if want == "" {
			return fmt.Errorf("portal/config/config.exs does not set %s", component.setting)
		}
		got := firstSubmatch(compose, `(?m)^\s*`+component.buildArg+`:\s*"([^"]+)"`)
		if got == "" {
			return fmt.Errorf("docker-compose.yml does not set the %s build arg", component.buildArg)
		}
		if got != want {
			return fmt.Errorf("docker-compose.yml builds %s %s, but the portal's %s is %s; "+
				"the stack must run the coordinated release it demonstrates", component.buildArg, got, component.setting, want)
		}
		newest, err := a.newestReleaseTag(ctx, component.tagPrefix)
		if err != nil {
			return err
		}
		if newest == "" {
			fmt.Fprintf(a.Out, "skipped: no %s* tags in this clone, so %s cannot be compared with the newest release\n",
				component.tagPrefix, component.setting)
			continue
		}
		if releaseVersionNewer(newest, want) {
			return fmt.Errorf("the portal's %s is %s, but %s%s is the newest release tag; "+
				"bump the Emisar.Compat thresholds and the %s build arg when a component tag ships",
				component.setting, want, component.tagPrefix, newest, component.buildArg)
		}
	}
	fmt.Fprintln(a.Out, "verified: the e2e stack builds the runner and bridge versions Emisar.Compat calls current, and no newer release tag exists")
	return nil
}

// newestReleaseTag returns the highest X.Y.Z among the clone's `<prefix>X.Y.Z`
// tags, or "" when the clone has none. Tags with any other shape are ignored:
// release tags are cut by hand from the release runbook and never carry a
// prerelease or build suffix.
func (a *App) newestReleaseTag(ctx context.Context, prefix string) (string, error) {
	output, err := a.output(ctx, a.Root, nil, "git", "tag", "-l", prefix+"*")
	if err != nil {
		return "", fmt.Errorf("listing %s* release tags: %w", prefix, err)
	}
	newest := ""
	for _, tag := range strings.Fields(string(output)) {
		version := strings.TrimPrefix(tag, prefix)
		if _, ok := parseReleaseVersion(version); !ok {
			continue
		}
		if newest == "" || releaseVersionNewer(version, newest) {
			newest = version
		}
	}
	return newest, nil
}

// parseReleaseVersion reads a plain X.Y.Z release version. Anything else —
// a missing component, a prerelease suffix, a negative number — is not a
// release version and returns ok=false.
func parseReleaseVersion(version string) ([3]int, bool) {
	var parsed [3]int
	parts := strings.Split(version, ".")
	if len(parts) != 3 {
		return parsed, false
	}
	for i, part := range parts {
		n, err := strconv.Atoi(part)
		if err != nil || n < 0 {
			return parsed, false
		}
		parsed[i] = n
	}
	return parsed, true
}

// releaseVersionNewer reports whether release version a is strictly newer
// than b. A version that does not parse is never newer.
func releaseVersionNewer(a, b string) bool {
	left, ok := parseReleaseVersion(a)
	if !ok {
		return false
	}
	right, ok := parseReleaseVersion(b)
	if !ok {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return left[i] > right[i]
		}
	}
	return false
}

func firstSubmatch(data []byte, pattern string) string {
	match := regexp.MustCompile(pattern).FindSubmatch(data)
	if match == nil {
		return ""
	}
	return string(match[1])
}
