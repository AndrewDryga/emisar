package capture

import (
	"os"
	"path/filepath"
	"runtime"
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

// The rigs write live client secrets here, so the file is owner-only even when an
// earlier run left a world-readable one at that path — O_CREATE's mode applies
// only on creation, which is what google's own writer missed.
func TestWriteCredentialFileIsOwnerOnly(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cert-client.env")
	if err := os.WriteFile(path, []byte("stale\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	const contents = "ENTRA_CLIENT_ID=11111111-2222-3333-4444-555555555555\n"
	if err := WriteCredentialFile(path, contents); err != nil {
		t.Fatalf("write credential file: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != contents {
		t.Fatalf("credential file = %q, want %q", data, contents)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("mode = %o, want 0600", info.Mode().Perm())
		}
	}
}
