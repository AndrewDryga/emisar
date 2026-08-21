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

func TestCLIFixedToolsHavePurposeBuiltHumanOutput(t *testing.T) {
	tests := []struct {
		name      string
		tool      string
		arguments string
		result    string
		want      []string
		wantNone  []string
	}{
		{
			name:   "action detail",
			tool:   getActionToolName,
			result: `{"ok":true,"action":{"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","title":"Postgres status","description":"Inspect replication health.","risk":"low","side_effects":["Reads replication state.","No changes are made."],"args_schema":{"type":"object","required":["database"],"properties":{"database":{"type":"string","description":"Database name."}}},"examples":[{"title":"Primary database","args":{"database":"primary"}}]},"compatible_runners":[{"runner_ref":"db-1~abc","name":"db-1","hostname":"db-1.local","group":"database","status":"connected","enforce_signatures":true}],"more_compatible_runners":false}`,
			want: []string{
				"Postgres status", "postgres.status · low risk", "Side effects", "- Reads replication state.",
				"- No changes are made.", "database — string, required", "Run\n  emisar-mcp run_action", "Compatible runners (1)",
				"database (1)", "db-1 — connected — db-1~abc · signed dispatch required",
				`emisar-mcp run_action '{"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runner_refs":["<runner-ref>"],"args":<arguments-json>,"reason":"<reason>"}'`,
			},
			wantNone: []string{`"runner_refs":["db-1~abc"]`, `"args":{"database":"primary"}`, "Action example: Primary database", "db-1.local · group database", "Runner ref"},
		},
		{
			name:   "action result",
			tool:   runActionToolName,
			result: `{"ok":true,"operation_id":"op-1","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runs":[{"run_id":"run-1","operation_id":"op-1","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runner_ref":"db-1~abc","status":"success","exit_code":0,"duration_ms":1250,"stdout":"primary\nhealthy","structured_output":{"role":"primary"}}]}`,
			want:   []string{"Action completed on 1 runner", "Operation ID  op-1", `Inspect       emisar-mcp get_operation '{"operation_id":"op-1"}'`, "db-1~abc — success", "Exit code  0", "Output\n    primary\n    healthy", "Result\n    {\n      \"role\": \"primary\""},
		},
		{
			name:   "operation recovery",
			tool:   getOperationToolName,
			result: `{"ok":true,"operation":{"operation_id":"op-1","kind":"action","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","next":{"tool":"recent_runs","arguments":{"operation_id":"op-1"}}}}`,
			want:   []string{"Operation found", "Operation ID  op-1", "Kind  action", "Next  emisar-mcp recent_runs"},
		},
		{
			name:   "run wait",
			tool:   waitForRunToolName,
			result: `{"ok":true,"run":{"run_id":"run-1","runner_ref":"db-1~abc","status":"pending_approval","approval":{"request_id":"approval-1","url":"https://emisar.dev/app/demo/approvals/approval-1","expires_at":"2026-08-21T04:00:00Z"}}}`,
			want:   []string{"db-1~abc — pending approval", "Run ID  run-1", "Approval  https://emisar.dev/app/demo/approvals/approval-1"},
		},
		{
			name:   "recent runs",
			tool:   recentRunsToolName,
			result: `{"ok":true,"runs":[{"run_id":"run-1","runner_ref":"db-1~abc","status":"failed","error_message":"command failed"}],"next_cursor":"cursor"}`,
			want:   []string{"1 recent run", "db-1~abc — failed", "Error  command failed", "More runs are available"},
		},
		{
			name:      "runbook list",
			tool:      listRunbooksToolName,
			arguments: `{"query":"database"}`,
			result:    `{"ok":true,"runbooks":[{"slug":"database-check","title":"Database check","summary":"Inspect database health.","available":true,"live":{"runbook_ref":"database-check@3","definition_sha256":"sha256:live"},"draft":{"definition_sha256":"sha256:draft"},"input_count":1,"stage_count":2,"step_count":3}],"next_cursor":null}`,
			want: []string{
				"1 runbook", "Database check", "database-check", "1 input · 2 stages · 3 steps", "Live  database-check@3",
				`Inspect live  emisar-mcp get_runbook '{"slug":"database-check","status":"published"}'`,
				"Draft  unpublished changes", `Inspect draft  emisar-mcp get_runbook '{"slug":"database-check","status":"draft"}'`,
			},
		},
		{
			name:   "runbook detail",
			tool:   getRunbookToolName,
			result: `{"ok":true,"runbook":{"runbook_ref":"database-check@3","status":"published","definition_sha256":"sha256:live","title":"Database check","description":"Inspect database health.","summary":{"input_count":0,"stage_count":1,"step_count":1},"definition":{"schema_version":1,"inputs":[],"stages":[{"id":"inspect","title":"Inspect","mode":"sequential","steps":[{"id":"status","action":"postgres.status","pack":{"id":"postgres"},"targets":{"selection":"random_one","refs":["group:database"]},"args":{"database":{"source":"literal","value":"primary"},"previous":{"source":"output","ref":"discover.database"},"threshold":{"source":"input","ref":"lag_threshold"}}}]}]}}}`,
			want: []string{
				"Database check", "database-check@3 · published", "0 inputs · 1 stage · 1 step", "Workflow",
				"1. Inspect — sequential, 1 step", "status — postgres.status",
				"Pack postgres · Target one of group:database",
				"Args database=primary · previous=output:discover.database · threshold=input:lag_threshold",
				"Run\n  emisar-mcp execute_runbook",
				`emisar-mcp execute_runbook '{"runbook_ref":"database-check@3","reason":"<reason>","input_values":<input-values-json>}'`,
			},
		},
		{
			name:   "runbook execution",
			tool:   executeRunbookToolName,
			result: `{"ok":true,"operation_id":"op-2","execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[{"stage_id":"inspect","title":"Inspect","mode":"sequential","status":"succeeded","items":[{"id":"item-1","step_id":"status","runner_ref":"db-1~abc","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","risk":"low","attempt_count":1,"outputs":[{"output_id":"role","source":"structured","sensitive":false,"status":"captured","value":"primary"}],"output_count":1}]}]}}`,
			want:   []string{"Runbook execution started", "Operation ID  op-2", `Inspect       emisar-mcp get_operation '{"operation_id":"op-2"}'`, "database-check@3 — succeeded", "Inspect — succeeded", "status on db-1~abc — succeeded", "postgres.status · low risk", "Output role — captured", "\"primary\""},
		},
		{
			name:   "draft",
			tool:   createRunbookDraftToolName,
			result: `{"ok":true,"operation_id":"op-3","draft_id":"draft-1","slug":"database-check","status":"draft","definition_sha256":"sha256:draft","live_ref":"database-check@3","review_url":"https://emisar.dev/app/demo/runbooks/draft-1/edit"}`,
			want:   []string{"Draft saved", "Runbook      database-check", "Operation ID  op-3", `Inspect       emisar-mcp get_operation '{"operation_id":"op-3"}'`, "Review  https://emisar.dev/app/demo/runbooks/draft-1/edit", "not live until an operator reviews"},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			arguments := test.arguments
			if arguments == "" {
				arguments = `{}`
			}
			var stdout bytes.Buffer
			if err := writeCLIToolOutput(&stdout, test.tool, []byte(arguments), []byte(test.result), "", false, true); err != nil {
				t.Fatal(err)
			}
			output := stdout.String()
			for _, want := range test.want {
				if !strings.Contains(output, want) {
					t.Errorf("output missing %q:\n%s", want, output)
				}
			}
			for _, unwanted := range test.wantNone {
				if strings.Contains(output, unwanted) {
					t.Errorf("output contains %q:\n%s", unwanted, output)
				}
			}
			if strings.Contains(output, "OK  Yes") || strings.Contains(output, "Item 1 of") {
				t.Errorf("fixed tool fell back to generic object rendering:\n%s", output)
			}
		})
	}
}

func TestCLIActionStatusesMatchPortalContract(t *testing.T) {
	tests := []struct {
		status   string
		terminal bool
		failed   bool
	}{
		{"pending", false, false},
		{"pending_approval", false, false},
		{"sent", false, false},
		{"running", false, false},
		{"cancelling", false, false},
		{"success", true, false},
		{"failed", true, true},
		{"error", true, true},
		{"validation_failed", true, true},
		{"unknown_action", true, true},
		{"cancelled", true, true},
		{"timed_out", true, true},
		{"refused", true, true},
		{"denied", true, true},
	}

	for _, test := range tests {
		t.Run(test.status, func(t *testing.T) {
			if got := cliRunTerminal(test.status); got != test.terminal {
				t.Errorf("cliRunTerminal(%q) = %t, want %t", test.status, got, test.terminal)
			}
			if got := cliRunFailed(test.status); got != test.failed {
				t.Errorf("cliRunFailed(%q) = %t, want %t", test.status, got, test.failed)
			}
		})
	}
}

func TestCLIProcessRendersArrayBackedActionSideEffects(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"action":{"action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","title":"System uptime","description":"Show uptime.","risk":"low","side_effects":["Reads host state.","Makes no changes."],"args_schema":{"type":"object","properties":{}},"examples":[{"title":"Get uptime and load","args":{}}]},"compatible_runners":[{"runner_ref":"host-1~abc","name":"host-1","status":"connected","enforce_signatures":false}],"more_compatible_runners":false},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	env := map[string]string{"EMISAR_URL": srv.URL, "EMISAR_API_KEY": "e2e-token"}
	stdout, stderr, code := runMain(t, "", []string{getActionToolName, `{}`}, env)
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	for _, want := range []string{
		"System uptime", "Side effects", "- Reads host state.", "- Makes no changes.", "Compatible runners (1)",
		`Run
  emisar-mcp run_action '{"action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","runner_refs":["<runner-ref>"],"args":<arguments-json>,"reason":"<reason>"}'`,
		"Ungrouped (1)", "host-1 — connected — host-1~abc",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, stdout)
		}
	}
	for _, unwanted := range []string{`"runner_refs":["host-1~abc"]`, `"args":{}`, "Action example: Get uptime and load"} {
		if strings.Contains(stdout, unwanted) {
			t.Fatalf("process output retained default %q:\n%s", unwanted, stdout)
		}
	}
	if strings.Contains(stdout, "OK  Yes") {
		t.Fatalf("process output fell back to the generic renderer:\n%s", stdout)
	}
}

func TestCLIActionRunTemplatePreservesAccount(t *testing.T) {
	raw := []byte(`{"ok":true,"action":{"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","title":"Postgres status","risk":"low","side_effects":[],"args_schema":{"type":"object"},"examples":[{"title":"Inspect primary database","args":{"threshold":9007199254740993}}]},"compatible_runners":[{"runner_ref":"db-1~abc","name":"db-1","status":"connected"}],"more_compatible_runners":false}`)
	var stdout bytes.Buffer
	if err := writeCLIToolOutput(&stdout, getActionToolName, json.RawMessage(`{}`), raw, "immersive", false, true); err != nil {
		t.Fatal(err)
	}

	want := `emisar-mcp --account immersive run_action '{"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runner_refs":["<runner-ref>"],"args":<arguments-json>,"reason":"<reason>"}'`
	if !strings.Contains(stdout.String(), want) {
		t.Fatalf("output missing %q:\n%s", want, stdout.String())
	}
}

func TestCLIActionRunTemplateQuotesPowerShellData(t *testing.T) {
	action := cliActionDetail{
		ActionID: "postgres.status",
		PackRef:  "postgres@O'Brien/sha256:abc",
	}

	want := `emisar-mcp --account 'north star' run_action '{"action_id":"postgres.status","pack_ref":"postgres@O''Brien/sha256:abc","runner_refs":["<runner-ref>"],"args":<arguments-json>,"reason":"<reason>"}'`
	if got := cliActionRunTemplateForOS(action, "north star", "windows"); got != want {
		t.Fatalf("command = %q, want %q", got, want)
	}
}

func TestCLIActionRunTemplateFailsClosedOnUnsafeIdentity(t *testing.T) {
	validAction := cliActionDetail{
		ActionID: "linux.uptime",
		PackRef:  "linux@1/sha256:abc",
	}

	tests := []struct {
		name   string
		action cliActionDetail
	}{
		{name: "missing action id", action: cliActionDetail{PackRef: validAction.PackRef}},
		{name: "missing pack ref", action: cliActionDetail{ActionID: validAction.ActionID}},
		{name: "unsafe action id", action: cliActionDetail{ActionID: "linux.\u202euptime", PackRef: validAction.PackRef}},
		{name: "unsafe pack ref", action: cliActionDetail{ActionID: validAction.ActionID, PackRef: "linux@1/sha256:\u202eabc"}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := cliActionRunTemplateForOS(test.action, "", "linux"); got != "" {
				t.Fatalf("unsafe command rendered as %q", got)
			}
		})
	}
}

func TestCLIOperationInspectCommandPreservesAccountAndQuotesPowerShell(t *testing.T) {
	want := `emisar-mcp --account 'north star' get_operation '{"operation_id":"op_O''Brien"}'`
	if got := cliOperationInspectCommandForOS("op_O'Brien", "north star", "windows"); got != want {
		t.Fatalf("command = %q, want %q", got, want)
	}
	for _, operationID := range []string{"", "op_safe\u202espoof"} {
		if got := cliOperationInspectCommandForOS(operationID, "", "linux"); got != "" {
			t.Fatalf("unsafe operation %q rendered as %q", operationID, got)
		}
	}
}

func TestCLIRunbookInspectCommandPreservesAccountAndRejectsUnsafeIdentity(t *testing.T) {
	want := `emisar-mcp --account immersive get_runbook '{"slug":"database-check","status":"draft"}'`
	if got := cliRunbookInspectCommandForOS("database-check", "draft", "immersive", "linux"); got != want {
		t.Fatalf("command = %q, want %q", got, want)
	}
	for _, test := range []struct {
		slug   string
		status string
	}{
		{slug: "", status: "published"},
		{slug: "safe\u202espoof", status: "published"},
		{slug: "database-check", status: "other"},
	} {
		if got := cliRunbookInspectCommandForOS(test.slug, test.status, "", "linux"); got != "" {
			t.Fatalf("unsafe runbook identity %#v rendered as %q", test, got)
		}
	}
}

func TestCLIGetRunbookDraftUsesExactEditableExecutionTemplate(t *testing.T) {
	raw := []byte(`{"ok":true,"runbook":{"slug":"database-check","draft_id":"draft-1","status":"draft","definition_sha256":"abc123","title":"Database check","description":"Inspect database health.","summary":{"input_count":1,"stage_count":1,"step_count":1},"definition":{"schema_version":1,"inputs":[{"id":"target","name":"Target","type":"string","required":true}],"stages":[]},"live_ref":"database-check@3"}}`)
	var stdout bytes.Buffer
	if err := writeCLIToolOutput(&stdout, getRunbookToolName, json.RawMessage(`{}`), raw, "immersive", false, true); err != nil {
		t.Fatal(err)
	}
	want := `emisar-mcp --account immersive execute_runbook '{"slug":"database-check","allow_draft":true,"definition_sha256":"abc123","reason":"<reason>","input_values":<input-values-json>}'`
	if !strings.Contains(stdout.String(), want) {
		t.Fatalf("output missing %q:\n%s", want, stdout.String())
	}
	for _, unwanted := range []string{`"runbook_ref"`, `"input_values":{}`, "Action example"} {
		if strings.Contains(stdout.String(), unwanted) {
			t.Fatalf("draft template retained %q:\n%s", unwanted, stdout.String())
		}
	}
}

func TestCLIRunbookExecuteTemplateQuotesPowerShellAndRejectsUnsafeIdentity(t *testing.T) {
	published := cliRunbookDetail{Status: "published", RunbookRef: "database-check@3"}
	want := `emisar-mcp --account 'north star' execute_runbook '{"runbook_ref":"database-check@3","reason":"<reason>","input_values":<input-values-json>}'`
	if got := cliRunbookExecuteTemplateForOS(published, "north star", "windows"); got != want {
		t.Fatalf("command = %q, want %q", got, want)
	}

	for _, runbook := range []cliRunbookDetail{
		{Status: "published"},
		{Status: "published", RunbookRef: "safe@1\u202espoof"},
		{Status: "draft", Slug: "database-check"},
		{Status: "draft", Slug: "safe\u202espoof", DefinitionSHA256: "abc123"},
		{Status: "other", RunbookRef: "database-check@3"},
	} {
		if got := cliRunbookExecuteTemplateForOS(runbook, "", "linux"); got != "" {
			t.Fatalf("unsafe runbook %#v rendered as %q", runbook, got)
		}
	}
}

func TestCLIRunbookStepDetailsAreBoundedAndTerminalSafe(t *testing.T) {
	arguments := map[string]cliRunbookBinding{
		"a":             {Source: "literal", Value: json.RawMessage(`9007199254740993`)},
		"b\u202eunsafe": {Source: "input", Ref: "threshold\n\x1b[31munsafe"},
		"c":             {Source: "literal", Value: json.RawMessage(`"` + strings.Repeat("x", 300) + `"`)},
		"d":             {Source: "literal", Value: json.RawMessage(`true`)},
		"e":             {Source: "output", Ref: "discover.value"},
		"f":             {Source: "literal", Value: json.RawMessage(`{"nested":"value"}`)},
		"g":             {Source: "literal", Value: json.RawMessage(`null`)},
		"h":             {Source: "literal", Value: json.RawMessage(`false`)},
	}
	got := cliRunbookStepArguments(arguments)
	for _, want := range []string{
		"a=9007199254740993",
		"b unsafe=input:threshold [31munsafe",
		"c=" + strings.Repeat("x", 160) + "…",
		`e=output:discover.value`,
		`f={"nested":"value"}`,
		"+2 more",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("arguments missing %q: %q", want, got)
		}
	}
	if strings.ContainsAny(got, "\n\r\x1b") || strings.ContainsRune(got, '\u202e') {
		t.Fatalf("arguments contain terminal control characters: %q", got)
	}
	if len([]rune(got)) > maxCLIRunbookStepDetailRunes+1 {
		t.Fatalf("arguments contain %d runes, want at most %d plus ellipsis", len([]rune(got)), maxCLIRunbookStepDetailRunes)
	}

	var step cliRunbookStep
	if err := json.Unmarshal([]byte(`{
		"pack":{"id":"victoria\u001bmetrics"},
		"targets":{"selection":"random_one","refs":["group:a","group:b","group:c","group:d","group:e","group:f"]}
	}`), &step); err != nil {
		t.Fatal(err)
	}
	context := cliRunbookStepContext(step)
	if want := "Pack victoria metrics · Target one of group:a, group:b, group:c, group:d +2 more"; context != want {
		t.Fatalf("context = %q, want %q", context, want)
	}
}

func TestCLICompatibleRunnersGroupOnceInFirstSeenOrder(t *testing.T) {
	runners := []cliCompatibleRunner{
		{Name: "db-1", RunnerRef: "db-1~abc", Group: "database"},
		{Name: "web-1", RunnerRef: "web-1~abc", Group: "web"},
		{Name: "db-2", RunnerRef: "db-2~abc", Group: "database"},
		{Name: "other-1", RunnerRef: "other-1~abc", Group: "\u202e"},
	}

	groups := groupCLICompatibleRunners(runners)
	if len(groups) != 3 {
		t.Fatalf("groups = %#v", groups)
	}
	if groups[0].Name != "database" || len(groups[0].Runners) != 2 ||
		groups[0].Runners[0].Name != "db-1" || groups[0].Runners[1].Name != "db-2" {
		t.Fatalf("database group = %#v", groups[0])
	}
	if groups[1].Name != "web" || groups[1].Runners[0].Name != "web-1" {
		t.Fatalf("web group = %#v", groups[1])
	}
	if groups[2].Name != "Ungrouped" || groups[2].Runners[0].Name != "other-1" {
		t.Fatalf("unsafe group = %#v", groups[2])
	}
}

func TestCLIHumanSuccessfulActionStatusExitsZero(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		operationID := r.Header.Get(operationIDHeader)
		writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","runs":[{"run_id":"run-1","operation_id":%q,"action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","runner_ref":"host-1~abc","status":"success","exit_code":0,"stdout":"up 12 days"}]},"content":[],"isError":false}`, operationID, operationID))
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{runActionToolName, `{}`}, "")
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "host-1~abc — success") || !strings.Contains(stdout, "up 12 days") {
		t.Fatalf("unexpected successful action output:\n%s", stdout)
	}
}

func TestCLIToolErrorsExplainFailureAndSafeRecovery(t *testing.T) {
	raw := []byte(`{"ok":false,"dispatch_started":true,"error":{"code":"target_contract_changed","message":"The selected contract changed.","retryable":true,"next":{"tool":"get_action","arguments":{"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc"}}}}`)
	var stdout bytes.Buffer
	if err := writeCLIToolOutput(&stdout, runActionToolName, nil, raw, "immersive", false, false); err != nil {
		t.Fatal(err)
	}
	output := stdout.String()
	for _, want := range []string{
		"Error: The selected contract changed.",
		"Code  target_contract_changed",
		"The mutation may have started. Recover it before retrying.",
		`Next  emisar-mcp --account immersive get_action`,
	} {
		if !strings.Contains(output, want) {
			t.Errorf("output missing %q:\n%s", want, output)
		}
	}
}

func TestCLIToolValidationErrorsExplainFieldsWithoutEchoingValues(t *testing.T) {
	arguments := []byte(`{"reason":"cli test","runner_refs":["secret-runner"],"scope":"global"}`)
	raw := []byte(`{"ok":false,"dispatch_started":false,"error":{"code":"invalid_args","message":"Tool arguments do not match the published input schema.","retryable":false,"details":{"schema_version":1,"stage":"arguments","kind":"range","issues":[{"path":"$.reason","code":"min"},{"path":"$.runner_refs","code":"max_items"},{"path":"$.scope","code":"enum"},{"path":"$.missing","code":"required"}]}}}`)
	var stdout bytes.Buffer
	if err := writeCLIToolOutput(&stdout, executeRunbookToolName, arguments, raw, "immersive", false, false); err != nil {
		t.Fatal(err)
	}
	output := stdout.String()
	for _, want := range []string{
		"Error: Tool arguments do not match the published input schema.",
		"Code  invalid_args",
		"Problems",
		"reason  Is shorter than the allowed minimum.",
		"runner_refs  Contains too many items.",
		"scope  Is not one of the allowed values.",
		"missing  Is required.",
		"View the accepted arguments and constraints:",
		"emisar-mcp --account immersive help execute_runbook",
	} {
		if !strings.Contains(output, want) {
			t.Errorf("output missing %q:\n%s", want, output)
		}
	}
	for _, unwanted := range []string{"cli test", "secret-runner", "More details are available"} {
		if strings.Contains(output, unwanted) {
			t.Errorf("output contains submitted value or stale fallback %q:\n%s", unwanted, output)
		}
	}

	stdout.Reset()
	if err := writeCLIToolOutput(&stdout, executeRunbookToolName, arguments, raw, "immersive", true, false); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stdout.String(), `"path": "$.reason"`) || !strings.Contains(stdout.String(), `"code": "min"`) {
		t.Fatalf("exact JSON lost validation details:\n%s", stdout.String())
	}
}

func TestCLIToolErrorIssuesAreBoundedAndTerminalSafe(t *testing.T) {
	issues := make([]cliErrorIssue, 10)
	for index := range issues {
		issues[index] = cliErrorIssue{
			Path:    fmt.Sprintf("/stages/0/steps/%d\n\x1b[31m\u202e", index),
			Code:    "invalid_definition",
			Message: "Fix this field.\n\x1b[31m\u202e",
		}
	}
	details, err := json.Marshal(map[string]any{
		"issue_count":      10,
		"issues_truncated": false,
		"issues":           issues,
	})
	if err != nil {
		t.Fatal(err)
	}
	var out strings.Builder
	if !writeCLIErrorIssues(&out, nil, details) {
		t.Fatal("expected issue details to render")
	}
	output := out.String()
	if strings.Count(output, "Fix this field.") != maxCLIErrorIssues {
		t.Fatalf("rendered issue count = %d, want %d:\n%s", strings.Count(output, "Fix this field."), maxCLIErrorIssues, output)
	}
	if !strings.Contains(output, "2 more problems; use --json for the complete report.") {
		t.Fatalf("output omitted bounded-report notice:\n%s", output)
	}
	for _, unsafe := range []string{"\n\x1b", "\x1b", "\u202e"} {
		if strings.Contains(output, unsafe) {
			t.Fatalf("output retained unsafe terminal text %q:\n%s", unsafe, output)
		}
	}
}

func TestCLIPurposeBuiltOutputSanitizesHostileTerminalText(t *testing.T) {
	raw := []byte(`{"ok":true,"runs":[{"run_id":"run-1","runner_ref":"safe\u001b[31m\u202evil","status":"failed","error_message":"bad\nnews\u0007"}],"next_cursor":null}`)
	var stdout bytes.Buffer
	if err := writeCLIToolOutput(&stdout, recentRunsToolName, nil, raw, "", false, true); err != nil {
		t.Fatal(err)
	}
	for _, unsafe := range []string{"\x1b", "\a", "\u202e"} {
		if strings.Contains(stdout.String(), unsafe) {
			t.Fatalf("output retained unsafe terminal text %q:\n%s", unsafe, stdout.String())
		}
	}
}
