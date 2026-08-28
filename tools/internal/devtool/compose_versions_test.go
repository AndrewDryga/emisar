package devtool

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeComposeVersionFixtures(t *testing.T, runnerCurrent, mcpCurrent, runnerArg, mcpArg string) *App {
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
	return New(root, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{})
}

func TestCheckComposeVersionsMatchCompat(t *testing.T) {
	if err := writeComposeVersionFixtures(t, "0.19.0", "0.7.0", "0.19.0", "0.7.0").
		checkComposeVersionsMatchCompat(); err != nil {
		t.Fatal(err)
	}

	// The exact drift already in the tree: the bridge stamped at mcp_minimum
	// while the portal calls a much later release current.
	err := writeComposeVersionFixtures(t, "0.19.0", "0.7.0", "0.19.0", "0.3.0").
		checkComposeVersionsMatchCompat()
	if err == nil || !strings.Contains(err.Error(), "builds MCP_VERSION 0.3.0") {
		t.Fatalf("bridge drift not reported: %v", err)
	}

	err = writeComposeVersionFixtures(t, "0.20.0", "0.7.0", "0.19.0", "0.7.0").
		checkComposeVersionsMatchCompat()
	if err == nil || !strings.Contains(err.Error(), "builds RUNNER_VERSION 0.19.0") {
		t.Fatalf("runner drift not reported: %v", err)
	}

	// A renamed setting or build arg must fail, not silently verify nothing.
	app := writeComposeVersionFixtures(t, "0.19.0", "0.7.0", "0.19.0", "0.7.0")
	if err := os.WriteFile(filepath.Join(app.Root, "docker-compose.yml"),
		[]byte("services:\n  mcp: {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := app.checkComposeVersionsMatchCompat(); err == nil ||
		!strings.Contains(err.Error(), "does not set the RUNNER_VERSION build arg") {
		t.Fatalf("absent build arg not reported: %v", err)
	}
}
