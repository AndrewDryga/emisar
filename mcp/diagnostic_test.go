package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestCLIDiagnosticPlainTextExplainsCauseAndRecovery(t *testing.T) {
	got := formatCLIDiagnostic(cliDiagnostic{
		Kind:    cliDiagnosticError,
		Summary: "Browser sign-in is not available",
		Details: []string{"The server at https://emisar.dev does not support it yet."},
		Next: []string{
			"Upgrade the Emisar server, then run `emisar-mcp auth` again.",
			"Until then, set EMISAR_URL and EMISAR_API_KEY together.",
		},
	}, false)
	want := "Error: Browser sign-in is not available\n\n" +
		"The server at https://emisar.dev does not support it yet.\n\n" +
		"Next:\n" +
		"  - Upgrade the Emisar server, then run `emisar-mcp auth` again.\n" +
		"  - Until then, set EMISAR_URL and EMISAR_API_KEY together.\n"
	if got != want {
		t.Fatalf("diagnostic:\n%s\nwant:\n%s", got, want)
	}
}

func TestCLIDiagnosticLeavesLineWrappingToTheTerminal(t *testing.T) {
	got := formatCLIDiagnostic(cliDiagnostic{
		Kind:    cliDiagnosticWarning,
		Summary: "Previous credential replaced",
		Next: []string{
			"Revoke the previous key at https://example.test/app/agents if it is still connected.",
		},
	}, false)
	want := "Warning: Previous credential replaced\n\nNext:\n" +
		"  - Revoke the previous key at https://example.test/app/agents if it is still connected.\n"
	if got != want {
		t.Fatalf("diagnostic inserted a display-width newline:\n%s", got)
	}
}

func TestCLIStyledTextColorsOnlyWhenEnabled(t *testing.T) {
	if got := formatCLIStyledText("1;36", "KHT3-CZXH", false); got != "KHT3-CZXH" {
		t.Fatalf("plain text = %q", got)
	}
	tests := []struct {
		name  string
		style string
		value string
		want  string
	}{
		{"colored status", "1;32", "✓ Authenticated", "\x1b[1;32m✓ Authenticated\x1b[0m"},
		{"bold identity", "1", "Northstar Labs (demo)", "\x1b[1mNorthstar Labs (demo)\x1b[0m"},
		{"underlined URL", "4", "https://emisar.dev", "\x1b[4mhttps://emisar.dev\x1b[0m"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := formatCLIStyledText(test.style, test.value, true); got != test.want {
				t.Fatalf("styled text = %q, want %q", got, test.want)
			}
		})
	}
}

func TestCLIDiagnosticColorIsLabelOnlyAndHostileTextIsSafe(t *testing.T) {
	got := formatCLIDiagnostic(cliDiagnostic{
		Kind:    cliDiagnosticError,
		Summary: "failed\x1b[31m\u202esecret",
		Details: []string{"detail\rnext"},
	}, true)
	if !strings.HasPrefix(got, "\x1b[1;31mError\x1b[0m: failed [31m secret\n") {
		t.Fatalf("colored diagnostic = %q", got)
	}
	if strings.Count(got, "\x1b[") != 2 || strings.Contains(got, "\u202e") || strings.Contains(got, "\r") {
		t.Fatalf("hostile controls survived diagnostic = %q", got)
	}
}

func TestCLIDiagnosticUsageKeepsCommandsOnSeparateLines(t *testing.T) {
	var stderr bytes.Buffer
	code := cliUsageBlock(&stderr, "Invalid auth command", authUsageText)
	if code != 2 || !strings.Contains(stderr.String(), "Usage:\n  emisar-mcp auth [login [URL]]\n") ||
		strings.Contains(stderr.String(), "emisar-mcp:") {
		t.Fatalf("exit=%d diagnostic=%q", code, stderr.String())
	}
}

func TestCLIDiagnosticDisablesColorForPipes(t *testing.T) {
	var stderr bytes.Buffer
	if cliDiagnosticColorEnabled(&stderr) {
		t.Fatal("buffer output must not contain terminal color")
	}
}

func TestCLIDiagnosticColorPolicy(t *testing.T) {
	tests := []struct {
		name     string
		terminal bool
		goos     string
		term     string
		noColor  bool
		cliColor string
		want     bool
	}{
		{name: "terminal", terminal: true, goos: "darwin", term: "xterm-256color", want: true},
		{name: "pipe", goos: "darwin", term: "xterm-256color"},
		{name: "no color", terminal: true, goos: "darwin", term: "xterm-256color", noColor: true},
		{name: "cli color zero", terminal: true, goos: "linux", term: "xterm", cliColor: "0"},
		{name: "dumb terminal", terminal: true, goos: "linux", term: "dumb"},
		{name: "windows", terminal: true, goos: "windows", term: "xterm"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := cliDiagnosticColorAllowed(
				test.terminal,
				test.goos,
				test.term,
				test.noColor,
				test.cliColor,
			); got != test.want {
				t.Fatalf("color allowed = %t, want %t", got, test.want)
			}
		})
	}
}

func TestCLIConfigurationFailuresGiveSpecificRecovery(t *testing.T) {
	tests := []struct {
		name    string
		err     string
		account string
		want    []string
	}{
		{
			name: "missing account",
			err:  "no stored CLI credential for this account",
			want: []string{"No stored account is available", "emisar-mcp auth", "accounts list"},
		},
		{
			name: "partial environment",
			err:  "EMISAR_API_KEY must be set (try --help)",
			want: []string{"Authentication environment is incomplete", "Set both EMISAR_URL and EMISAR_API_KEY"},
		},
		{
			name: "invalid endpoint",
			err:  "EMISAR_URL must not contain user information",
			want: []string{"EMISAR_URL is invalid", "without a path", "credentials"},
		},
		{
			name: "signing",
			err:  "both EMISAR_SIGNING_KEY and EMISAR_SIGNING_CERT must be set",
			want: []string{"Signing configuration is invalid", "unset both", "disable signed dispatch"},
		},
		{
			name: "metadata",
			err:  "EMISAR_CLIENT_METADATA must be a JSON object",
			want: []string{"EMISAR_CLIENT_METADATA is invalid", "Fix the JSON object"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var stderr bytes.Buffer
			if code := cliConfigurationFailure(&stderr, errors.New(test.err), test.account); code != 1 {
				t.Fatalf("exit = %d", code)
			}
			for _, want := range test.want {
				if !strings.Contains(stderr.String(), want) {
					t.Errorf("diagnostic missing %q:\n%s", want, stderr.String())
				}
			}
			if strings.Contains(stderr.String(), "emisar-mcp:") || strings.Contains(stderr.String(), "\x1b[") {
				t.Fatalf("captured diagnostic contains a prefix or color: %q", stderr.String())
			}
		})
	}
}
