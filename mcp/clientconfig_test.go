package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// The adapter matrix: every advertised client is installed into a fresh file
// and into an existing file carrying unrelated settings, then removed. This is
// the contract the docs and the compatibility spec publish, so a client added
// to the table without a case here fails the completeness check below.
var clientConfigCases = []struct {
	id        string
	existing  string
	unrelated string
	entry     string
}{
	{
		id:        "claude-code",
		existing:  "{\n  \"numStartups\": 7,\n  \"mcpServers\": {\n    \"other\": {\"command\": \"y\"}\n  }\n}\n",
		unrelated: "\"numStartups\": 7",
		entry:     `{"command":"BIN","env":{"EMISAR_URL":"https://emisar.dev","EMISAR_API_KEY":"emk-key","EMISAR_CLIENT":"claude-code"}}`,
	},
	{
		id:        "claude-desktop",
		existing:  "{\n  \"globalShortcut\": \"Alt+Space\"\n}\n",
		unrelated: "\"globalShortcut\"",
		entry:     `{"command":"BIN","env":{"EMISAR_URL":"https://emisar.dev","EMISAR_API_KEY":"emk-key","EMISAR_CLIENT":"claude-desktop"}}`,
	},
	{
		id:        "cursor",
		existing:  "{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"y\"}\n  }\n}\n",
		unrelated: "\"other\"",
		entry:     `{"command":"BIN","env":{"EMISAR_URL":"https://emisar.dev","EMISAR_API_KEY":"emk-key","EMISAR_CLIENT":"cursor"}}`,
	},
	{
		id:        "vscode",
		existing:  "{\n  // user servers\n  \"servers\": {\n    \"other\": {\"type\": \"stdio\", \"command\": \"y\"}\n  }\n}\n",
		unrelated: "// user servers",
		entry:     `{"type":"stdio","command":"BIN","args":[],"envFile":"ENVFILE"}`,
	},
	{
		id:        "gemini",
		existing:  "{\n  \"theme\": \"Default\"\n}\n",
		unrelated: "\"theme\"",
		entry:     `{"command":"BIN","env":{"EMISAR_URL":"https://emisar.dev","EMISAR_API_KEY":"emk-key","EMISAR_CLIENT":"gemini"}}`,
	},
	{
		id:        "codex",
		existing:  "model = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"y\"\n",
		unrelated: "model = \"gpt-5\"",
	},
	{
		id:        "openclaw",
		existing:  "{\n  \"mcp\": {\n    \"timeout\": 30,\n    \"servers\": {\n      \"other\": {\"command\": \"y\"}\n    }\n  }\n}\n",
		unrelated: "\"timeout\": 30",
		entry:     `{"command":"BIN","env":{"EMISAR_URL":"https://emisar.dev","EMISAR_API_KEY":"emk-key","EMISAR_CLIENT":"openclaw"}}`,
	},
	{
		id:        "opencode",
		existing:  "{\n  \"$schema\": \"https://opencode.ai/config.json\"\n}\n",
		unrelated: "\"$schema\"",
		entry:     `{"type":"local","command":["BIN"],"enabled":true,"environment":{"EMISAR_URL":"https://emisar.dev","EMISAR_API_KEY":"emk-key","EMISAR_CLIENT":"opencode"}}`,
	},
	{
		id:        "windsurf",
		existing:  "{\n  \"mcpServers\": {}\n}\n",
		unrelated: "\"mcpServers\"",
		entry:     `{"command":"BIN","env":{"EMISAR_URL":"https://emisar.dev","EMISAR_API_KEY":"emk-key","EMISAR_CLIENT":"windsurf"}}`,
	},
	{
		id:        "pi",
		existing:  "{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"y\"}\n  }\n}\n",
		unrelated: "\"other\"",
		entry:     `{"command":"BIN","env":{"EMISAR_URL":"https://emisar.dev","EMISAR_API_KEY":"emk-key","EMISAR_CLIENT":"pi"}}`,
	},
	{
		id:        "copilot-cli",
		existing:  "{\n  \"mcpServers\": {\n    \"other\": {\"type\": \"local\", \"command\": \"y\"}\n  }\n}\n",
		unrelated: "\"other\"",
		entry:     `{"type":"local","command":"BIN","args":[],"env":{"EMISAR_URL":"https://emisar.dev","EMISAR_API_KEY":"emk-key","EMISAR_CLIENT":"copilot-cli"},"tools":["*"]}`,
	},
	{
		id:        "zed",
		existing:  "{\n  /* Zed settings */\n  \"vim_mode\": true,\n}\n",
		unrelated: "/* Zed settings */",
		entry:     `{"source":"custom","command":"BIN","args":[],"env":{"EMISAR_URL":"https://emisar.dev","EMISAR_API_KEY":"emk-key","EMISAR_CLIENT":"zed"}}`,
	},
	{
		id:        "hermes",
		existing:  "model: sonnet\n",
		unrelated: "model: sonnet",
	},
	{
		id:        "goose",
		existing:  "GOOSE_PROVIDER: anthropic\n",
		unrelated: "GOOSE_PROVIDER: anthropic",
	},
	{
		id:        "grok",
		existing:  "default_model = \"grok-4\"\n",
		unrelated: "default_model = \"grok-4\"",
	},
}

func testConfigRoots(t *testing.T) configRoots {
	t.Helper()
	root := t.TempDir()
	return configRoots{
		home:      filepath.Join(root, "home"),
		appConfig: filepath.Join(root, "appconfig"),
		dotConfig: filepath.Join(root, "home", ".config"),
	}
}

func testEntryRequest(command, clientID string) clientEntryRequest {
	return clientEntryRequest{
		Command:  command,
		Origin:   "https://emisar.dev",
		APIKey:   "emk-key",
		ClientID: clientID,
	}
}

func TestClientConfigCasesCoverEveryAdapter(t *testing.T) {
	covered := make(map[string]bool, len(clientConfigCases))
	for _, testCase := range clientConfigCases {
		covered[testCase.id] = true
	}
	for _, adapter := range clientAdapters {
		if !covered[adapter.ID] {
			t.Errorf("client %q has no config case", adapter.ID)
		}
	}
}

func TestClientInstallAndRemove(t *testing.T) {
	for _, testCase := range clientConfigCases {
		for _, seeded := range []bool{false, true} {
			name := testCase.id
			if seeded {
				name += "/existing"
			} else {
				name += "/fresh"
			}
			t.Run(name, func(t *testing.T) {
				adapter, ok := lookupClientAdapter(testCase.id)
				if !ok {
					t.Fatalf("unknown client %q", testCase.id)
				}
				roots := testConfigRoots(t)
				client := adapter.resolve(roots)
				if err := os.MkdirAll(filepath.Dir(client.ConfigFile), 0o700); err != nil {
					t.Fatal(err)
				}
				if seeded {
					if err := os.WriteFile(client.ConfigFile, []byte(testCase.existing), 0o600); err != nil {
						t.Fatal(err)
					}
					if err := os.WriteFile(client.ConfigFile+configBackupSuffix, []byte("stale backup"), 0o600); err != nil {
						t.Fatal(err)
					}
				}
				if client.configured(client.ConfigFile) {
					t.Fatal("a config without an emisar entry reads as connected")
				}

				command := filepath.Join(roots.home, ".local", "bin", "emisar-mcp")
				if err := client.install(testEntryRequest(command, testCase.id)); err != nil {
					t.Fatalf("install: %v", err)
				}
				if !client.configured(client.ConfigFile) {
					raw, _ := readConfigFile(client.ConfigFile)
					t.Fatalf("installed config does not read as connected:\n%s", raw)
				}
				raw, err := readConfigFile(client.ConfigFile)
				if err != nil {
					t.Fatal(err)
				}
				if seeded && !strings.Contains(raw, testCase.unrelated) {
					t.Errorf("install dropped %q:\n%s", testCase.unrelated, raw)
				}
				if !strings.Contains(raw, "emk-key") && client.EnvFilePath == "" {
					t.Errorf("the API key did not reach the config:\n%s", raw)
				}
				if seeded {
					backup, err := os.ReadFile(client.ConfigFile + configBackupSuffix)
					if err != nil {
						t.Errorf("no backup was written: %v", err)
					} else if string(backup) != testCase.existing {
						t.Errorf("backup = %q, want %q", backup, testCase.existing)
					}
				}
				if testCase.entry != "" {
					assertJSONEntry(t, client, raw, testCase.entry, command)
				}

				if err := client.remove(); err != nil {
					t.Fatalf("remove: %v", err)
				}
				if client.configured(client.ConfigFile) {
					after, _ := readConfigFile(client.ConfigFile)
					t.Fatalf("the entry survived removal:\n%s", after)
				}
				after, err := readConfigFile(client.ConfigFile)
				if err != nil {
					t.Fatal(err)
				}
				if strings.Contains(after, "emk-key") {
					t.Errorf("the API key survived removal:\n%s", after)
				}
				if seeded && !strings.Contains(after, testCase.unrelated) {
					t.Errorf("removal dropped %q:\n%s", testCase.unrelated, after)
				}
				if _, err := os.Stat(client.ConfigFile + configBackupSuffix); !os.IsNotExist(err) {
					t.Errorf("the backup outlived the removal: %v", err)
				}
				if client.EnvFilePath != "" {
					if _, err := os.Stat(client.EnvFilePath); !os.IsNotExist(err) {
						t.Errorf("the env file outlived the removal: %v", err)
					}
				}
			})
		}
	}
}

func TestClientInstallReplacesBackupWithoutFollowingSymlinks(t *testing.T) {
	for _, testCase := range []struct {
		id       string
		existing string
	}{
		{id: "cursor", existing: "{\n  \"mcpServers\": {}\n}\n"},
		{id: "codex", existing: "model = \"gpt-5\"\n"},
		{id: "hermes", existing: "model: sonnet\n"},
	} {
		t.Run(testCase.id, func(t *testing.T) {
			adapter, _ := lookupClientAdapter(testCase.id)
			roots := testConfigRoots(t)
			client := adapter.resolve(roots)
			if err := os.MkdirAll(filepath.Dir(client.ConfigFile), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(client.ConfigFile, []byte(testCase.existing), 0o600); err != nil {
				t.Fatal(err)
			}

			attackTarget := filepath.Join(roots.home, "root-owned-target")
			if err := os.WriteFile(attackTarget, []byte("do not overwrite"), 0o600); err != nil {
				t.Fatal(err)
			}
			backupPath := client.ConfigFile + configBackupSuffix
			if err := os.Symlink(attackTarget, backupPath); err != nil {
				if runtime.GOOS == "windows" {
					t.Skip("creating a Windows symlink requires developer mode or SeCreateSymbolicLinkPrivilege")
				}
				t.Fatal(err)
			}

			if err := client.install(testEntryRequest("/usr/local/bin/emisar-mcp", testCase.id)); err != nil {
				t.Fatalf("install: %v", err)
			}
			attackContents, err := os.ReadFile(attackTarget)
			if err != nil {
				t.Fatal(err)
			}
			if string(attackContents) != "do not overwrite" {
				t.Fatalf("backup followed the symlink: target = %q", attackContents)
			}
			backupInfo, err := os.Lstat(backupPath)
			if err != nil {
				t.Fatal(err)
			}
			if backupInfo.Mode()&os.ModeSymlink != 0 {
				t.Fatal("backup symlink was not replaced")
			}
			if runtime.GOOS != "windows" && backupInfo.Mode().Perm() != 0o600 {
				t.Errorf("backup mode = %v, want 0600", backupInfo.Mode().Perm())
			}
			backupContents, err := os.ReadFile(backupPath)
			if err != nil {
				t.Fatal(err)
			}
			if string(backupContents) != testCase.existing {
				t.Errorf("backup = %q, want %q", backupContents, testCase.existing)
			}
		})
	}
}

func TestClientInstallRefusesSymlinkedConfigSources(t *testing.T) {
	for _, testCase := range []struct {
		id       string
		existing string
	}{
		{id: "cursor", existing: "{\n  \"mcpServers\": {}\n}\n"},
		{id: "codex", existing: "model = \"gpt-5\"\n"},
		{id: "hermes", existing: "model: sonnet\n"},
	} {
		t.Run(testCase.id, func(t *testing.T) {
			adapter, _ := lookupClientAdapter(testCase.id)
			roots := testConfigRoots(t)
			client := adapter.resolve(roots)
			if err := os.MkdirAll(filepath.Dir(client.ConfigFile), 0o700); err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(roots.home, testCase.id+"-config-target")
			if err := os.WriteFile(target, []byte(testCase.existing), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, client.ConfigFile); err != nil {
				if runtime.GOOS == "windows" {
					t.Skip("creating a Windows symlink requires developer mode or SeCreateSymbolicLinkPrivilege")
				}
				t.Fatal(err)
			}

			err := client.install(testEntryRequest("/usr/local/bin/emisar-mcp", testCase.id))
			if err == nil || !strings.Contains(err.Error(), "is a symlink") {
				t.Fatalf("install error = %v, want symlink refusal", err)
			}
			contents, readErr := os.ReadFile(target)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if string(contents) != testCase.existing {
				t.Errorf("symlink target changed: got %q, want %q", contents, testCase.existing)
			}
			info, statErr := os.Lstat(client.ConfigFile)
			if statErr != nil {
				t.Fatal(statErr)
			}
			if info.Mode()&os.ModeSymlink == 0 {
				t.Fatal("refused config symlink was replaced")
			}
			if _, statErr := os.Lstat(client.ConfigFile + configBackupSuffix); !errors.Is(statErr, os.ErrNotExist) {
				t.Errorf("backup written for refused source: %v", statErr)
			}
		})
	}
}

func TestConfigFileIdentityRejectsPathSwap(t *testing.T) {
	root := t.TempDir()
	original := filepath.Join(root, "original.json")
	path := filepath.Join(root, "config.json")
	if err := os.WriteFile(original, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("replacement"), 0o600); err != nil {
		t.Fatal(err)
	}
	file, err := os.Open(original)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	if err := validateConfigFileIdentity(path, file); err == nil || !strings.Contains(err.Error(), "changed while opening") {
		t.Fatalf("identity error = %v, want changed-path refusal", err)
	}
}

// A Windows command path carries backslashes, and the expectation templates
// place it inside a JSON string. Splicing it raw produced \U from
// C:\Users\..., so every JSON-config client failed on Windows while the
// config the installer wrote was perfectly fine. Running the substitution over
// a Windows-shaped path here keeps that reachable from any platform.
func TestJSONEntryExpectationSurvivesAWindowsPath(t *testing.T) {
	const windowsCommand = `C:\Users\runneradmin\AppData\Local\emisar\emisar-mcp.exe`

	expected := strings.ReplaceAll(
		`{"command":"BIN","args":[]}`, "BIN", jsonStringBody(t, windowsCommand))

	var want map[string]any
	if err := decodeJSON([]byte(expected), &want); err != nil {
		t.Fatalf("a Windows path must not break the expectation: %v", err)
	}
	if want["command"] != windowsCommand {
		t.Fatalf("command = %v, want %s", want["command"], windowsCommand)
	}
}

// jsonStringBody renders s as it would appear BETWEEN the quotes of a JSON
// string, so a value can be substituted into a quoted placeholder in a literal
// expectation without breaking it.
func jsonStringBody(t *testing.T, s string) string {
	t.Helper()
	encoded, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("encoding %q for a JSON string: %v", s, err)
	}
	return string(encoded[1 : len(encoded)-1])
}

func assertJSONEntry(t *testing.T, client detectedClient, raw, expected, command string) {
	t.Helper()
	document, err := parseJSONConfig(raw)
	if err != nil {
		t.Fatalf("installed config does not parse: %v\n%s", err, raw)
	}
	written, ok := lookupJSONPath(document, client.container, emisarServerName)
	if !ok {
		t.Fatalf("no emisar entry at %v:\n%s", client.container, raw)
	}
	// BIN and ENVFILE stand inside JSON string literals, so the paths replacing
	// them have to be escaped for that context. A Windows path splices in as
	// C:\Users\..., and \U is not a valid JSON escape — the expectation, not the
	// config under test, is what fails to parse.
	expected = strings.ReplaceAll(expected, "BIN", jsonStringBody(t, command))
	expected = strings.ReplaceAll(expected, "ENVFILE", jsonStringBody(t, client.EnvFilePath))
	var want any
	if err := decodeJSON([]byte(expected), &want); err != nil {
		t.Fatalf("bad expectation: %v", err)
	}
	if !sameJSONValue(written, want) {
		t.Errorf("entry mismatch\n got: %#v\nwant: %s", written, expected)
	}
}

func TestVSCodeKeepsTheAPIKeyOutOfTheEditorConfig(t *testing.T) {
	adapter, _ := lookupClientAdapter("vscode")
	roots := testConfigRoots(t)
	client := adapter.resolve(roots)
	if err := client.install(testEntryRequest("/usr/local/bin/emisar-mcp", "vscode")); err != nil {
		t.Fatalf("install: %v", err)
	}
	raw, err := readConfigFile(client.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(raw, "emk-key") {
		t.Errorf("the API key reached a config VS Code may sync:\n%s", raw)
	}
	env, err := readConfigFile(client.EnvFilePath)
	if err != nil {
		t.Fatalf("env file: %v", err)
	}
	if !strings.Contains(env, "EMISAR_API_KEY=emk-key") {
		t.Errorf("the env file has no key:\n%s", env)
	}
	info, err := os.Stat(client.EnvFilePath)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Errorf("env file mode is %v, want 0600", info.Mode().Perm())
	}
}

func TestConnectedClientIsDetected(t *testing.T) {
	for _, testCase := range clientConfigCases {
		t.Run(testCase.id, func(t *testing.T) {
			adapter, _ := lookupClientAdapter(testCase.id)
			roots := testConfigRoots(t)
			client := adapter.resolve(roots)
			if err := client.install(testEntryRequest("/usr/local/bin/emisar-mcp", testCase.id)); err != nil {
				t.Fatalf("install: %v", err)
			}
			if !adapter.installed(roots) {
				t.Error("a client with a written config does not read as installed")
			}
			for _, detected := range detectClients(roots) {
				if detected.ID == testCase.id && !detected.Connected {
					t.Error("detectClients did not mark the client connected")
				}
			}
		})
	}
}

// A config file can express a second MCP server with its own `command`, which
// the client runs on next start. So a value that escapes its string literal is
// arbitrary code execution on the operator's workstation off the back of a
// hostile portal response. Quoting neutralizes it; a control byte is refused
// outright because the env-file format cannot escape one at all.
func TestInstallNeutralizesAnEscapeAttempt(t *testing.T) {
	for _, id := range []string{"cursor", "codex", "goose"} {
		t.Run(id, func(t *testing.T) {
			adapter, _ := lookupClientAdapter(id)
			roots := testConfigRoots(t)
			client := adapter.resolve(roots)
			request := testEntryRequest("/usr/local/bin/emisar-mcp", id)
			request.APIKey = `emk-key"}}, "evil": {"command": "/bin/sh`
			if err := client.install(request); err != nil {
				t.Fatalf("install: %v", err)
			}
			raw, err := readConfigFile(client.ConfigFile)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(raw, `"evil"`) || strings.Contains(raw, "evil:") {
				t.Fatalf("the injected key escaped its literal:\n%s", raw)
			}
			if !strings.Contains(raw, `\"`) {
				t.Errorf("the quote was not escaped:\n%s", raw)
			}
		})
	}
}

func TestInstallRefusesControlBytes(t *testing.T) {
	adapter, _ := lookupClientAdapter("cursor")
	roots := testConfigRoots(t)
	client := adapter.resolve(roots)
	for _, value := range []string{"emk-key\nEMISAR_URL=evil", "emk-key\x00", ""} {
		request := testEntryRequest("/usr/local/bin/emisar-mcp", "cursor")
		request.APIKey = value
		if err := client.install(request); err == nil {
			t.Errorf("expected a refusal for %q", value)
		}
	}
}

func TestQuotedValuesSurviveJSONTOMLAndYAML(t *testing.T) {
	// A Windows path is the realistic case: backslashes must be escaped in all
	// three formats, and a quote must never end the literal early.
	command := `C:\Program Files\emisar\emisar-mcp.exe`
	for _, id := range []string{"cursor", "codex", "hermes", "goose", "grok"} {
		t.Run(id, func(t *testing.T) {
			adapter, _ := lookupClientAdapter(id)
			roots := testConfigRoots(t)
			client := adapter.resolve(roots)
			if err := client.install(testEntryRequest(command, id)); err != nil {
				t.Fatalf("install: %v", err)
			}
			raw, err := readConfigFile(client.ConfigFile)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(raw, `C:\Program`) {
				t.Errorf("the backslash was written raw:\n%s", raw)
			}
			if !strings.Contains(raw, `C:\\Program Files\\emisar\\emisar-mcp.exe`) {
				t.Errorf("the path was not escaped:\n%s", raw)
			}
		})
	}
}

func TestYAMLClientRefusesToMergeAnExistingKey(t *testing.T) {
	adapter, _ := lookupClientAdapter("goose")
	roots := testConfigRoots(t)
	client := adapter.resolve(roots)
	if err := os.MkdirAll(filepath.Dir(client.ConfigFile), 0o700); err != nil {
		t.Fatal(err)
	}
	existing := "extensions:\n  developer:\n    enabled: true\n"
	if err := os.WriteFile(client.ConfigFile, []byte(existing), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := client.install(testEntryRequest("/usr/local/bin/emisar-mcp", "goose")); err == nil {
		t.Fatal("expected a refusal rather than a duplicate YAML key")
	}
	raw, err := readConfigFile(client.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if raw != existing {
		t.Errorf("the config was modified anyway:\n%s", raw)
	}
}

func TestTOMLRemovalKeepsUnrelatedTables(t *testing.T) {
	raw := "model = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"y\"\n\n[mcp_servers.emisar]\ncommand = \"x\"\n\n[mcp_servers.emisar.env]\nEMISAR_URL = \"https://emisar.dev\"\n\n[profiles.work]\nname = \"work\"\n"
	edited := removeTOMLTable(raw)
	for _, kept := range []string{"model = \"gpt-5\"", "[mcp_servers.other]", "[profiles.work]", "name = \"work\""} {
		if !strings.Contains(edited, kept) {
			t.Errorf("removal dropped %q:\n%s", kept, edited)
		}
	}
	if strings.Contains(edited, "emisar") {
		t.Errorf("an emisar table survived:\n%s", edited)
	}
}

func TestYAMLRemovalKeepsSiblingExtensions(t *testing.T) {
	raw := "extensions:\n  developer:\n    enabled: true\n  emisar:\n    name: emisar\n    envs:\n      EMISAR_API_KEY: \"emk-key\"\n  memory:\n    enabled: false\n"
	edited := removeYAMLEntry(raw, "extensions")
	for _, kept := range []string{"developer:", "memory:", "enabled: false"} {
		if !strings.Contains(edited, kept) {
			t.Errorf("removal dropped %q:\n%s", kept, edited)
		}
	}
	if strings.Contains(edited, "emisar") {
		t.Errorf("the emisar entry survived:\n%s", edited)
	}
}

func TestYAMLRemovalDropsAnEmptiedTopLevelKey(t *testing.T) {
	raw := "model: sonnet\n\nmcp_servers:\n  emisar:\n    command: x\n"
	edited := removeYAMLEntry(raw, "mcp_servers")
	if strings.Contains(edited, "mcp_servers:") {
		t.Errorf("an emptied key survived, so a later connect cannot append:\n%s", edited)
	}
	if !strings.Contains(edited, "model: sonnet") {
		t.Errorf("removal dropped an unrelated key:\n%s", edited)
	}
}
