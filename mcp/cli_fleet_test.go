package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const cliFleetRunnersResult = `{
  "ok":true,
  "summary":{"connected":1,"disconnected":2,"pending":0,"disabled":0,"matched":3},
  "runners":[
    {
      "name":"db-iad-01",
      "status":"connected",
      "group":"postgres",
      "hostname":"db-iad-01.example",
      "labels":{"region":"us-east-1","env":"prod"},
      "packs":["postgres","systemd"],
      "packs_next":{"tool":"list_packs","arguments":{"runner_refs":["db-iad-01~0123456789abcdef0123456789abcdef"],"availability":"all","limit":15}},
      "last_seen_at":"2026-08-21T02:45:31Z",
      "runner_ref":"db-iad-01~0123456789abcdef0123456789abcdef",
      "enforce_signatures":true,
      "issues":[]
    },
    {
      "name":"db-fra-02",
      "status":"disconnected",
      "group":"postgres",
      "hostname":"db-fra-02.example",
      "labels":{},
      "packs":[],
      "packs_next":{"tool":"list_packs","arguments":{"runner_refs":["db-fra-02~abcdef0123456789abcdef0123456789"],"availability":"all","limit":15}},
      "last_seen_at":"2026-08-20T22:10:00Z",
      "runner_ref":"db-fra-02~abcdef0123456789abcdef0123456789",
      "enforce_signatures":false,
      "issues":[{"code":"runner_disconnected","message":"The runner is disconnected."}]
    }
  ],
  "observed_at":"2026-08-21T02:45:31Z",
  "next_cursor":"opaque"
}`

func TestCLIListRunnersUsesFleetFormatting(t *testing.T) {
	var stdout bytes.Buffer
	err := writeCLIToolOutput(
		&stdout,
		listRunnersToolName,
		json.RawMessage(`{"limit":2}`),
		json.RawMessage(cliFleetRunnersResult),
		"",
		false,
		true,
	)
	if err != nil {
		t.Fatal(err)
	}
	want := "Showing 2 of 3 runners — 1 connected, 2 disconnected\n\n" +
		"db-iad-01 — connected\n" +
		"  db-iad-01.example · group postgres\n" +
		"  Labels  env=prod · region=us-east-1\n" +
		"  Packs  postgres, systemd\n" +
		"  See packs  emisar-mcp list_packs '{\"runner_refs\":[\"db-iad-01~0123456789abcdef0123456789abcdef\"],\"availability\":\"all\",\"limit\":15}'\n" +
		"  Last seen  2026-08-21 02:45 UTC\n" +
		"  Runner ref  db-iad-01~0123456789abcdef0123456789abcdef\n" +
		"  Dispatch signatures required.\n\n" +
		"db-fra-02 — disconnected\n" +
		"  db-fra-02.example · group postgres\n" +
		"  See packs  emisar-mcp list_packs '{\"runner_refs\":[\"db-fra-02~abcdef0123456789abcdef0123456789\"],\"availability\":\"all\",\"limit\":15}'\n" +
		"  Last seen  2026-08-20 22:10 UTC\n" +
		"  Runner ref  db-fra-02~abcdef0123456789abcdef0123456789\n" +
		"  Issue  The runner is disconnected.\n\n" +
		"More runners are available. Use --json to continue with the returned cursor.\n"
	if stdout.String() != want {
		t.Fatalf("output = %q, want %q", stdout.String(), want)
	}
	for _, unwanted := range []string{"Item 1", "Observed at", "OK  Yes", "opaque"} {
		if strings.Contains(stdout.String(), unwanted) {
			t.Errorf("human output retained %q:\n%s", unwanted, stdout.String())
		}
	}
}

func TestCLIListPacksSummarizesInsteadOfDumpingActions(t *testing.T) {
	actions := make([]map[string]string, 119)
	for index := range actions {
		actions[index] = map[string]string{
			"action_id":    fmt.Sprintf("postgres.action_%03d", index+1),
			"availability": "executable",
			"title":        "Action title that belongs in find_actions",
		}
	}
	raw, err := json.Marshal(map[string]any{
		"ok": true,
		"packs": []any{
			map[string]any{
				"pack_ref":     "postgres@1.2.3/sha256:abc",
				"availability": "executable",
				"issues":       []any{},
				"actions":      actions,
			},
		},
		"observed_at": "2026-08-21T02:45:31Z",
		"next_cursor": nil,
	})
	if err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	if err := writeCLIToolOutput(&stdout, listPacksToolName, json.RawMessage(`{}`), raw, "", false, true); err != nil {
		t.Fatal(err)
	}
	want := "1 pack\n\npostgres 1.2.3 — executable\n  119 executable actions\n  Pack ref  postgres@1.2.3/sha256:abc\n" +
		"  Actions  emisar-mcp find_actions '{\"pack_ref\":\"postgres@1.2.3/sha256:abc\"}'\n"
	if stdout.String() != want {
		t.Fatalf("output = %q, want %q", stdout.String(), want)
	}
	if strings.Contains(stdout.String(), "postgres.action_") || strings.Contains(stdout.String(), "Item 119") {
		t.Fatalf("pack inventory dumped its action catalog:\n%s", stdout.String())
	}
}

func TestCLIListPacksActionsCommandPreservesAccountAndRejectsUnsafeRefs(t *testing.T) {
	want := `emisar-mcp --account immersive find_actions '{"pack_ref":"postgres@1.2.3/sha256:abc"}'`
	if got := cliFleetPackActionsCommandForOS("postgres@1.2.3/sha256:abc", "immersive", "linux"); got != want {
		t.Fatalf("command = %q, want %q", got, want)
	}
	for _, packRef := range []string{"", "postgres@1/sha256:safe\u202espoof"} {
		if got := cliFleetPackActionsCommandForOS(packRef, "", "linux"); got != "" {
			t.Fatalf("unsafe pack ref %q rendered as %q", packRef, got)
		}
	}
}

func TestCLIListPacksExplainsEmptyHumanViews(t *testing.T) {
	raw := json.RawMessage(`{"ok":true,"packs":[],"next_cursor":null}`)
	tests := []struct {
		name      string
		arguments json.RawMessage
		account   string
		want      string
	}{
		{
			name:      "default executable view",
			arguments: json.RawMessage(`{}`),
			want:      "No executable packs found.\n\nUse `emisar-mcp list_packs '{\"availability\":\"all\"}'` to include trusted unavailable packs.\n",
		},
		{
			name:      "all view",
			arguments: json.RawMessage(`{"availability":"all"}`),
			want:      "No trusted packs found.\n",
		},
		{
			name:      "selected account",
			arguments: json.RawMessage(`{}`),
			account:   "immersive",
			want:      "No executable packs found.\n\nUse `emisar-mcp --account immersive list_packs '{\"availability\":\"all\"}'` to include trusted unavailable packs.\n",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var stdout bytes.Buffer
			if err := writeCLIToolOutput(&stdout, listPacksToolName, test.arguments, raw, test.account, false, true); err != nil {
				t.Fatal(err)
			}
			if stdout.String() != test.want {
				t.Fatalf("output = %q, want %q", stdout.String(), test.want)
			}
		})
	}
}

func TestCLIFindActionsUsesActionPreviewsAndAnInspectCommand(t *testing.T) {
	raw := json.RawMessage(`{
		"ok":true,
		"candidates":[
			{
				"action_id":"postgres.replication_status",
				"pack_ref":"postgres@1.2.3/sha256:abc",
				"title":"Check replication status",
				"summary":"Show replica state and lag without changing the database.",
				"risk":"low",
				"side_effects":["Read-only."],
				"matched_fields":["title"],
				"next":{"tool":"get_action","arguments":{"action_id":"postgres.replication_status","pack_ref":"postgres@1.2.3/sha256:abc","target":"primary"}}
			}
		],
		"next":null,
		"observed_at":"2026-08-21T02:45:31Z"
	}`)
	var stdout bytes.Buffer
	if err := writeCLIToolOutput(
		&stdout,
		findActionsToolName,
		json.RawMessage(`{"query":"postgres replication"}`),
		raw,
		"",
		false,
		true,
	); err != nil {
		t.Fatal(err)
	}
	want := "1 action found for \"postgres replication\".\n\n" +
		"postgres.replication_status — Check replication status\n" +
		"  Show replica state and lag without changing the database.\n" +
		"  low risk · pack postgres@1.2.3/sha256:abc\n" +
		"  Inspect  emisar-mcp get_action '{\"action_id\":\"postgres.replication_status\",\"pack_ref\":\"postgres@1.2.3/sha256:abc\",\"target\":\"primary\"}'\n"
	if stdout.String() != want {
		t.Fatalf("output = %q, want %q", stdout.String(), want)
	}
	for _, unwanted := range []string{"Matched fields", "Observed at", "Side effects", "Next"} {
		if strings.Contains(stdout.String(), unwanted) {
			t.Errorf("search preview retained %q:\n%s", unwanted, stdout.String())
		}
	}
}

func TestCLIFleetFormattingCannotEmitTerminalControls(t *testing.T) {
	raw := json.RawMessage(`{
		"ok":true,
		"summary":{"connected":1,"disconnected":0,"pending":0,"disabled":0,"matched":1},
		"runners":[{
			"name":"db\n\u001b[31mred\u202espoof",
			"status":"connected",
			"hostname":"host\u2028name",
			"labels":{"env\u001b":"prod\nwest"},
			"packs":[],
			"runner_ref":"db~0123456789abcdef0123456789abcdef",
			"issues":[{"message":"first\nsecond\u001b[2J"}]
		}],
		"next_cursor":null
	}`)
	var stdout bytes.Buffer
	if err := writeCLIToolOutput(&stdout, listRunnersToolName, json.RawMessage(`{}`), raw, "", false, true); err != nil {
		t.Fatal(err)
	}
	body := strings.TrimSuffix(stdout.String(), "\n")
	for _, control := range []string{"\n\u001b", "\u001b", "\u2028", "\u202e"} {
		if strings.Contains(body, control) {
			t.Fatalf("human output retained terminal control %q: %q", control, stdout.String())
		}
	}
	if !strings.Contains(stdout.String(), "db [31mred spoof") ||
		!strings.Contains(stdout.String(), "first second [2J") {
		t.Fatalf("sanitized content is missing: %q", stdout.String())
	}
}

func TestCLIFleetOmitsTerminalHostileContinuation(t *testing.T) {
	next := cliFleetNext{
		Tool:      "get_action",
		Arguments: json.RawMessage(`{"action_id":"safe` + string(rune(0x202e)) + `vil","pack_ref":"postgres@1/sha256:abc"}`),
	}
	if command := cliFleetNextCommandForOS(next, "get_action", "", "darwin"); command != "" {
		t.Fatalf("hostile continuation rendered as %q", command)
	}
}

func TestCLIFleetContinuationUsesPowerShellQuoting(t *testing.T) {
	next := cliFleetNext{
		Tool: "get_action",
		Arguments: json.RawMessage(
			`{"action_id":"postgres.read","pack_ref":"postgres@1/sha256:abc","target":"operator's database"}`,
		),
	}
	want := `emisar-mcp --account immersive get_action '{"action_id":"postgres.read","pack_ref":"postgres@1/sha256:abc","target":"operator''s database"}'`
	if command := cliFleetNextCommandForOS(next, "get_action", "immersive", "windows"); command != want {
		t.Fatalf("PowerShell continuation = %q, want %q", command, want)
	}
}

func TestCLIFleetRejectsMismatchedContinuationArguments(t *testing.T) {
	runner := cliFleetRunner{
		RunnerRef: "db-01~0123456789abcdef0123456789abcdef",
		PacksNext: cliFleetNext{
			Tool:      listPacksToolName,
			Arguments: json.RawMessage(`{"runner_refs":["db-02~abcdef0123456789abcdef0123456789"],"availability":"all"}`),
		},
	}
	if command := cliFleetRunnerPacksCommand(runner, ""); command != "" {
		t.Fatalf("mismatched runner continuation rendered as %q", command)
	}

	candidate := cliFleetAction{
		ActionID: "postgres.read",
		PackRef:  "postgres@1/sha256:abc",
		Next: cliFleetNext{
			Tool:      "get_action",
			Arguments: json.RawMessage(`{"action_id":"postgres.erase","pack_ref":"postgres@1/sha256:abc"}`),
		},
	}
	if command := cliFleetActionInspectCommand(candidate, ""); command != "" {
		t.Fatalf("mismatched action continuation rendered as %q", command)
	}
}

func TestCLIFleetJSONOutputStaysExact(t *testing.T) {
	var stdout bytes.Buffer
	if err := writeCLIToolOutput(
		&stdout,
		listRunnersToolName,
		json.RawMessage(`{}`),
		json.RawMessage(cliFleetRunnersResult),
		"",
		true,
		true,
	); err != nil {
		t.Fatal(err)
	}
	if !jsonEqual(stdout.Bytes(), []byte(cliFleetRunnersResult)) {
		t.Fatalf("JSON output changed:\n%s", stdout.String())
	}
}

func TestMainCLIListRunnersUsesFleetFormattingEndToEnd(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertCLIRequestHeaders(t, r, "tools/call", listRunnersToolName)
		switch r.Header.Get(nameHeader) {
		case listRunnersToolName:
			writeCLIResult(t, w, r, `{"structuredContent":`+cliFleetRunnersResult+`,"content":[],"isError":false}`)
		case listPacksToolName:
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"packs":[],"next_cursor":null},"content":[],"isError":false}`)
		default:
			t.Errorf("unexpected tool %q", r.Header.Get(nameHeader))
		}
	}))
	defer srv.Close()

	env := map[string]string{"EMISAR_URL": srv.URL, "EMISAR_API_KEY": "e2e-token"}
	stdout, stderr, code := runMain(t, "", []string{listRunnersToolName, `{"limit":2}`}, env)
	if code != 0 || stderr != "" || !strings.HasPrefix(stdout, "Showing 2 of 3 runners") ||
		strings.Contains(stdout, "Item 1") {
		t.Fatalf("human process output: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, "", []string{listRunnersToolName, `{"limit":2}`, "--json"}, env)
	if code != 0 || stderr != "" || !jsonEqual([]byte(stdout), []byte(cliFleetRunnersResult)) {
		t.Fatalf("JSON process output: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestMainCLIFleetContinuationPreservesExplicitAccount(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	currentKey := testAPIKey(91)
	selectedKey := testAPIKey(92)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if authorization := r.Header.Get("Authorization"); authorization != "Bearer "+selectedKey {
			t.Errorf("Authorization = %q, want selected account", authorization)
		}
		switch r.Header.Get(nameHeader) {
		case listRunnersToolName:
			writeCLIResult(t, w, r, `{"structuredContent":`+cliFleetRunnersResult+`,"content":[],"isError":false}`)
		case listPacksToolName:
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"packs":[],"next_cursor":null},"content":[],"isError":false}`)
		default:
			t.Errorf("unexpected tool %q", r.Header.Get(nameHeader))
		}
	}))
	defer srv.Close()

	storeTestCLIAccount(t, configDir, srv.URL, blitzAccountID, "blitz", "Blitz", currentKey, true)
	storeTestCLIAccount(t, configDir, srv.URL, immersiveAccountID, "immersive", "Immersive", selectedKey, false)

	stdout, stderr, code := runMain(
		t,
		"",
		[]string{"--account", "immersive", listRunnersToolName, `{"limit":2}`},
		configEnv,
	)
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "See packs  emisar-mcp --account immersive list_packs") {
		t.Fatalf("continuation lost account selector:\n%s", stdout)
	}
	stdout, stderr, code = runMain(
		t,
		"",
		[]string{"--account", "immersive", listPacksToolName},
		configEnv,
	)
	if code != 0 || stderr != "" ||
		!strings.Contains(stdout, "Use `emisar-mcp --account immersive list_packs") {
		t.Fatalf("empty-pack suggestion lost account selector: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	_, current, err := loadCLICredential("")
	if err != nil || current.AccountID != blitzAccountID {
		t.Fatalf("one-command selection changed current account: %#v, %v", current, err)
	}
}

func TestMainCLIFleetDoesNotRenderUnexpectedContinuationTools(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Header.Get(nameHeader) {
		case listRunnersToolName:
			writeCLIResult(t, w, r, `{"structuredContent":{
				"ok":true,
				"summary":{"connected":1,"disconnected":0,"pending":0,"disabled":0,"matched":1},
				"runners":[{
					"name":"db-01",
					"status":"connected",
					"runner_ref":"db-01~0123456789abcdef0123456789abcdef",
					"packs":[],
					"packs_next":{"tool":"run_action","arguments":{"runner_refs":["db-01~0123456789abcdef0123456789abcdef"]}},
					"issues":[]
				}],
				"next_cursor":null
			},"content":[],"isError":false}`)
		case findActionsToolName:
			writeCLIResult(t, w, r, `{"structuredContent":{
				"ok":true,
				"candidates":[{
					"action_id":"postgres.read",
					"pack_ref":"postgres@1/sha256:abc",
					"title":"Read Postgres state",
					"summary":"Inspect the database without changing it.",
					"risk":"low",
					"next":{"tool":"run_action","arguments":{"action_id":"postgres.read","pack_ref":"postgres@1/sha256:abc"}}
				}],
				"next":null
			},"content":[],"isError":false}`)
		default:
			t.Errorf("unexpected tool %q", r.Header.Get(nameHeader))
		}
	}))
	defer srv.Close()

	env := map[string]string{"EMISAR_URL": srv.URL, "EMISAR_API_KEY": "e2e-token"}
	for _, args := range [][]string{
		{listRunnersToolName},
		{findActionsToolName, "postgres state"},
	} {
		stdout, stderr, code := runMain(t, "", args, env)
		if code != 0 || stderr != "" {
			t.Fatalf("%s: exit=%d stdout=%q stderr=%q", args[0], code, stdout, stderr)
		}
		if strings.Contains(stdout, "run_action") {
			t.Fatalf("%s rendered unexpected mutation continuation:\n%s", args[0], stdout)
		}
	}
}
