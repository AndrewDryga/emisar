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
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := calls.Add(1)
		var request struct {
			Params struct {
				Name string `json:"name"`
			} `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		switch call {
		case 1:
			mutationOperationID = r.Header.Get(operationIDHeader)
			writeCLIResult(t, w, r, fmt.Sprintf(`{"structuredContent":{"ok":true,"operation_id":%q,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"active","stages":[],"next":{"tool":"wait_for_run","arguments":{"runbook_execution_id":"exec-1","timeout":"60s"}}}},"content":[],"isError":false}`, mutationOperationID))
		case 2:
			if request.Params.Name != waitForRunToolName {
				t.Errorf("status follow tool = %q", request.Params.Name)
			}
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"execution":{"runbook_execution_id":"exec-1","runbook_ref":"database-check@3","kind":"published","definition_sha256":"sha256:live","status":"succeeded","stages":[],"outputs_next":{"tool":"wait_for_run","arguments":{"runbook_execution_id":"exec-1","cursor":"outputs-1","timeout":"0"}}}},"content":[],"isError":false}`)
		case 3:
			if request.Params.Name != waitForRunToolName {
				t.Errorf("output follow tool = %q", request.Params.Name)
			}
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"execution_outputs":{"runbook_execution_id":"exec-1","total_count":1,"returned_count":1,"remaining_count":0,"outputs":[{"output_id":"role","stage_id":"inspect","step_id":"status","runner_ref":"db-1~abc","source":"structured","sensitive":false,"status":"captured","value":"primary"}]}},"content":[],"isError":false}`)
		default:
			t.Errorf("unexpected request %d", call)
		}
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{executeRunbookToolName, `{}`}, "")
	if code != 0 || stderr != "" || calls.Load() != 3 {
		t.Fatalf("exit=%d calls=%d stderr=%q\n%s", code, calls.Load(), stderr, stdout)
	}
	for _, want := range []string{"Operation ID  " + mutationOperationID, "Waiting for completion", "Final status", "database-check@3 — succeeded", "1 of 1 runbook outputs", "\"primary\""} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, stdout)
		}
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
