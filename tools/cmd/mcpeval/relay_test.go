package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRelayRecordsMetadataAndNeverBearerOrArgumentValues(t *testing.T) {
	const apiKey = "emk-sentinel-secret"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if got := request.Header.Get("Authorization"); got != "Bearer "+apiKey {
			t.Errorf("authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":1,"result":{"isError":false,"structuredContent":{"ok":true,"operation_id":"op_1","runs":[{"run_id":"r1","operation_id":"op_1","runner_ref":"edge~abc","status":"success","run_url":"http://run/1"}]}}}`)
	}))
	defer upstream.Close()

	r, err := newRelay(upstream.URL, apiKey, scenario{AllowedTools: []string{"run_action"}, AllowedActions: []string{"linux.uptime"}})
	if err != nil {
		t.Fatal(err)
	}
	r.start()
	defer r.close()
	r.recorder.inspected["linux.uptime\x00linux-core@1/sha256:abc"] = true
	body := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":"linux.uptime","pack_ref":"linux-core@1/sha256:abc","runner_refs":["edge~abc"],"args":{"password":"argument-sentinel"},"reason":"reason-sentinel","evidence":"evidence-sentinel","expected":"expected-sentinel"}}}`
	response, err := http.Post(r.endpoint(), "application/json", bytes.NewBufferString(body))
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, response.Body)
	response.Body.Close()

	calls := r.recorder.snapshot()
	if len(calls) != 1 {
		t.Fatalf("calls = %d", len(calls))
	}
	if len(calls[0].RunStates) != 1 || calls[0].RunStates[0].Status != "success" || calls[0].RunStates[0].RunnerName != "edge" {
		t.Fatalf("run states = %#v", calls[0].RunStates)
	}
	if calls[0].ResponseError {
		t.Fatalf("clean run marked as error: %#v", calls[0])
	}
	// The justification chain is recorded as presence booleans only — never the
	// prose, which is asserted redacted below.
	if !calls[0].EvidencePresent || !calls[0].ExpectedPresent {
		t.Fatalf("chain presence not recorded: %#v", calls[0])
	}
	encoded, _ := json.Marshal(calls)
	for _, secret := range []string{apiKey, "argument-sentinel", "reason-sentinel", "evidence-sentinel", "expected-sentinel"} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("record leaked %q: %s", secret, encoded)
		}
	}
}

func TestRecorderRecordsChainPresenceBooleansOnly(t *testing.T) {
	r := newRecorder(scenario{AllowedTools: []string{"run_action"}, AllowedActions: []string{"linux.uptime"}})
	// A blank evidence and an absent expected both read as not-present.
	r.request([]byte(`{"id":1,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":"linux.uptime","pack_ref":"p","runner_refs":["r"],"args":{},"reason":"inspect the disk","evidence":"   "}}}`))
	call := r.snapshot()[0]
	if call.EvidencePresent || call.ExpectedPresent {
		t.Fatalf("blank/absent chain recorded as present: %#v", call)
	}
}

func TestRelayRejectsWrongPathToken(t *testing.T) {
	upstreamCalls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { upstreamCalls++ }))
	defer upstream.Close()
	r, err := newRelay(upstream.URL, "key", scenario{AllowedTools: []string{"list_runners"}, AllowedActions: []string{"linux.uptime"}})
	if err != nil {
		t.Fatal(err)
	}
	r.start()
	defer r.close()
	wrong := strings.TrimSuffix(r.endpoint(), r.token) + "guessed-token"
	response, err := http.Post(wrong, "application/json", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`))
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNotFound || upstreamCalls != 0 {
		t.Fatalf("status = %d, upstream calls = %d", response.StatusCode, upstreamCalls)
	}
}

func TestRecorderTracksPriorInspection(t *testing.T) {
	r := newRecorder(scenario{
		AllowedTools: []string{"get_action", "run_action"}, AllowedActions: []string{"linux.uptime"},
	})
	get := r.request([]byte(`{"id":1,"method":"tools/call","params":{"name":"get_action","arguments":{"action_id":"linux.uptime","pack_ref":"p"}}}`))
	r.response(get, []byte(`{"id":1,"result":{"structuredContent":{"ok":true}}}`), 200)
	run := r.request([]byte(`{"id":2,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":"linux.uptime","pack_ref":"p","runner_refs":["r"],"args":{},"reason":"inspect"}}}`))
	if run.blockCode != "" {
		t.Fatalf("run_action after a prior get_action blocked: %q", run.blockCode)
	}
	r.response(run, []byte(`{"id":2,"result":{"structuredContent":{"ok":true,"operation_id":"op_1","runs":[{"run_id":"r1","operation_id":"op_1","runner_ref":"r","status":"success"}]}}}`), 200)
	calls := r.snapshot()
	if !calls[1].priorContractMatched {
		t.Fatalf("run_action did not record inspection continuity from the prior get_action: %#v", calls[1])
	}
}

func TestRecorderBlocksRunActionWithoutPriorInspection(t *testing.T) {
	r := newRecorder(scenario{
		AllowedTools: []string{"get_action", "run_action"}, AllowedActions: []string{"linux.uptime"},
	})
	run := r.request([]byte(`{"id":1,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":"linux.uptime","pack_ref":"p","runner_refs":["r"],"args":{},"reason":"inspect"}}}`))
	if run.blockCode != "inspection_required" {
		t.Fatalf("block code = %q", run.blockCode)
	}
}

func TestRecorderRejectsMismatchedRunOperationID(t *testing.T) {
	r := newRecorder(scenario{AllowedTools: []string{"run_action"}, AllowedActions: []string{"linux.uptime"}})
	r.inspected["linux.uptime\x00p"] = true
	request := r.request([]byte(`{"id":1,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":"linux.uptime","pack_ref":"p","runner_refs":["r"],"args":{},"reason":"inspect"}}}`))
	r.response(request, []byte(`{"id":1,"result":{"structuredContent":{"ok":true,"operation_id":"op_expected","runs":[{"run_id":"r1","operation_id":"op_other","runner_ref":"r","status":"success"}]}}}`), 200)
	call := r.snapshot()[0]
	if !call.ResponseError || call.ResponseCode != "operation_id_mismatch" {
		t.Fatalf("mismatched response = %#v", call)
	}
}

func TestRelayBlocksForbiddenActionBeforeUpstream(t *testing.T) {
	upstreamCalls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		upstreamCalls++
		_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":1,"result":{}}`)
	}))
	defer upstream.Close()
	r, err := newRelay(upstream.URL, "key", scenario{
		AllowedTools: []string{"run_action"}, AllowedActions: []string{"linux.uptime"},
	})
	if err != nil {
		t.Fatal(err)
	}
	r.start()
	defer r.close()
	body := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":"linux.shutdown","pack_ref":"p","runner_refs":["r"],"args":{},"reason":"test"}}}`
	response, err := http.Post(r.endpoint(), "application/json", bytes.NewBufferString(body))
	if err != nil {
		t.Fatal(err)
	}
	denial, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if upstreamCalls != 0 {
		t.Fatalf("forbidden call reached upstream %d time(s)", upstreamCalls)
	}
	if !strings.Contains(string(denial), "evaluator_policy_denied") {
		t.Fatalf("denial body = %s", denial)
	}
	calls := r.recorder.snapshot()
	if len(calls) != 1 || !calls[0].BlockedByPolicy || calls[0].ResponseCode != "action_not_allowed" {
		t.Fatalf("blocked call = %#v", calls)
	}
}

func TestPolicyAllowsReadOnlyInspectionOfAnyAction(t *testing.T) {
	// get_action is read-only, so exploring an action outside the dispatch set
	// is legitimate discovery, not a policy breach — only run_action is gated.
	r := newRecorder(scenario{
		AllowedTools:   []string{"get_action", "run_action"},
		AllowedActions: []string{"linux.uptime"},
	})
	record := callRecord{Tool: "get_action", ActionID: "linux.mount_status", PackRef: "p"}
	if blocked := r.policyBlock(record, map[string]any{}, nil); blocked != "" {
		t.Fatalf("read-only get_action on a non-dispatch action was blocked: %q", blocked)
	}
	run := callRecord{Tool: "run_action", ActionID: "linux.mount_status", PackRef: "p"}
	if blocked := r.policyBlock(run, map[string]any{}, nil); blocked != "action_not_allowed" {
		t.Fatalf("run_action on a non-allowed action = %q, want action_not_allowed", blocked)
	}
}

func TestPolicyBlockBoundsRunnerRefsAndArgs(t *testing.T) {
	r := newRecorder(scenario{AllowedTools: []string{"run_action"}, AllowedActions: []string{"linux.uptime"}})
	r.inspected["linux.uptime\x00p"] = true
	for name, arguments := range map[string]string{
		"empty_refs":     `{"action_id":"linux.uptime","pack_ref":"p","runner_refs":[],"args":{},"reason":"x"}`,
		"duplicate_refs": `{"action_id":"linux.uptime","pack_ref":"p","runner_refs":["r","r"],"args":{},"reason":"x"}`,
		"missing_args":   `{"action_id":"linux.uptime","pack_ref":"p","runner_refs":["r"],"reason":"x"}`,
	} {
		request := r.request([]byte(`{"id":1,"method":"tools/call","params":{"name":"run_action","arguments":` + arguments + `}}`))
		if request.blockCode == "" {
			t.Errorf("%s was not blocked", name)
		}
	}
}

func TestLocalPortalURLRejectsCredentialExfiltrationTargets(t *testing.T) {
	for _, raw := range []string{"https://example.com", "http://example.com", "http://user:pass@localhost:4010", "http://localhost:4010/path"} {
		if _, err := localPortalURL(raw); err == nil {
			t.Errorf("accepted unsafe portal URL %q", raw)
		}
	}
	if got, err := localPortalURL("http://127.0.0.1:4010"); err != nil || got.Path != "/api/mcp/rpc" {
		t.Fatalf("loopback portal = %v, %v", got, err)
	}
}

func TestCollectRunStatesReadsRunsAndWaitShapes(t *testing.T) {
	runs := map[string]any{"runs": []any{map[string]any{
		"run_id": "r1", "operation_id": "op", "status": "queued", "runner_ref": "edge~abc", "run_url": "http://run/1",
	}}}
	wait := map[string]any{"run": map[string]any{"run_id": "r1", "operation_id": "op", "status": "success"}}
	for tool, structured := range map[string]map[string]any{"run_action": runs, "recent_runs": runs, "wait_for_run": wait} {
		states := collectRunStates(tool, structured)
		if len(states) != 1 || states[0].RunID != "r1" {
			t.Fatalf("%s states = %#v", tool, states)
		}
	}
	if states := collectRunStates("get_operation", runs); len(states) != 0 {
		t.Fatalf("get_operation carries no run statuses, got %#v", states)
	}
	incomplete := map[string]any{"runs": []any{map[string]any{"run_id": "r1", "status": "success"}}}
	if states := collectRunStates("run_action", incomplete); len(states) != 0 {
		t.Fatalf("run without operation_id accepted: %#v", states)
	}
}

func TestPlaceholderReasonFlagsFillerAndAcceptsHonestSentences(t *testing.T) {
	for reason, placeholder := range map[string]bool{
		"":             true,
		"test":         true,
		"Testing":      true,
		"check":        true,
		"linux.uptime": true,
		"short":        true,
		"Check uptime and load before the maintenance window": false,
		"verify replication catch-up after failover":          false,
		"Collect disk usage for the capacity report":          false,
	} {
		if got := placeholderReason(reason, "linux.uptime"); got != placeholder {
			t.Errorf("placeholderReason(%q) = %t, want %t", reason, got, placeholder)
		}
	}
}
