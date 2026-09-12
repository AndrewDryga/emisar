package devtool

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeInstallerFixtures(t *testing.T, runner, mcp string) *App {
	t.Helper()
	root := t.TempDir()
	for name, body := range map[string]string{"install.sh": runner, "install-mcp.sh": mcp} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
}

func installerStub(name string) string {
	return name + "() { echo " + name + "; }\n"
}

// The check compares a pinned set of helpers, so a fixture has to define all of
// them: the ones a case is actually about, plus an identical stub for the rest.
func installerFixture(defined string) string {
	fixture := defined
	for _, name := range installerSharedFunctions {
		if !strings.Contains(defined, name+"()") {
			fixture += installerStub(name)
		}
	}
	return fixture
}

func TestInstallerSharedFunctionsAgreeUpToTheProductNoun(t *testing.T) {
	runner := installerFixture(`log()   { printf '[install] %s\n' "$*" >&2; }
normalize_version() {
  case "$1" in
    runner-v*) printf '%s\n' "$1";;
    *)         printf 'runner-v%s\n' "$1";;
  esac
}
require_immutable_release() {
  die "install the latest immutable runner release"
}
`)
	mcp := installerFixture(`log()  { printf '[install-mcp] %s\n' "$*" >&2; }
normalize_version() {
  case "$1" in
    mcp-v*) printf '%s\n' "$1";;
    *)      printf 'mcp-v%s\n' "$1";;
  esac
}
require_immutable_release() {
  die "install the latest immutable MCP release"
}
`)
	app := writeInstallerFixtures(t, runner, mcp)
	if err := app.checkInstallerSharedFunctions(); err != nil {
		t.Fatal(err)
	}
	if out := app.Out.(*bytes.Buffer).String(); !strings.Contains(out, "17 helpers shared") {
		t.Fatalf("unexpected report: %q", out)
	}

	// The drift this check was written for: same helper, a different shape.
	drifted := strings.Replace(mcp, "  die \"install the latest immutable MCP release\"\n",
		"  [ -n \"$1\" ] || die \"install the latest immutable MCP release\"\n", 1)
	err := writeInstallerFixtures(t, runner, drifted).checkInstallerSharedFunctions()
	if err == nil || !strings.Contains(err.Error(), "require_immutable_release") {
		t.Fatalf("drift not reported: %v", err)
	}

	// A log helper that changes which stream it writes to is drift too.
	stdout := strings.Replace(mcp, `"$*" >&2; }`, `"$*"; }`, 1)
	err = writeInstallerFixtures(t, runner, stdout).checkInstallerSharedFunctions()
	if err == nil || !strings.Contains(err.Error(), "log") {
		t.Fatalf("stream drift not reported: %v", err)
	}

	// A divergent entry that no longer names a shared function is stale.
	err = writeInstallerFixtures(t, strings.Replace(runner, installerStub("usage"), "", 1), mcp).checkInstallerSharedFunctions()
	if err == nil || !strings.Contains(err.Error(), "usage (listed as divergent") {
		t.Fatalf("stale allowlist entry not reported: %v", err)
	}

	// The silent failure the pinned set exists for: a helper written in a shape
	// installerFunctions does not extract drops out of the comparison instead of
	// being compared and found drifted.
	hidden := strings.Replace(runner, "truthy() {", "function truthy {", 1)
	err = writeInstallerFixtures(t, hidden, mcp).checkInstallerSharedFunctions()
	if err == nil || !strings.Contains(err.Error(), "truthy (pinned as shared") {
		t.Fatalf("helper dropping out of the comparison not reported: %v", err)
	}

	// A new helper both installers grew belongs in the pinned set.
	added := installerStub("resolve_mirror")
	err = writeInstallerFixtures(t, runner+added, mcp+added).checkInstallerSharedFunctions()
	if err == nil || !strings.Contains(err.Error(), "resolve_mirror (shared by both installers but missing") {
		t.Fatalf("unpinned shared helper not reported: %v", err)
	}
}
