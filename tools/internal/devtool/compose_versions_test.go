package devtool

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The fixture root is a real git repository so the release-tag comparison runs
// against exactly the tags each case creates; a case that creates none
// exercises the "skipped" path.
func writeComposeVersionFixtures(t *testing.T, runnerCurrent, mcpCurrent, runnerArg, mcpArg string, tags ...string) *App {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "portal", "config"), 0o755); err != nil {
		t.Fatal(err)
	}
	config := "config :emisar, Emisar.Compat,\n  runner_minimum: \">= 0.10.0\",\n" +
		"  runner_current: \"" + runnerCurrent + "\",\n  mcp_minimum: \">= 0.3.0\",\n" +
		"  mcp_current: \"" + mcpCurrent + "\"\n"
	if err := os.WriteFile(filepath.Join(root, "portal", "config", "config.exs"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	compose := "services:\n  runner-1:\n    build:\n      args:\n        RUNNER_VERSION: \"" + runnerArg + "\"\n" +
		"  mcp:\n    build:\n      args:\n        MCP_VERSION: \"" + mcpArg + "\"\n"
	if err := os.WriteFile(filepath.Join(root, "docker-compose.yml"), []byte(compose), 0o600); err != nil {
		t.Fatal(err)
	}
	commands := [][]string{
		{"init", "-q"},
		{"config", "user.email", "test@example.com"},
		{"config", "user.name", "Test"},
		{"config", "commit.gpgsign", "false"},
		{"config", "tag.gpgsign", "false"},
		{"add", "."},
		{"commit", "-q", "-m", "fixture"},
	}
	for _, tag := range tags {
		commands = append(commands, []string{"tag", tag})
	}
	for _, args := range commands {
		command := exec.Command("git", args...)
		command.Dir = root
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, output)
		}
	}
	return New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
}

func TestCheckComposeVersionsMatchCompat(t *testing.T) {
	ctx := context.Background()
	if err := writeComposeVersionFixtures(t, "0.19.0", "0.7.0", "0.19.0", "0.7.0").
		checkComposeVersionsMatchCompat(ctx); err != nil {
		t.Fatal(err)
	}

	// The exact drift already in the tree: the bridge stamped at mcp_minimum
	// while the portal calls a much later release current.
	err := writeComposeVersionFixtures(t, "0.19.0", "0.7.0", "0.19.0", "0.3.0").
		checkComposeVersionsMatchCompat(ctx)
	if err == nil || !strings.Contains(err.Error(), "builds MCP_VERSION 0.3.0") {
		t.Fatalf("bridge drift not reported: %v", err)
	}

	err = writeComposeVersionFixtures(t, "0.20.0", "0.7.0", "0.19.0", "0.7.0").
		checkComposeVersionsMatchCompat(ctx)
	if err == nil || !strings.Contains(err.Error(), "builds RUNNER_VERSION 0.19.0") {
		t.Fatalf("runner drift not reported: %v", err)
	}

	// A renamed setting or build arg must fail, not silently verify nothing.
	app := writeComposeVersionFixtures(t, "0.19.0", "0.7.0", "0.19.0", "0.7.0")
	if err := os.WriteFile(filepath.Join(app.Root, "docker-compose.yml"),
		[]byte("services:\n  mcp: {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := app.checkComposeVersionsMatchCompat(ctx); err == nil ||
		!strings.Contains(err.Error(), "does not set the RUNNER_VERSION build arg") {
		t.Fatalf("absent build arg not reported: %v", err)
	}
}

func TestCheckComposeVersionsMatchCompatAgainstReleaseTags(t *testing.T) {
	ctx := context.Background()

	// Config and compose agree with each other and with the newest tags.
	app := writeComposeVersionFixtures(t, "0.27.0", "0.14.0", "0.27.0", "0.14.0",
		"runner-v0.26.0", "runner-v0.27.0", "mcp-v0.14.0", "v0.48.0")
	if err := app.checkComposeVersionsMatchCompat(ctx); err != nil {
		t.Fatal(err)
	}

	// The drift this check was added for: config and compose agree, but both
	// sit three runner releases behind the tags.
	err := writeComposeVersionFixtures(t, "0.24.0", "0.14.0", "0.24.0", "0.14.0",
		"runner-v0.25.0", "runner-v0.26.0", "runner-v0.27.0", "mcp-v0.14.0").
		checkComposeVersionsMatchCompat(ctx)
	if err == nil || !strings.Contains(err.Error(), "runner_current is 0.24.0, but runner-v0.27.0 is the newest release tag") {
		t.Fatalf("stale runner_current not reported: %v", err)
	}

	err = writeComposeVersionFixtures(t, "0.27.0", "0.13.0", "0.27.0", "0.13.0",
		"runner-v0.27.0", "mcp-v0.13.0", "mcp-v0.14.0").
		checkComposeVersionsMatchCompat(ctx)
	if err == nil || !strings.Contains(err.Error(), "mcp_current is 0.13.0, but mcp-v0.14.0 is the newest release tag") {
		t.Fatalf("stale mcp_current not reported: %v", err)
	}

	// Config ahead of the tags is the commit that precedes cutting the tag,
	// not drift; numeric comparison, not lexical, so 0.10.0 beats 0.9.0.
	if err := writeComposeVersionFixtures(t, "0.10.0", "0.14.0", "0.10.0", "0.14.0",
		"runner-v0.9.0", "mcp-v0.14.0").checkComposeVersionsMatchCompat(ctx); err != nil {
		t.Fatal(err)
	}

	// No tags at all (a shallow clone) skips the comparison and says so.
	app = writeComposeVersionFixtures(t, "0.27.0", "0.14.0", "0.27.0", "0.14.0")
	if err := app.checkComposeVersionsMatchCompat(ctx); err != nil {
		t.Fatal(err)
	}
	if out := app.Out.(*bytes.Buffer).String(); !strings.Contains(out, "skipped: no runner-v* tags") ||
		!strings.Contains(out, "skipped: no mcp-v* tags") {
		t.Fatalf("missing tags were not reported as skipped: %q", out)
	}
}

func TestReleaseVersionNewer(t *testing.T) {
	for _, tc := range []struct {
		a, b string
		want bool
	}{
		{"0.27.0", "0.24.0", true},
		{"0.24.0", "0.27.0", false},
		{"0.27.0", "0.27.0", false},
		{"0.10.0", "0.9.0", true},
		{"1.0.0", "0.99.99", true},
		{"0.27.0-rc1", "0.24.0", false},
		{"0.27", "0.24.0", false},
		{"0.27.0", "garbage", false},
	} {
		if got := releaseVersionNewer(tc.a, tc.b); got != tc.want {
			t.Errorf("releaseVersionNewer(%q, %q) = %v, want %v", tc.a, tc.b, got, tc.want)
		}
	}
}
