package capture

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Four capture rigs had hand-written this parser and the copies had drifted:
// only two stripped quotes, only one rejected a malformed line, and the process
// override was split between Getenv and LookupEnv.
func TestReadEnv(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "creds.env")
	write := func(body string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	write("# a comment\n\nOKTA_TOKEN = \"secret\"\nOKTA_ORG='acme'\nPLAIN=value\n")
	env, err := ReadEnv(path)
	if err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]string{
		"OKTA_TOKEN": "secret", "OKTA_ORG": "acme", "PLAIN": "value",
	} {
		if env[key] != want {
			t.Errorf("%s = %q, want %q", key, env[key], want)
		}
	}

	// A line with no `=` is a typo in a credentials file, not something to skip.
	write("OKTA_TOKEN\n")
	if _, err := ReadEnv(path); err == nil || !strings.Contains(err.Error(), "expected KEY=VALUE") {
		t.Errorf("a malformed line was accepted: %v", err)
	}

	// An exported-but-empty value is a deliberate blank, so it overrides — the
	// difference between Getenv and LookupEnv that the rigs disagreed on.
	write("EMISAR_SCIM_TOKEN=from-file\nOTHER=from-file\n")
	t.Setenv("EMISAR_SCIM_TOKEN", "")
	t.Setenv("OTHER", "from-process")
	env, err = ReadEnv(path, "EMISAR_SCIM_TOKEN")
	if err != nil {
		t.Fatal(err)
	}
	if env["EMISAR_SCIM_TOKEN"] != "" {
		t.Errorf("an exported blank did not override: %q", env["EMISAR_SCIM_TOKEN"])
	}
	if env["OTHER"] != "from-file" {
		t.Errorf("a key not named as an override was taken from the process: %q", env["OTHER"])
	}
}
