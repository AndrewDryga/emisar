package main

import (
	"bytes"
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
	}{
		{
			name:   "action detail",
			tool:   getActionToolName,
			result: `{"ok":true,"action":{"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","title":"Postgres status","description":"Inspect replication health.","risk":"low","side_effects":["Reads replication state.","No changes are made."],"args_schema":{"type":"object","required":["database"],"properties":{"database":{"type":"string","description":"Database name."}}}},"compatible_runners":[{"runner_ref":"db-1~abc","name":"db-1","hostname":"db-1.local","group":"database","status":"connected","enforce_signatures":true}],"more_compatible_runners":false}`,
			want:   []string{"Postgres status", "postgres.status · low risk", "Side effects", "- Reads replication state.", "- No changes are made.", "database — string, required", "Compatible runners (1)", "db-1 — connected", "Signed dispatch required"},
		},
		{
			name:   "action result",
			tool:   runActionToolName,
			result: `{"ok":true,"operation_id":"op-1","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runs":[{"run_id":"run-1","operation_id":"op-1","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runner_ref":"db-1~abc","status":"success","exit_code":0,"duration_ms":1250,"stdout":"primary\nhealthy","structured_output":{"role":"primary"}}]}`,
			want:   []string{"Action completed on 1 runner", "Operation ID  op-1", "db-1~abc — success", "Exit code  0", "Output\n    primary\n    healthy", "Result\n    {\n      \"role\": \"primary\""},
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
			want:      []string{"1 runbook", "Database check", "database-check", "1 input · 2 stages · 3 steps", "Live  database-check@3", "Draft  unpublished changes"},
		},
		{
			name:   "runbook detail",
			tool:   getRunbookToolName,
			result: `{"ok":true,"runbook":{"runbook_ref":"database-check@3","status":"published","definition_sha256":"sha256:live","title":"Database check","description":"Inspect database health.","summary":{"input_count":0,"stage_count":1,"step_count":1},"definition":{"schema_version":1,"inputs":[],"stages":[{"id":"inspect","title":"Inspect","mode":"sequential","steps":[{"id":"status","action":"postgres.status","pack":{"id":"postgres"}}]}]}}}`,
			want:   []string{"Database check", "database-check@3 · published", "0 inputs · 1 stage · 1 step", "Workflow", "1. Inspect — sequential, 1 step", "status — postgres.status"},
		},
		{
			name:   "runbook execution",
			tool:   executeRunbookToolName,
			result: `{"ok":true,"operation_id":"op-2","execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[{"stage_id":"inspect","title":"Inspect","mode":"sequential","status":"succeeded","items":[{"id":"item-1","step_id":"status","runner_ref":"db-1~abc","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","risk":"low","attempt_count":1,"outputs":[{"output_id":"role","source":"structured","sensitive":false,"status":"captured","value":"primary"}],"output_count":1}]}]}}`,
			want:   []string{"Runbook execution started", "Operation ID  op-2", "database-check@3 — succeeded", "Inspect — succeeded", "status on db-1~abc — succeeded", "postgres.status · low risk", "Output role — captured", "\"primary\""},
		},
		{
			name:   "draft",
			tool:   createRunbookDraftToolName,
			result: `{"ok":true,"operation_id":"op-3","draft_id":"draft-1","slug":"database-check","status":"draft","definition_sha256":"sha256:draft","live_ref":"database-check@3","review_url":"https://emisar.dev/app/demo/runbooks/draft-1/edit"}`,
			want:   []string{"Draft saved", "Runbook      database-check", "Operation ID op-3", "Review  https://emisar.dev/app/demo/runbooks/draft-1/edit", "not live until an operator reviews"},
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
		writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"action":{"action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","title":"System uptime","description":"Show uptime.","risk":"low","side_effects":["Reads host state.","Makes no changes."],"args_schema":{"type":"object","properties":{}}},"compatible_runners":[{"runner_ref":"host-1~abc","name":"host-1","status":"connected","enforce_signatures":false}],"more_compatible_runners":false},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	env := map[string]string{"EMISAR_URL": srv.URL, "EMISAR_API_KEY": "e2e-token"}
	stdout, stderr, code := runMain(t, "", []string{getActionToolName, `{}`}, env)
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	for _, want := range []string{"System uptime", "Side effects", "- Reads host state.", "- Makes no changes.", "Compatible runners (1)"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "OK  Yes") {
		t.Fatalf("process output fell back to the generic renderer:\n%s", stdout)
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
