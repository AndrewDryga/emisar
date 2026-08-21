package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCLIHumanRunActionFollowsExactContinuation(t *testing.T) {
	var calls atomic.Int32
	var mutationOperationID string
	var requestTokens []string
	var tokenMu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		tokenMu.Lock()
		requestTokens = append(requestTokens, r.Header.Get(requestTokenHeader))
		tokenMu.Unlock()
		var request struct {
			Params struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			} `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		switch call {
		case 1:
			if request.Params.Name != runActionToolName {
				t.Errorf("first tool = %q", request.Params.Name)
			}
			mutationOperationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runs":[{"run_id":"run-1","operation_id":%q,"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runner_ref":"db-1~abc","status":"running","next":{"tool":"wait_for_run","arguments":{"run_id":"run-1","cursor":"cursor-1","timeout":"60s"}}}]},"content":[],"isError":false}`, mutationOperationID, mutationOperationID))
		case 2:
			if request.Params.Name != waitForRunToolName || !jsonEqual(request.Params.Arguments, []byte(`{"run_id":"run-1","cursor":"cursor-1","timeout":"60s"}`)) {
				t.Errorf("follow request = %s %s", request.Params.Name, request.Params.Arguments)
			}
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"run":{"run_id":"run-1","operation_id":%q,"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runner_ref":"db-1~abc","status":"success","exit_code":0,"output":[{"stream":"stdout","text":"primary\nhealthy"}]}},"content":[],"isError":false}`, mutationOperationID))
		default:
			t.Errorf("unexpected request %d", call)
		}
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{runActionToolName, `{}`}, "")
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stderr=%q\n%s", code, stderr, stdout)
	}
	for _, want := range []string{
		"Operation ID  " + mutationOperationID,
		"Waiting for completion. Ctrl-C stops waiting; the action keeps running.",
		"Final status",
		"db-1~abc — success",
		"Output\n    primary\n    healthy",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, stdout)
		}
	}
	if calls.Load() != 2 {
		t.Fatalf("calls = %d, want 2", calls.Load())
	}
	if len(requestTokens) != 2 || requestTokens[0] == requestTokens[1] {
		t.Fatalf("request tokens must be distinct: %#v", requestTokens)
	}
}

func TestCLIProcessRunsActionThroughTerminalOutput(t *testing.T) {
	var calls atomic.Int32
	var mutationOperationID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		var request struct {
			Params struct {
				Name string `json:"name"`
			} `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Errorf("decode request: %v", err)
			return
		}
		if call == 1 {
			mutationOperationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","runs":[{"run_id":"run-1","operation_id":%q,"action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","runner_ref":"host-1~abc","status":"running","next":{"tool":"wait_for_run","arguments":{"run_id":"run-1","timeout":"60s"}}}]},"content":[],"isError":false}`, mutationOperationID, mutationOperationID))
			return
		}
		if request.Params.Name != waitForRunToolName {
			t.Errorf("follow tool = %q", request.Params.Name)
		}
		writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"run":{"run_id":"run-1","operation_id":%q,"action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","runner_ref":"host-1~abc","status":"success","exit_code":0,"output":[{"stream":"stdout","text":"up 12 days"}]}},"content":[],"isError":false}`, mutationOperationID))
	}))
	defer srv.Close()

	env := map[string]string{"EMISAR_URL": srv.URL, "EMISAR_API_KEY": "e2e-token"}
	stdout, stderr, code := runMain(t, "", []string{runActionToolName, `{}`}, env)
	if code != 0 || stderr != "" || calls.Load() != 2 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	for _, want := range []string{"Action dispatched to 1 runner", "Operation ID  " + mutationOperationID, "Final status", "host-1~abc — success", "up 12 days"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("process stdout missing %q:\n%s", want, stdout)
		}
	}
}

func TestCLIJSONMutationMakesExactlyOneCall(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		operationID := r.Header.Get(operationIDHeader)
		writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runs":[{"run_id":"run-1","operation_id":%q,"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runner_ref":"db-1~abc","status":"running","next":{"tool":"wait_for_run","arguments":{"run_id":"run-1","timeout":"60s"}}}]},"content":[],"isError":false}`, operationID, operationID))
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{runActionToolName, `{}`, "--json"}, "")
	if code != 0 || stderr != "" || !json.Valid([]byte(stdout)) {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if calls.Load() != 1 {
		t.Fatalf("--json calls = %d, want exactly 1", calls.Load())
	}
}

func TestCLIJSONExecuteRunbookMakesExactlyOneCall(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		operationID := r.Header.Get(operationIDHeader)
		writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"active","stages":[],"runs_next":{"tool":"recent_runs","arguments":{"runbook_execution_id":"exec-1","limit":15}},"next":{"tool":"wait_for_run","arguments":{"runbook_execution_id":"exec-1","timeout":"60s"}}}},"content":[],"isError":false}`, operationID))
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`, "--json"}, "")
	if code != 0 || stderr != "" || !json.Valid([]byte(stdout)) {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if calls.Load() != 1 {
		t.Fatalf("--json calls = %d, want exactly 1", calls.Load())
	}
	if !strings.Contains(stdout, `"runs_next"`) || !strings.Contains(stdout, `"next"`) {
		t.Fatalf("exact structuredContent was not preserved: %s", stdout)
	}
}

func TestCLIHumanExecuteRunbookRejectsMutationResultsContinuation(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		operationID := r.Header.Get(operationIDHeader)
		writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[{"stage_id":"inspect","title":"Inspect","status":"succeeded","items":[{"item_id":"item-1","step_id":"status","runner_ref":"db-1~abc","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","latest_attempt":{"run_id":"run-1","attempt_number":1,"status":"success"}}]}],"runs_next":{"tool":"run_action","arguments":{"action_id":"danger.erase"}}}},"content":[],"isError":false}`, operationID))
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`}, "")
	if code != 1 || calls.Load() != 1 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stderr, "invalid action-results continuation") ||
		strings.Contains(stdout, "danger.erase") || strings.Contains(stderr, "danger.erase") {
		t.Fatalf("unsafe results continuation was not rejected safely:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
}

func TestCLIHumanExecuteRunbookRejectsChangedActionResult(t *testing.T) {
	var calls atomic.Int32
	var operationID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		if call == 1 {
			operationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[{"stage_id":"inspect","title":"Inspect","status":"succeeded","items":[{"item_id":"item-1","step_id":"status","runner_ref":"db-1~abc","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","latest_attempt":{"run_id":"run-1","attempt_number":1,"status":"success"}}]}],"runs_next":{"tool":"recent_runs","arguments":{"runbook_execution_id":"exec-1","limit":15}}}},"content":[],"isError":false}`, operationID))
			return
		}
		writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"runs":[{"run_id":"run-1","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"status","runner_ref":"hostile~def","action_id":"danger.erase","pack_ref":"danger@1/sha256:def","status":"success","stdout":"do not print me"}],"next_cursor":null},"content":[],"isError":false}`, operationID))
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`}, "")
	if code != 1 || calls.Load() != 2 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stderr, "outside this runbook execution") ||
		strings.Contains(stdout, "danger.erase") || strings.Contains(stdout, "do not print me") {
		t.Fatalf("changed action identity reached output:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
}

func TestCLIHumanExecuteRunbookRejectsRepeatedResultsCursor(t *testing.T) {
	var calls atomic.Int32
	var operationID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch call := calls.Add(1); call {
		case 1:
			operationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[{"stage_id":"inspect","title":"Inspect","status":"succeeded","items":[{"item_id":"item-1","step_id":"status","runner_ref":"db-1~abc","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","latest_attempt":{"run_id":"run-latest","attempt_number":3,"status":"success"}}]}],"runs_next":{"tool":"recent_runs","arguments":{"runbook_execution_id":"exec-1","limit":15}}}},"content":[],"isError":false}`, operationID))
		case 2, 3:
			runID := fmt.Sprintf("run-old-%d", call)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"runs":[{"run_id":%q,"operation_id":%q,"runbook_execution_id":"exec-1","step_id":"status","runner_ref":"db-1~abc","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","status":"success","stdout":"old output"}],"next_cursor":"same-cursor"},"content":[],"isError":false}`, runID, operationID))
		default:
			t.Errorf("unexpected request %d", call)
		}
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`}, "")
	if code != 1 || calls.Load() != 3 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stderr, "repeated a cursor") || strings.Contains(stdout, "old output") {
		t.Fatalf("repeated cursor was not rejected before output:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
}

func TestCLIHumanExecuteRunbookRejectsChangedFrozenItem(t *testing.T) {
	var calls atomic.Int32
	var operationID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			operationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"active","stages":[{"stage_id":"inspect","title":"Inspect","mode":"parallel","status":"active","items":[{"item_id":"item-1","step_id":"status","runner_ref":"db-1~abc","status":"running","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc"}]}],"next":{"tool":"wait_for_run","arguments":{"runbook_execution_id":"exec-1","timeout":"60s"}}}},"content":[],"isError":false}`, operationID))
			return
		}
		writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[{"stage_id":"inspect","title":"Inspect","mode":"parallel","status":"succeeded","items":[{"item_id":"item-1","step_id":"status","runner_ref":"db-1~abc","status":"succeeded","action_id":"danger.erase","pack_ref":"danger@1/sha256:def","latest_attempt":{"run_id":"run-1","attempt_number":1,"status":"success"}}]}],"runs_next":{"tool":"recent_runs","arguments":{"runbook_execution_id":"exec-1","limit":15}}}},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`}, "")
	if code != 1 || calls.Load() != 2 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stderr, "different or invalid runbook execution") || strings.Contains(stdout, "danger.erase") {
		t.Fatalf("changed frozen item reached output:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
}

func TestCLIProcessRejectsSpoofedMutationOperationBeforeOutput(t *testing.T) {
	var transportOperationID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		transportOperationID = r.Header.Get(operationIDHeader)
		writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"operation_id":"op_spoofed","action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","runs":[{"run_id":"run-1","operation_id":"op_spoofed","action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","runner_ref":"host-1~abc","status":"success"}]},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	env := map[string]string{"EMISAR_URL": srv.URL, "EMISAR_API_KEY": "e2e-token"}
	stdout, stderr, code := runMain(t, "", []string{runActionToolName, `{}`}, env)
	if code != 1 || stdout != "" {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if strings.Contains(stderr, "op_spoofed") || transportOperationID == "" ||
		!strings.Contains(stderr, transportOperationID) {
		t.Fatalf("spoofed operation diagnostic was not safely correlated:\n%s", stderr)
	}
}

func TestCLIProcessRejectsSpoofedDraftOperationBeforeOutput(t *testing.T) {
	var transportOperationID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		transportOperationID = r.Header.Get(operationIDHeader)
		writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"operation_id":"op_spoofed","draft_id":"draft-1","slug":"database-check","status":"draft","definition_sha256":"sha256:draft"},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	env := map[string]string{"EMISAR_URL": srv.URL, "EMISAR_API_KEY": "e2e-token"}
	stdout, stderr, code := runMain(t, "", []string{createRunbookDraftToolName, `{}`}, env)
	if code != 1 || stdout != "" {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if strings.Contains(stderr, "op_spoofed") || transportOperationID == "" ||
		!strings.Contains(stderr, transportOperationID) {
		t.Fatalf("spoofed draft diagnostic was not safely correlated:\n%s", stderr)
	}
}

func TestCLIHumanRunActionRejectsUntrustedContinuation(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		operationID := r.Header.Get(operationIDHeader)
		writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runs":[{"run_id":"run-1","operation_id":%q,"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runner_ref":"db-1~abc","status":"running","next":{"tool":"run_action","arguments":{"run_id":"run-1"}}}]},"content":[],"isError":false}`, operationID, operationID))
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{runActionToolName, `{}`}, "")
	if code != 1 || calls.Load() != 1 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stderr, "invalid wait continuation") || !strings.Contains(stderr, "get_operation") {
		t.Fatalf("unsafe continuation diagnostic:\n%s", stderr)
	}
	if strings.Contains(stderr, "run_action") {
		t.Fatalf("diagnostic exposed a mutation continuation:\n%s", stderr)
	}
}

func TestCLIHumanRunActionRejectsChangedRunIdentity(t *testing.T) {
	var calls atomic.Int32
	var mutationOperationID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		if call == 1 {
			mutationOperationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","runs":[{"run_id":"run-1","operation_id":%q,"action_id":"linux.uptime","pack_ref":"linux@1/sha256:abc","runner_ref":"host-1~abc","status":"running","next":{"tool":"wait_for_run","arguments":{"run_id":"run-1","timeout":"60s"}}}]},"content":[],"isError":false}`, mutationOperationID, mutationOperationID))
			return
		}
		writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"run":{"run_id":"run-1","operation_id":%q,"action_id":"danger.erase","pack_ref":"other@1/sha256:def","runner_ref":"other-host~def","status":"failed"}},"content":[],"isError":false}`, mutationOperationID))
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{runActionToolName, `{}`}, "")
	if code != 1 || calls.Load() != 2 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stderr, "different or invalid run") || strings.Contains(stdout, "danger.erase") ||
		strings.Contains(stdout, "other-host") {
		t.Fatalf("changed run identity was not rejected safely:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
}

func TestCLIHumanRunActionCancellationStopsOnlyWaiting(t *testing.T) {
	followStarted := make(chan struct{})
	releaseFollow := make(chan struct{})
	var mutationOperationID string
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		if call == 1 {
			mutationOperationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runs":[{"run_id":"run-1","operation_id":%q,"action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","runner_ref":"db-1~abc","status":"running","next":{"tool":"wait_for_run","arguments":{"run_id":"run-1","timeout":"60s"}}}]},"content":[],"isError":false}`, mutationOperationID, mutationOperationID))
			return
		}
		close(followStarted)
		<-releaseFollow
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	b := newTestBridge(srv)
	var stdout, stderr bytes.Buffer
	done := make(chan int, 1)
	go func() {
		done <- b.runCLIContext(ctx, []string{runActionToolName, `{}`}, strings.NewReader(""), &stdout, &stderr)
	}()
	select {
	case <-followStarted:
		cancel()
		close(releaseFollow)
	case <-time.After(2 * time.Second):
		t.Fatal("follow request did not start")
	}
	select {
	case code := <-done:
		if code != 130 {
			t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
		}
	case <-time.After(2 * time.Second):
		t.Fatal("CLI did not stop after cancellation")
	}
	if !strings.Contains(stderr.String(), "Stopped waiting") ||
		!strings.Contains(stderr.String(), "action was not cancelled") ||
		!strings.Contains(stderr.String(), mutationOperationID) {
		t.Fatalf("cancellation diagnostic:\n%s", stderr.String())
	}
}

func TestCLIHumanExecuteRunbookFollowsStatusAndOutputs(t *testing.T) {
	var calls atomic.Int32
	var mutationOperationID string
	fullReplicaOutput := strings.Repeat("replica healthy\n", 240) + "full output end\x1b[31m\u202evil"
	fullReplicaOutputJSON, err := json.Marshal(fullReplicaOutput)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		var request struct {
			Params struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			} `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Errorf("decode request: %v", err)
			return
		}
		switch call {
		case 1:
			mutationOperationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"active","stages":[{"stage_id":"inspect","title":"Inspect databases","mode":"parallel","status":"active","items":[{"item_id":"item-1","step_id":"primary_status","runner_ref":"db-1~abc","status":"running","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","attempt_count":1},{"item_id":"item-2","step_id":"replica_status","runner_ref":"db-2~def","status":"pending","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc"}]},{"stage_id":"report","title":"Build report","mode":"sequential","status":"pending","items":[{"item_id":"item-3","step_id":"render_report","runner_ref":"ops-1~ghi","status":"pending","action_id":"linux.uptime","pack_ref":"linux@1/sha256:def"}]}],"next":{"tool":"wait_for_run","arguments":{"runbook_execution_id":"exec-1","timeout":"60s"}}}},"content":[],"isError":false}`, mutationOperationID))
		case 2:
			if request.Params.Name != waitForRunToolName || !jsonEqual(request.Params.Arguments, []byte(`{"runbook_execution_id":"exec-1","timeout":"60s"}`)) {
				t.Errorf("first status follow = %s %s", request.Params.Name, request.Params.Arguments)
			}
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"active","stages":[{"stage_id":"inspect","title":"Inspect databases","mode":"parallel","status":"active","items":[{"item_id":"item-1","step_id":"primary_status","runner_ref":"db-1~abc","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","attempt_count":1,"latest_attempt":{"run_id":"run-1","attempt_number":1,"status":"success","duration_ms":4}},{"item_id":"item-2","step_id":"replica_status","runner_ref":"db-2~def","status":"running","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","attempt_count":1}]},{"stage_id":"report","title":"Build report","mode":"sequential","status":"pending","items":[{"item_id":"item-3","step_id":"render_report","runner_ref":"ops-1~ghi","status":"pending","action_id":"linux.uptime","pack_ref":"linux@1/sha256:def"}]}],"next":{"tool":"wait_for_run","arguments":{"runbook_execution_id":"exec-1","cursor":"status-2","timeout":"60s"}}}},"content":[],"isError":false}`)
		case 3:
			if request.Params.Name != waitForRunToolName || !jsonEqual(request.Params.Arguments, []byte(`{"runbook_execution_id":"exec-1","cursor":"status-2","timeout":"60s"}`)) {
				t.Errorf("second status follow = %s %s", request.Params.Name, request.Params.Arguments)
			}
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[{"stage_id":"inspect","title":"Inspect databases","mode":"parallel","status":"succeeded","items":[{"item_id":"item-1","step_id":"primary_status","runner_ref":"db-1~abc","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","attempt_count":1,"latest_attempt":{"run_id":"run-1","attempt_number":1,"status":"success","duration_ms":4}},{"item_id":"item-2","step_id":"replica_status","runner_ref":"db-2~def","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","attempt_count":1,"latest_attempt":{"run_id":"run-2","attempt_number":1,"status":"success","duration_ms":7}}]},{"stage_id":"report","title":"Build report","mode":"sequential","status":"succeeded","items":[{"item_id":"item-3","step_id":"render_report","runner_ref":"ops-1~ghi","status":"succeeded","action_id":"linux.uptime","pack_ref":"linux@1/sha256:def","attempt_count":2,"latest_attempt":{"run_id":"run-3","attempt_number":2,"status":"success","duration_ms":1250}}]}],"runs_next":{"tool":"recent_runs","arguments":{"runbook_execution_id":"exec-1","limit":15}},"outputs_next":{"tool":"wait_for_run","arguments":{"runbook_execution_id":"exec-1","cursor":"outputs-1","timeout":"0"}}}},"content":[],"isError":false}`)
		case 4:
			if request.Params.Name != recentRunsToolName || !jsonEqual(request.Params.Arguments, []byte(`{"runbook_execution_id":"exec-1","limit":15}`)) {
				t.Errorf("first results page = %s %s", request.Params.Name, request.Params.Arguments)
			}
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"runs":[{"run_id":"run-1","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"primary_status","runner_ref":"db-1~abc","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","status":"success","duration_ms":4,"stdout":"primary healthy"},{"run_id":"run-3","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"render_report","runner_ref":"ops-1~ghi","action_id":"linux.uptime","pack_ref":"linux@1/sha256:def","status":"success","duration_ms":1250,"stdout":"up 24 days","structured_output_omitted":true,"run_url":"https://emisar.dev/app/demo/runs/run-3"}],"next_cursor":"runs-2"},"content":[],"isError":false}`, mutationOperationID, mutationOperationID))
		case 5:
			if request.Params.Name != recentRunsToolName || !jsonEqual(request.Params.Arguments, []byte(`{"runbook_execution_id":"exec-1","limit":15,"cursor":"runs-2"}`)) {
				t.Errorf("second results page = %s %s", request.Params.Name, request.Params.Arguments)
			}
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"runs":[{"run_id":"run-2","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"replica_status","runner_ref":"db-2~def","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","status":"success","duration_ms":7,"stdout":"line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\u001b[31m\u202evil","emitted_stdout_bytes":1200000,"truncated_stdout":true,"run_url":"https://emisar.dev/app/demo/runs/run-2","next":{"tool":"wait_for_run","arguments":{"run_id":"run-2","cursor":"output-2","timeout":"0"}}}],"next_cursor":null},"content":[],"isError":false}`, mutationOperationID))
		case 6:
			if request.Params.Name != waitForRunToolName || !jsonEqual(request.Params.Arguments, []byte(`{"run_id":"run-2","cursor":"output-2","timeout":"0"}`)) {
				t.Errorf("action output follow = %s %s", request.Params.Name, request.Params.Arguments)
			}
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"run":{"run_id":"run-2","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"replica_status","runner_ref":"db-2~def","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","status":"success","duration_ms":7,"output":[{"stream":"stdout","text":%s}],"run_url":"https://emisar.dev/app/demo/runs/run-2"}},"content":[],"isError":false}`, mutationOperationID, fullReplicaOutputJSON))
		case 7:
			if request.Params.Name != waitForRunToolName || !jsonEqual(request.Params.Arguments, []byte(`{"runbook_execution_id":"exec-1","cursor":"outputs-1","timeout":"0"}`)) {
				t.Errorf("output follow = %s %s", request.Params.Name, request.Params.Arguments)
			}
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"execution_outputs":{"runbook_execution_id":"exec-1","total_count":1,"returned_count":1,"remaining_count":0,"outputs":[{"output_id":"role","stage_id":"inspect","step_id":"primary_status","runner_ref":"db-1~abc","source":"structured","sensitive":false,"status":"captured","value":"primary"}]}},"content":[],"isError":false}`)
		default:
			t.Errorf("unexpected request %d", call)
		}
	}))
	defer srv.Close()

	env := map[string]string{"EMISAR_URL": srv.URL, "EMISAR_API_KEY": "e2e-token"}
	stdout, stderr, code := runMain(t, "", []string{executeRunbookToolName, `{}`}, env)
	if code != 0 || stderr != "" || calls.Load() != 7 {
		t.Fatalf("exit=%d calls=%d stderr=%q\n%s", code, calls.Load(), stderr, stdout)
	}
	for _, want := range []string{
		"Operation ID  " + mutationOperationID,
		"3 actions across 2 stages",
		"● Inspect databases — 0/2 complete · 1 running",
		"○ Build report — waiting · 1 action",
		"● Inspect databases — 1/2 complete · 1 running",
		"✓ Inspect databases — 2/2 succeeded",
		"✓ Build report — 1/1 succeeded",
		"✓ Runbook succeeded — 3/3 actions succeeded",
		"Results\n\nInspect databases",
		"✓ primary_status · db-1 · 4 ms",
		"primary healthy",
		"✓ replica_status · db-2 · 7 ms",
		"replica healthy\n      replica healthy",
		"full output end",
		"Build report",
		"✓ render_report · ops-1 · 1.2 s",
		"linux.uptime · 2 attempts",
		"up 24 days",
		"… structured result omitted from this preview",
		"Details  https://emisar.dev/app/demo/runs/run-3",
		"1 of 1 runbook outputs",
		"\"primary\"",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, stdout)
		}
	}
	for _, unwanted := range []string{
		"Final status",
		"primary_status on db-1~abc",
		"… preview truncated · 1.2 MB total",
		`More  emisar-mcp wait_for_run`,
		"\x1b",
		"\u202e",
	} {
		if strings.Contains(stdout, unwanted) {
			t.Errorf("stdout contains %q:\n%s", unwanted, stdout)
		}
	}
}

func TestCLIHumanExecuteRunbookBoundsAutomaticallyFollowedOutput(t *testing.T) {
	var calls atomic.Int32
	var operationID string
	oversizedOutput := strings.Repeat("x", maxCLIResultOutputRunes+100) + "must not print"
	oversizedOutputJSON, err := json.Marshal(oversizedOutput)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch call := calls.Add(1); call {
		case 1:
			operationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[{"stage_id":"inspect","title":"Inspect","mode":"sequential","status":"succeeded","items":[{"item_id":"item-1","step_id":"status","runner_ref":"db-1~abc","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","latest_attempt":{"run_id":"run-1","attempt_number":1,"status":"success"}}]}],"runs_next":{"tool":"recent_runs","arguments":{"runbook_execution_id":"exec-1","limit":15}}}},"content":[],"isError":false}`, operationID))
		case 2:
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"runs":[{"run_id":"run-1","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"status","runner_ref":"db-1~abc","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","status":"success","stdout":"preview","truncated_stdout":true,"run_url":"https://emisar.dev/app/demo/runs/run-1","next":{"tool":"wait_for_run","arguments":{"run_id":"run-1","cursor":"output-1","timeout":"0"}}}],"next_cursor":null},"content":[],"isError":false}`, operationID))
		case 3:
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"run":{"run_id":"run-1","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"status","runner_ref":"db-1~abc","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","status":"success","output":[{"stream":"stdout","text":%s}],"run_url":"https://emisar.dev/\u202e","next":{"tool":"wait_for_run","arguments":{"run_id":"run-1","cursor":"output-2","timeout":"0"}}}},"content":[],"isError":false}`, operationID, oversizedOutputJSON))
		default:
			t.Errorf("unexpected request %d", call)
		}
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`}, "")
	if code != 0 || stderr != "" || calls.Load() != 3 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stdout, "output exceeds the 16,384-character terminal display limit") ||
		!strings.Contains(stdout, "Details  https://emisar.dev/app/demo/runs/run-1") ||
		strings.Contains(stdout, "must not print") || strings.Contains(stdout, "More  emisar-mcp wait_for_run") {
		t.Fatalf("bounded output did not provide a safe full-output path:\n%s", stdout)
	}
	if len([]rune(stdout)) > maxCLIResultOutputRunes+5_000 {
		t.Fatalf("bounded result amplified to %d characters", len([]rune(stdout)))
	}
}

func TestCLIHumanExecuteRunbookRejectsRepeatedActionOutputContinuation(t *testing.T) {
	var calls atomic.Int32
	var operationID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch call := calls.Add(1); call {
		case 1:
			operationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[{"stage_id":"inspect","title":"Inspect","mode":"sequential","status":"succeeded","items":[{"item_id":"item-1","step_id":"status","runner_ref":"db-1~abc","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","latest_attempt":{"run_id":"run-1","attempt_number":1,"status":"success"}}]}],"runs_next":{"tool":"recent_runs","arguments":{"runbook_execution_id":"exec-1","limit":15}}}},"content":[],"isError":false}`, operationID))
		case 2:
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"runs":[{"run_id":"run-1","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"status","runner_ref":"db-1~abc","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","status":"success","next":{"tool":"wait_for_run","arguments":{"run_id":"run-1","cursor":"same","timeout":"0"}}}],"next_cursor":null},"content":[],"isError":false}`, operationID))
		case 3:
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"run":{"run_id":"run-1","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"status","runner_ref":"db-1~abc","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","status":"success","output":[{"stream":"stdout","text":"do not render"}],"next":{"tool":"wait_for_run","arguments":{"run_id":"run-1","cursor":"same","timeout":"0"}}}},"content":[],"isError":false}`, operationID))
		default:
			t.Errorf("unexpected request %d", call)
		}
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`}, "")
	if code != 1 || calls.Load() != 3 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stderr, "repeated an action-output continuation") ||
		!strings.Contains(stderr, operationID) || strings.Contains(stdout, "do not render") {
		t.Fatalf("repeated continuation was not rejected safely:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
}

func TestCLIHumanExecuteRunbookRejectsChangedActionOutputIdentity(t *testing.T) {
	var calls atomic.Int32
	var operationID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch call := calls.Add(1); call {
		case 1:
			operationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[{"stage_id":"inspect","title":"Inspect","mode":"sequential","status":"succeeded","items":[{"item_id":"item-1","step_id":"status","runner_ref":"db-1~abc","status":"succeeded","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","latest_attempt":{"run_id":"run-1","attempt_number":1,"status":"success"}}]}],"runs_next":{"tool":"recent_runs","arguments":{"runbook_execution_id":"exec-1","limit":15}}}},"content":[],"isError":false}`, operationID))
		case 2:
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"runs":[{"run_id":"run-1","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"status","runner_ref":"db-1~abc","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","status":"success","next":{"tool":"wait_for_run","arguments":{"run_id":"run-1","cursor":"output-1","timeout":"0"}}}],"next_cursor":null},"content":[],"isError":false}`, operationID))
		case 3:
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"run":{"run_id":"run-1","operation_id":%q,"runbook_execution_id":"exec-1","step_id":"status","runner_ref":"hostile~def","action_id":"postgres.status","pack_ref":"postgres@1/sha256:abc","status":"success","output":[{"stream":"stdout","text":"do not render"}]}},"content":[],"isError":false}`, operationID))
		default:
			t.Errorf("unexpected request %d", call)
		}
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`}, "")
	if code != 1 || calls.Load() != 3 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stderr, "different or invalid runbook action") ||
		strings.Contains(stdout, "hostile") || strings.Contains(stdout, "do not render") {
		t.Fatalf("changed output identity was not rejected safely:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
}

func TestCLIRunbookProgressDisplayRedrawsOneLinePerStage(t *testing.T) {
	initial := []cliRunbookStageResult{
		{
			StageID: "inspect", Title: "Inspect databases", Status: "active",
			Items: []cliRunbookItemResult{{Status: "running"}, {Status: "pending"}},
		},
		{
			StageID: "report", Title: "Build report", Status: "pending",
			Items: []cliRunbookItemResult{{Status: "pending"}},
		},
	}
	updated := []cliRunbookStageResult{
		{
			StageID: "inspect", Title: "Inspect databases", Status: "succeeded",
			Items: []cliRunbookItemResult{{Status: "succeeded"}, {Status: "succeeded"}},
		},
		{
			StageID: "report", Title: "Build report", Status: "active",
			Items: []cliRunbookItemResult{{Status: "running"}},
		},
	}

	var out bytes.Buffer
	display := cliRunbookProgressDisplay{
		writer:       &out,
		terminalSize: func() (int, int, bool) { return 120, 40, true },
		redraw:       true,
	}
	display.writeInitial(initial)
	display.writeUpdate(updated)
	afterUpdate := out.Len()
	display.writeUpdate(updated)
	if out.Len() != afterUpdate {
		t.Fatal("unchanged progress was redrawn")
	}

	want := "\x1b[2A\r\x1b[2K  ✓ Inspect databases — 2/2 succeeded\n" +
		"\r\x1b[2K  ● Build report — 0/1 complete · 1 running\n"
	if !strings.Contains(out.String(), want) {
		t.Fatalf("progress was not redrawn in place:\n%q", out.String())
	}
}

func TestCLIRunbookProgressRedrawRequiresLinesThatFit(t *testing.T) {
	stages := []cliRunbookStageResult{{
		StageID: "inspect", Title: "Inspect databases", Status: "active",
		Items: []cliRunbookItemResult{{Status: "running"}},
	}}
	if !cliRunbookProgressFitsWidth(stages, 80) {
		t.Fatal("ordinary progress line should fit an 80-column terminal")
	}
	if cliRunbookProgressFitsWidth(stages, 20) {
		t.Fatal("wrapped progress line must not use cursor redraw")
	}
	if cliRunbookProgressFitsTerminal(stages, 80, 1) {
		t.Fatal("progress taller than the terminal must not use cursor redraw")
	}
	stages[0].Title = "Inspect données"
	if cliRunbookProgressFitsWidth(stages, 80) {
		t.Fatal("ambiguous-width server text must not use cursor redraw")
	}
}

func TestCLIHumanExecuteRunbookRequiresProgressingOutputContinuation(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		operationID := r.Header.Get(operationIDHeader)
		switch call {
		case 1:
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[],"outputs_next":{"tool":"wait_for_run","arguments":{"runbook_execution_id":"exec-1","cursor":"outputs-1","timeout":"0"}}}},"content":[],"isError":false}`, operationID))
		case 2:
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"execution_outputs":{"runbook_execution_id":"exec-1","total_count":2,"returned_count":1,"remaining_count":1,"outputs":[{"output_id":"first","stage_id":"inspect","step_id":"status","runner_ref":"db-1~abc","source":"structured","sensitive":false,"status":"captured","value":"primary"}]}},"content":[],"isError":false}`)
		default:
			t.Errorf("unexpected request %d", call)
		}
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`}, "")
	if code != 1 || calls.Load() != 2 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stderr, "invalid runbook outputs") || strings.Contains(stdout, "1 outputs remain") {
		t.Fatalf("non-progressing output page was not rejected:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
}

func TestCLIHumanExecuteRunbookRejectsSkippedOutputPages(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		operationID := r.Header.Get(operationIDHeader)
		switch call {
		case 1:
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[],"outputs_next":{"tool":"wait_for_run","arguments":{"runbook_execution_id":"exec-1","cursor":"outputs-1","timeout":"0"}}}},"content":[],"isError":false}`, operationID))
		case 2:
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"execution_outputs":{"runbook_execution_id":"exec-1","total_count":10,"returned_count":1,"remaining_count":9,"outputs":[{"output_id":"first","stage_id":"inspect","step_id":"status","runner_ref":"db-1~abc","source":"structured","sensitive":false,"status":"captured","value":1}],"next":{"tool":"wait_for_run","arguments":{"runbook_execution_id":"exec-1","cursor":"outputs-2","timeout":"0"}}}},"content":[],"isError":false}`)
		case 3:
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"execution_outputs":{"runbook_execution_id":"exec-1","total_count":10,"returned_count":1,"remaining_count":0,"outputs":[{"output_id":"tenth","stage_id":"inspect","step_id":"status","runner_ref":"db-1~abc","source":"structured","sensitive":false,"status":"captured","value":10}]}},"content":[],"isError":false}`)
		default:
			t.Errorf("unexpected request %d", call)
		}
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`}, "")
	if code != 1 || calls.Load() != 3 {
		t.Fatalf("exit=%d calls=%d stdout=%q stderr=%q", code, calls.Load(), stdout, stderr)
	}
	if !strings.Contains(stderr, "invalid runbook outputs") || strings.Contains(stdout, "tenth") {
		t.Fatalf("skipped output page was not rejected:\nstdout=%s\nstderr=%s", stdout, stderr)
	}
}
