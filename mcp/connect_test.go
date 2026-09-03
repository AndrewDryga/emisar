package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
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
		{name: "yes is disconnect only", args: []string{"--yes"}, wantErr: true},
		{name: "forget is disconnect only", args: []string{"--forget"}, wantErr: true},
		{name: "auto-permit is connect only", args: []string{"--auto-permit"}, disconnect: true, wantErr: true},
		{name: "url is connect only", args: []string{"--url", "https://x"}, disconnect: true, wantErr: true},
		{
			name:       "yes on disconnect",
			args:       []string{"--yes"},
			disconnect: true,
			check: func(t *testing.T, parsed parsedConnectArgs) {
				if !parsed.assumeYes {
					t.Errorf("parsed = %+v", parsed.connectOptions)
				}
			},
		},
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

func TestConnectPreflightDoesNotRequestAKeyForAnUnwritableConfig(t *testing.T) {
	roots := useConnectTestHome(t)
	adapter, _ := lookupClientAdapter("goose")
	client := adapter.resolve(roots)
	if err := os.MkdirAll(filepath.Dir(client.ConfigFile), 0o700); err != nil {
		t.Fatal(err)
	}
	// Goose owns this top-level key, but without an existing Emisar child the
	// deliberately small YAML editor cannot safely merge into it.
	if err := os.WriteFile(client.ConfigFile, []byte("extensions:\n  developer:\n    enabled: true\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests++
		http.Error(w, "authorization must not start", http.StatusInternalServerError)
	}))
	defer server.Close()
	authenticator := testConnectAuthenticator(server)
	var stdout, stderr bytes.Buffer
	code := connectClients(
		connectOptions{origin: server.URL, clientIDs: []string{"goose"}},
		strings.NewReader(""),
		&stdout,
		&stderr,
		authenticator,
	)
	if code != 1 {
		t.Fatalf("exit = %d, want 1\nstdout:\n%s\nstderr:\n%s", code, stdout.String(), stderr.String())
	}
	if requests != 0 {
		t.Fatalf("authorization requests = %d, want 0", requests)
	}
	if !strings.Contains(stderr.String(), "No approval was requested") {
		t.Errorf("the refusal did not explain the credential boundary:\n%s", stderr.String())
	}
}

func TestConnectPreflightChecksEveryActualDestination(t *testing.T) {
	for _, testCase := range []struct {
		name string
		id   string
		jam  func(*testing.T, detectedClient)
	}{
		{
			name: "backup",
			id:   "codex",
			jam: func(t *testing.T, client detectedClient) {
				t.Helper()
				if err := os.Mkdir(client.ConfigFile+configBackupSuffix, 0o700); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "env file",
			id:   "vscode",
			jam: func(t *testing.T, client detectedClient) {
				t.Helper()
				if err := os.Remove(client.EnvFilePath); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(client.EnvFilePath, 0o700); err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			roots := useConnectTestHome(t)
			adapter, _ := lookupClientAdapter(testCase.id)
			client := adapter.resolve(roots)
			if err := client.install(testEntryRequest("/usr/local/bin/emisar-mcp", testCase.id)); err != nil {
				t.Fatalf("arrange connected client: %v", err)
			}
			testCase.jam(t, client)

			requests := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				requests++
				http.Error(w, "authorization must not start", http.StatusInternalServerError)
			}))
			defer server.Close()
			var stdout, stderr bytes.Buffer
			code := connectClients(
				connectOptions{origin: server.URL, clientIDs: []string{testCase.id}},
				strings.NewReader(""),
				&stdout,
				&stderr,
				testConnectAuthenticator(server),
			)
			if code != 1 {
				t.Fatalf("exit = %d, want 1\nstdout:\n%s\nstderr:\n%s", code, stdout.String(), stderr.String())
			}
			if requests != 0 {
				t.Fatalf("authorization requests = %d, want 0", requests)
			}
			if !strings.Contains(stderr.String(), "No approval was requested") {
				t.Errorf("the refusal did not explain the credential boundary:\n%s", stderr.String())
			}
		})
	}
}

// `--client cursor` before Cursor is installed configured nothing and exited 0,
// so a scripted install checking $? recorded a connection that never happened.
func TestConnectFailsWhenANamedClientIsNotInstalled(t *testing.T) {
	useConnectTestHome(t)
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests++
		http.Error(w, "authorization must not start", http.StatusInternalServerError)
	}))
	defer server.Close()

	var stdout, stderr bytes.Buffer
	code := connectClients(
		connectOptions{origin: server.URL, clientIDs: []string{"cursor", "zed"}},
		strings.NewReader(""),
		&stdout,
		&stderr,
		testConnectAuthenticator(server),
	)
	if code == 0 {
		t.Fatalf("exit = 0, want non-zero\nstdout:\n%s\nstderr:\n%s", stdout.String(), stderr.String())
	}
	if requests != 0 {
		t.Fatalf("authorization requests = %d, want 0", requests)
	}
	for _, want := range []string{"cursor", "zed", "mcp.json", "settings.json"} {
		if !strings.Contains(stderr.String(), want) {
			t.Errorf("the refusal never named %q:\n%s", want, stderr.String())
		}
	}
}

func TestConnectAcceptsANamedClientThatIsInstalled(t *testing.T) {
	roots := useConnectTestHome(t)
	adapter, _ := lookupClientAdapter("cursor")
	if err := os.MkdirAll(filepath.Dir(adapter.file(roots)), 0o700); err != nil {
		t.Fatal(err)
	}
	server := newConnectAuthServer(t, "cursor", testAPIKey(0x51), testAPIKey(0x52))
	defer server.Close()

	var stdout, stderr bytes.Buffer
	code := connectClients(
		connectOptions{origin: server.URL, clientIDs: []string{"cursor"}},
		strings.NewReader(""),
		&stdout,
		&stderr,
		testConnectAuthenticator(server),
	)
	if code != 0 {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout.String(), stderr.String())
	}
	raw, err := readConfigFile(adapter.file(roots))
	if err != nil || !strings.Contains(raw, "emisar") {
		t.Fatalf("cursor config = %q, err = %v", raw, err)
	}
}

func TestExplicitReconnectRotatesKeyAndRepointsURL(t *testing.T) {
	roots := useConnectTestHome(t)
	adapter, _ := lookupClientAdapter("codex")
	client := adapter.resolve(roots)
	if err := os.MkdirAll(filepath.Dir(client.ConfigFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(client.ConfigFile, []byte("model = \"gpt-5\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	oldKey := testAPIKey(0x41)
	oldCLIKey := testAPIKey(0x42)
	oldServer := newConnectAuthServer(t, "codex", oldKey, oldCLIKey)
	defer oldServer.Close()
	var stdout, stderr bytes.Buffer
	code := connectClients(
		connectOptions{origin: oldServer.URL, clientIDs: []string{"codex"}},
		strings.NewReader(""),
		&stdout,
		&stderr,
		testConnectAuthenticator(oldServer),
	)
	if code != 0 {
		t.Fatalf("first connect exit = %d\nstdout:\n%s\nstderr:\n%s", code, stdout.String(), stderr.String())
	}
	before, err := readConfigFile(client.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}

	newKey := testAPIKey(0x43)
	newCLIKey := testAPIKey(0x44)
	newServer := newConnectAuthServer(t, "codex", newKey, newCLIKey)
	defer newServer.Close()
	stdout.Reset()
	stderr.Reset()
	code = connectClients(
		connectOptions{origin: newServer.URL, clientIDs: []string{"codex"}},
		strings.NewReader(""),
		&stdout,
		&stderr,
		testConnectAuthenticator(newServer),
	)
	if code != 0 {
		t.Fatalf("reconnect exit = %d\nstdout:\n%s\nstderr:\n%s", code, stdout.String(), stderr.String())
	}
	after, err := readConfigFile(client.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{newServer.URL, newKey} {
		if !strings.Contains(after, want) {
			t.Errorf("reconnect did not write %q:\n%s", want, after)
		}
	}
	for _, stale := range []string{oldServer.URL, oldKey} {
		if strings.Contains(after, stale) {
			t.Errorf("reconnect kept %q:\n%s", stale, after)
		}
	}
	backup, err := os.ReadFile(client.ConfigFile + configBackupSuffix)
	if err != nil {
		t.Fatalf("reconnect backup: %v", err)
	}
	if string(backup) != before {
		t.Errorf("reconnect backup differs from the replaced config\n got: %q\nwant: %q", backup, before)
	}
	if !strings.Contains(stdout.String(), "connected") {
		t.Errorf("successful reconnect was not reported:\n%s", stdout.String())
	}
}

func useConnectTestHome(t *testing.T) configRoots {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("APPDATA", filepath.Join(home, "AppData", "Roaming"))
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	t.Setenv("EMISAR_ALLOW_INSECURE", "1")
	roots, err := currentConfigRoots()
	if err != nil {
		t.Fatal(err)
	}
	return roots
}

func testConnectAuthenticator(server *httptest.Server) deviceAuthenticator {
	return deviceAuthenticator{
		client:      server.Client(),
		openBrowser: func(string) bool { return false },
		stdoutIsTTY: func(io.Writer) bool { return false },
		now:         time.Now,
		wait:        func(context.Context, time.Duration) error { return nil },
	}
}

func newConnectAuthServer(t *testing.T, clientID, clientKey, cliKey string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/api/mcp/device_authorization":
			var body struct {
				RequestedClients []string `json:"requested_clients"`
			}
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
				t.Errorf("decode authorization request: %v", err)
			}
			if !slices.Equal(body.RequestedClients, []string{deviceAuthClientID, clientID}) {
				t.Errorf("requested clients = %#v", body.RequestedClients)
			}
			origin := "http://" + request.Host
			_ = json.NewEncoder(w).Encode(map[string]any{
				"device_code":               "emdg-0123456789abcdef",
				"user_code":                 "ABCD-2345",
				"verification_uri":          origin + "/activate",
				"verification_uri_complete": origin + "/activate?code=ABCD-2345",
				"expires_in":                60,
				"interval":                  1,
			})
		case "/api/mcp/device_token":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"account_id":   blitzAccountID,
				"account_slug": "blitz",
				"account_name": "Blitz",
				"client_keys": map[string]string{
					deviceAuthClientID: cliKey,
					clientID:           clientKey,
				},
			})
		default:
			http.NotFound(w, request)
		}
	}))
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

// Only Gemini's schema defines `trust` inside the server entry. Claude Code
// keeps its auto-permit in settings.json, so an opted-in run must not also leave
// a key Claude Code never defined inside the operator's ~/.claude.json.
func TestAutoPermitNeverWritesTrustIntoAClientWithoutIt(t *testing.T) {
	for _, id := range []string{"claude-code", "cursor"} {
		t.Run(id, func(t *testing.T) {
			adapter, _ := lookupClientAdapter(id)
			client := adapter.resolve(testConfigRoots(t))
			request := testEntryRequest("/usr/local/bin/emisar-mcp", id)
			request.AutoPermit = true
			if err := client.install(request); err != nil {
				t.Fatalf("install: %v", err)
			}
			raw, err := readConfigFile(client.ConfigFile)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(raw, "trust") {
				t.Errorf("%s got a trust key its schema does not define:\n%s", id, raw)
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
