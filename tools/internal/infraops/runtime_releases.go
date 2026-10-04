package infraops

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Production ran Erlang/OTP 29.0.6 for twelve days after 29.1.1 fixed a critical
// TLS 1.3 server-authentication bypass (CVE-2026-89422). Trivy sees the image's
// Debian packages, the Hex audits see Hex packages and govulncheck sees Go, so
// no scanner looks at the Erlang runtime, and nothing watched its pins. This
// compares .tool-versions with the builds CI installs from and fails while a
// newer release of a pinned line exists: any newer Erlang/OTP of the same major,
// any newer Elixir patch of the same minor. It needs the network, so it runs on
// a schedule and never in a gate.

const hexBuilds = "https://builds.hex.pm"

// setup-beam installs the portal job's OTP from the build list of its runner
// image (.github/workflows/ci.yml runs that job on ubuntu-24.04).
const (
	otpBuildsPath    = "/builds/otp/ubuntu-24.04/builds.txt"
	elixirBuildsPath = "/builds/elixir/builds.txt"
)

var (
	otpPinPattern      = regexp.MustCompile(`^\d+(\.\d+)*$`)
	otpBuildPattern    = regexp.MustCompile(`^OTP-(\d+(?:\.\d+)*)$`)
	elixirPinPattern   = regexp.MustCompile(`^(\d+)\.(\d+)\.(\d+)-otp-(\d+)$`)
	elixirBuildPattern = regexp.MustCompile(`^v(\d+)\.(\d+)\.(\d+)-otp-(\d+)$`)
)

// One published build: its version and when it was published.
type runtimeBuild struct {
	label    string
	version  []int
	released time.Time
}

func (a *App) checkRuntimeReleases(ctx context.Context) error {
	pins, err := readToolVersions(filepath.Join(a.Root, ".tool-versions"))
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 30 * time.Second}
	otpBuilds, err := fetchBuildList(ctx, client, a.HexBuilds+otpBuildsPath)
	if err != nil {
		return err
	}
	elixirBuilds, err := fetchBuildList(ctx, client, a.HexBuilds+elixirBuildsPath)
	if err != nil {
		return err
	}

	findings, notes, err := runtimeReleaseFindings(pins["erlang"], pins["elixir"], otpBuilds, elixirBuilds)
	if err != nil {
		return err
	}
	for _, note := range notes {
		fmt.Fprintln(a.Out, "note: "+note)
	}
	if len(findings) > 0 {
		return fmt.Errorf("a newer release of a pinned runtime exists:\n  %s\n"+
			"Move .tool-versions, portal/Dockerfile's hexpm builder and its Debian base together "+
			"(./run gate tooling checks they agree); security content: "+
			"https://github.com/erlang/otp/security/advisories", strings.Join(findings, "\n  "))
	}
	fmt.Fprintf(a.Out, "runtime pins are current: erlang %s, elixir %s\n", pins["erlang"], pins["elixir"])
	return nil
}

// runtimeReleaseFindings compares the pins with the published builds. A finding
// fails the check; a note only reports a new major or minor line, which is an
// upgrade to plan rather than a fix to take.
func runtimeReleaseFindings(erlangPin, elixirPin string, otpBuilds, elixirBuilds []string) (findings, notes []string, err error) {
	if !otpPinPattern.MatchString(erlangPin) {
		return nil, nil, fmt.Errorf(".tool-versions erlang pin %q is not a release version", erlangPin)
	}
	elixirMatch := elixirPinPattern.FindStringSubmatch(elixirPin)
	if elixirMatch == nil {
		return nil, nil, fmt.Errorf(".tool-versions elixir pin %q is not <version>-otp-<major>", elixirPin)
	}

	pinnedOTP := versionParts(erlangPin)
	var newestSameMajor, newestOverall *runtimeBuild
	for _, line := range otpBuilds {
		build, ok := parseBuild(line, otpBuildPattern, func(match []string) (string, []int) {
			return "Erlang/OTP " + match[1], versionParts(match[1])
		})
		if !ok {
			continue
		}
		if newestOverall == nil || compareVersions(build.version, newestOverall.version) > 0 {
			newestOverall = &build
		}
		if build.version[0] == pinnedOTP[0] &&
			(newestSameMajor == nil || compareVersions(build.version, newestSameMajor.version) > 0) {
			newestSameMajor = &build
		}
	}
	if newestSameMajor == nil {
		return nil, nil, fmt.Errorf("the OTP build list has no release of the pinned major %d", pinnedOTP[0])
	}
	if compareVersions(newestSameMajor.version, pinnedOTP) > 0 {
		findings = append(findings, newer(*newestSameMajor, "erlang "+erlangPin))
	}
	if newestOverall.version[0] > pinnedOTP[0] {
		notes = append(notes, newestOverall.label+" opens a new major; plan that upgrade separately")
	}

	pinnedElixir := []int{atoi(elixirMatch[1]), atoi(elixirMatch[2]), atoi(elixirMatch[3])}
	otpSuffix := elixirMatch[4]
	var newestSameMinor, newestElixir *runtimeBuild
	for _, line := range elixirBuilds {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if match := elixirBuildPattern.FindStringSubmatch(fields[0]); match == nil || match[4] != otpSuffix {
			continue
		}
		build, ok := parseBuild(line, elixirBuildPattern, func(match []string) (string, []int) {
			return fmt.Sprintf("Elixir %s.%s.%s", match[1], match[2], match[3]),
				[]int{atoi(match[1]), atoi(match[2]), atoi(match[3])}
		})
		if !ok {
			continue
		}
		if newestElixir == nil || compareVersions(build.version, newestElixir.version) > 0 {
			newestElixir = &build
		}
		if build.version[0] == pinnedElixir[0] && build.version[1] == pinnedElixir[1] &&
			(newestSameMinor == nil || compareVersions(build.version, newestSameMinor.version) > 0) {
			newestSameMinor = &build
		}
	}
	if newestSameMinor == nil {
		return nil, nil, fmt.Errorf("the Elixir build list has no %d.%d release built for OTP %s",
			pinnedElixir[0], pinnedElixir[1], otpSuffix)
	}
	if compareVersions(newestSameMinor.version, pinnedElixir) > 0 {
		findings = append(findings, newer(*newestSameMinor, "elixir "+elixirPin))
	}
	if compareVersions(newestElixir.version[:2], pinnedElixir[:2]) > 0 {
		notes = append(notes, newestElixir.label+" opens a new minor line; plan that upgrade separately")
	}
	return findings, notes, nil
}

func newer(build runtimeBuild, pinned string) string {
	return fmt.Sprintf("%s (published %s) is newer than the pinned %s",
		build.label, build.released.Format("2006-01-02"), pinned)
}

// A build list line is `<label> <commit> <published-at> <sha256>`; release
// candidates and branch builds do not match the release patterns.
func parseBuild(line string, pattern *regexp.Regexp, version func([]string) (string, []int)) (runtimeBuild, bool) {
	fields := strings.Fields(line)
	if len(fields) < 3 {
		return runtimeBuild{}, false
	}
	match := pattern.FindStringSubmatch(fields[0])
	if match == nil {
		return runtimeBuild{}, false
	}
	released, err := time.Parse(time.RFC3339, fields[2])
	if err != nil {
		return runtimeBuild{}, false
	}
	label, parts := version(match)
	return runtimeBuild{label: label, version: parts, released: released}, true
}

func fetchBuildList(ctx context.Context, client *http.Client, url string) ([]string, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("fetching %s: %w", url, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetching %s: HTTP %d", url, response.StatusCode)
	}
	var lines []string
	scanner := bufio.NewScanner(io.LimitReader(response.Body, 16<<20))
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("reading %s: %w", url, err)
	}
	return lines, nil
}

func readToolVersions(path string) (map[string]string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pins := map[string]string{}
	for _, line := range strings.Split(string(content), "\n") {
		if fields := strings.Fields(line); len(fields) >= 2 && !strings.HasPrefix(fields[0], "#") {
			pins[fields[0]] = fields[1]
		}
	}
	for _, tool := range []string{"erlang", "elixir"} {
		if pins[tool] == "" {
			return nil, fmt.Errorf("%s pins no %s version", path, tool)
		}
	}
	return pins, nil
}

// OTP releases carry two to four numbers (29.1, 29.1.1, 28.5.0.7); a missing
// trailing number is zero, so 29.1 and 29.1.0 are the same release.
func versionParts(version string) []int {
	var parts []int
	for _, part := range strings.Split(version, ".") {
		parts = append(parts, atoi(part))
	}
	return parts
}

func compareVersions(a, b []int) int {
	for i := 0; i < len(a) || i < len(b); i++ {
		var x, y int
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

func atoi(digits string) int {
	value, _ := strconv.Atoi(digits)
	return value
}
