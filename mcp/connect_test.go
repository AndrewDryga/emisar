package main

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseConnectArgs(t *testing.T) {
	cases := []struct {
		name       string
		args       []string
		disconnect bool
		wantErr    bool
		check      func(*testing.T, parsedConnectArgs)
	}{
		{
			name: "no arguments",
			args: nil,
		},
		{
			name: "client selection",
			args: []string{"--client", "cursor", "--client", "zed"},
			check: func(t *testing.T, parsed parsedConnectArgs) {
				if len(parsed.clientIDs) != 2 {
					t.Errorf("clientIDs = %v", parsed.clientIDs)
				}
			},
		},
		{
			name: "url and auto permit",
			args: []string{"--url", "https://portal.example", "--auto-permit"},
			check: func(t *testing.T, parsed parsedConnectArgs) {
				if parsed.origin != "https://portal.example" || !parsed.autoPermit {
					t.Errorf("parsed = %+v", parsed.connectOptions)
				}
			},
		},
		{name: "unknown client", args: []string{"--client", "notepad"}, wantErr: true},
		{name: "client without a value", args: []string{"--client"}, wantErr: true},
		{name: "url without a value", args: []string{"--url"}, wantErr: true},
		{name: "all with client", args: []string{"--all", "--client", "cursor"}, wantErr: true},
		{name: "unknown option", args: []string{"--everything"}, wantErr: true},
		{name: "forget is disconnect only", args: []string{"--forget"}, wantErr: true},
		{name: "auto-permit is connect only", args: []string{"--auto-permit"}, disconnect: true, wantErr: true},
		{name: "url is connect only", args: []string{"--url", "https://x"}, disconnect: true, wantErr: true},
		{
			name:       "forget on disconnect",
			args:       []string{"--all", "--forget"},
			disconnect: true,
			check: func(t *testing.T, parsed parsedConnectArgs) {
				if !parsed.forget || !parsed.all {
					t.Errorf("parsed = %+v", parsed.connectOptions)
				}
			},
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			parsed, err := parseConnectArgs(testCase.args, testCase.disconnect)
			if testCase.wantErr {
				if err == nil {
					t.Fatal("expected an error")
				}
				return
			}
			if err != nil {
				t.Fatalf("parseConnectArgs: %v", err)
			}
			if testCase.check != nil {
				testCase.check(t, parsed)
			}
		})
	}
}

func TestSelectClientsWithoutATerminal(t *testing.T) {
	roots := testConfigRoots(t)
	cursor, _ := lookupClientAdapter("cursor")
	zed, _ := lookupClientAdapter("zed")
	clients := []detectedClient{cursor.resolve(roots), zed.resolve(roots)}
	clients[1].Connected = true

	t.Run("all skips a connected client", func(t *testing.T) {
		selection, ok := selectClients(connectOptions{all: true}, clients, false, strings.NewReader(""), &bytes.Buffer{})
		if !ok || len(selection.clients) != 1 || selection.clients[0].ID != "cursor" {
			t.Fatalf("selection = %+v ok=%v", selection.clients, ok)
		}
	})

	t.Run("explicit client wins over connected state", func(t *testing.T) {
		options := connectOptions{clientIDs: []string{"zed"}}
		selection, ok := selectClients(options, clients, false, strings.NewReader(""), &bytes.Buffer{})
		if !ok || len(selection.clients) != 1 || selection.clients[0].ID != "zed" {
			t.Fatalf("selection = %+v ok=%v", selection.clients, ok)
		}
	})

	t.Run("no terminal and no flags connects nothing", func(t *testing.T) {
		stdout := &bytes.Buffer{}
		selection, ok := selectClients(connectOptions{}, clients, false, strings.NewReader(""), stdout)
		if ok || len(selection.clients) != 0 {
			t.Fatalf("selection = %+v ok=%v", selection.clients, ok)
		}
		if !strings.Contains(stdout.String(), "--client") {
			t.Errorf("the operator was not told how to proceed:\n%s", stdout)
		}
	})

	t.Run("no terminal still authenticates the CLI", func(t *testing.T) {
		selection, ok := selectClients(connectOptions{}, clients, true, strings.NewReader(""), &bytes.Buffer{})
		if !ok || !selection.cliNeeded || len(selection.clients) != 0 {
			t.Fatalf("selection = %+v ok=%v", selection, ok)
		}
	})
}

func TestAskYesNoDefaultsToNo(t *testing.T) {
	cases := map[string]bool{
		"y\n":    true,
		"Y\n":    true,
		"yes\n":  true,
		"YES\n":  true,
		"n\n":    false,
		"\n":     false,
		"":       false,
		"sure\n": false,
	}
	for answer, want := range cases {
		reader := bufio.NewReader(strings.NewReader(answer))
		if got := askYesNo(reader, &bytes.Buffer{}, "Add emisar?"); got != want {
			t.Errorf("askYesNo(%q) = %v, want %v", answer, got, want)
		}
	}
}

func TestAutoPermitLandsInsideTheEntry(t *testing.T) {
	cases := []struct {
		id       string
		expected string
		marker   string
	}{
		{id: "gemini", expected: `"trust": true`, marker: "trust"},
		{id: "codex", expected: `default_tools_approval_mode = "approve"`, marker: "approval_mode"},
	}
	for _, testCase := range cases {
		t.Run(testCase.id, func(t *testing.T) {
			adapter, _ := lookupClientAdapter(testCase.id)
			roots := testConfigRoots(t)
			client := adapter.resolve(roots)
			request := testEntryRequest("/usr/local/bin/emisar-mcp", testCase.id)
			request.AutoPermit = true
			if err := client.install(request); err != nil {
				t.Fatalf("install: %v", err)
			}
			raw, err := readConfigFile(client.ConfigFile)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(raw, testCase.expected) {
				t.Errorf("auto-permit missing %q:\n%s", testCase.expected, raw)
			}
			// It rides inside the block this run wrote, so removing the entry
			// removes the setting with it.
			if err := client.remove(); err != nil {
				t.Fatalf("remove: %v", err)
			}
			after, err := readConfigFile(client.ConfigFile)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(after, testCase.marker) {
				t.Errorf("the auto-permit setting survived removal:\n%s", after)
			}
		})
	}
}

func TestAutoPermitWithoutOptInWritesNothingExtra(t *testing.T) {
	adapter, _ := lookupClientAdapter("gemini")
	roots := testConfigRoots(t)
	client := adapter.resolve(roots)
	if err := client.install(testEntryRequest("/usr/local/bin/emisar-mcp", "gemini")); err != nil {
		t.Fatalf("install: %v", err)
	}
	raw, err := readConfigFile(client.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(raw, "trust") {
		t.Errorf("trust was written without an opt-in:\n%s", raw)
	}
}

func TestClaudeCodePermissionEditKeepsOtherRules(t *testing.T) {
	roots := testConfigRoots(t)
	settings := filepath.Join(roots.home, ".claude", "settings.json")
	if err := os.MkdirAll(filepath.Dir(settings), 0o700); err != nil {
		t.Fatal(err)
	}
	existing := "{\n  \"model\": \"opus\",\n  \"permissions\": {\n    \"allow\": [\"Bash(ls:*)\"],\n    \"deny\": []\n  }\n}\n"
	if err := os.WriteFile(settings, []byte(existing), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := editClaudePermission(settings, true); err != nil {
		t.Fatalf("add: %v", err)
	}
	raw, err := readConfigFile(settings)
	if err != nil {
		t.Fatal(err)
	}
	for _, kept := range []string{"\"model\": \"opus\"", "Bash(ls:*)", "\"deny\""} {
		if !strings.Contains(raw, kept) {
			t.Errorf("edit dropped %q:\n%s", kept, raw)
		}
	}
	if !strings.Contains(raw, claudeToolPattern) {
		t.Errorf("the emisar rule was not added:\n%s", raw)
	}

	if err := editClaudePermission(settings, false); err != nil {
		t.Fatalf("remove: %v", err)
	}
	after, err := readConfigFile(settings)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(after, claudeToolPattern) {
		t.Errorf("the emisar rule survived:\n%s", after)
	}
	if !strings.Contains(after, "Bash(ls:*)") {
		t.Errorf("removal dropped another rule:\n%s", after)
	}
}

func TestClaudeCodePermissionEditIsIdempotent(t *testing.T) {
	roots := testConfigRoots(t)
	settings := filepath.Join(roots.home, ".claude", "settings.json")
	for range 2 {
		if err := editClaudePermission(settings, true); err != nil {
			t.Fatalf("add: %v", err)
		}
	}
	raw, err := readConfigFile(settings)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(raw, claudeToolPattern) != 1 {
		t.Errorf("the rule was added twice:\n%s", raw)
	}
}

func TestClaudeCodePermissionRemovalWithoutASettingsFile(t *testing.T) {
	roots := testConfigRoots(t)
	settings := filepath.Join(roots.home, ".claude", "settings.json")
	if err := editClaudePermission(settings, false); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if _, err := os.Stat(settings); !os.IsNotExist(err) {
		t.Errorf("removal created a settings file: %v", err)
	}
}

func TestGrokPermissionOnlyRemovesOurOwnTable(t *testing.T) {
	roots := testConfigRoots(t)
	adapter, _ := lookupClientAdapter("grok")
	client := adapter.resolve(roots)
	if err := os.MkdirAll(filepath.Dir(client.ConfigFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(client.ConfigFile, []byte("default_model = \"grok-4\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := addGrokPermission(client.ConfigFile); err != nil {
		t.Fatalf("add: %v", err)
	}
	raw, err := readConfigFile(client.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(raw, grokToolPermission) {
		t.Fatalf("the permission was not added:\n%s", raw)
	}
	if err := removeGrokPermission(client.ConfigFile); err != nil {
		t.Fatalf("remove: %v", err)
	}
	after, err := readConfigFile(client.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(after, "[permission]") || strings.Contains(after, grokToolPermission) {
		t.Errorf("our table survived:\n%s", after)
	}
	if !strings.Contains(after, "default_model") {
		t.Errorf("removal dropped an unrelated key:\n%s", after)
	}
}

func TestGrokPermissionLeavesAnOperatorsOwnTable(t *testing.T) {
	roots := testConfigRoots(t)
	adapter, _ := lookupClientAdapter("grok")
	client := adapter.resolve(roots)
	if err := os.MkdirAll(filepath.Dir(client.ConfigFile), 0o700); err != nil {
		t.Fatal(err)
	}
	existing := "[permission]\nallow = [\"Bash(ls)\"]\n"
	if err := os.WriteFile(client.ConfigFile, []byte(existing), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := addGrokPermission(client.ConfigFile); err == nil {
		t.Fatal("expected a refusal rather than a second [permission] table")
	}
	raw, err := readConfigFile(client.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if raw != existing {
		t.Errorf("the operator's table was modified:\n%s", raw)
	}
}

func TestClientKeyRejectsAnInvalidDelivery(t *testing.T) {
	response := deviceTokenResponse{ClientKeys: map[string]string{
		"cursor":         "not-a-key",
		"emisar-mcp-cli": testAPIKey(0x31),
	}}
	if _, err := response.clientKey("cursor"); err == nil {
		t.Error("expected an invalid key to be refused")
	}
	if _, err := response.clientKey("zed"); err == nil {
		t.Error("expected a missing key to be refused")
	}
	if key, err := response.clientKey("emisar-mcp-cli"); err != nil || key != testAPIKey(0x31) {
		t.Errorf("clientKey = %q, %v", key, err)
	}
}

func TestClaudeCodePermissionRemovalAddsNothing(t *testing.T) {
	roots := testConfigRoots(t)
	settings := filepath.Join(roots.home, ".claude", "settings.json")
	if err := os.MkdirAll(filepath.Dir(settings), 0o700); err != nil {
		t.Fatal(err)
	}
	existing := "{\n  \"model\": \"opus\"\n}\n"
	if err := os.WriteFile(settings, []byte(existing), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := editClaudePermission(settings, false); err != nil {
		t.Fatalf("remove: %v", err)
	}
	raw, err := readConfigFile(settings)
	if err != nil {
		t.Fatal(err)
	}
	// Removing a rule that is not there must not give the file a permissions
	// block it never had.
	if raw != existing {
		t.Errorf("removal rewrote a file it had nothing to remove from:\n%s", raw)
	}
}
