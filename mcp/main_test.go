package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// renderRunBlocks is the single chokepoint that decides what an LLM
// sees after a tool call. Regressions here directly degrade the
// model's ability to diagnose failures. These tests pin the contract:
// stdout, stderr, exit_code, and error_message all reach the LLM in
// a form it can read.

func TestRenderRunBlocks_SuccessSurfacesStdout(t *testing.T) {
	run := map[string]any{
		"status":     "success",
		"exit_code":  float64(0),
		"stdout":     " 14:02:11 up 6 days, load average: 0.42\n",
		"stderr":     "",
		"runner":     "linux-prod-01",
		"duration_ms": float64(43),
	}

	blocks, isErr := renderRunBlocks(run, false)
	if isErr {
		t.Fatalf("success should not mark isError; got true")
	}

	text := flatten(blocks)
	if !strings.Contains(text, "load average") {
		t.Errorf("stdout missing from output: %q", text)
	}
	// Single-runner success — no [runner] header noise.
	if strings.Contains(text, "[linux-prod-01]") {
		t.Errorf("single-runner output should not include runner header: %q", text)
	}
}

func TestRenderRunBlocks_FailureSurfacesStderrAndExitCode(t *testing.T) {
	run := map[string]any{
		"status":        "failed",
		"exit_code":     float64(1),
		"stdout":        "",
		"stderr":        "nginx: [emerg] bind() to 0.0.0.0:80 failed (98: Address already in use)\n",
		"error_message": "command exited with code 1",
		"runner":        "linux-prod-01",
	}

	blocks, isErr := renderRunBlocks(run, false)
	if !isErr {
		t.Fatalf("failed status should mark isError; got false")
	}

	text := flatten(blocks)
	if !strings.Contains(text, "exit_code=1") {
		t.Errorf("exit code missing from failure output: %q", text)
	}
	if !strings.Contains(text, "status=failed") {
		t.Errorf("status missing from failure output: %q", text)
	}
	if !strings.Contains(text, "Address already in use") {
		t.Errorf("stderr missing from failure output: %q", text)
	}
	if !strings.Contains(text, "command exited with code 1") {
		t.Errorf("error_message missing from failure output: %q", text)
	}
}

func TestRenderRunBlocks_ErrorStatusSurfacesErrorMessage(t *testing.T) {
	// "error" status with negative exit_code is what we get when the
	// binary itself can't start (fork/exec failures). The runner's
	// `reason` lands in error_message — without surfacing it, the LLM
	// sees nothing actionable.
	run := map[string]any{
		"status":        "error",
		"exit_code":     float64(-1),
		"stdout":        "",
		"stderr":        "",
		"error_message": "fork/exec /bin/systemctl: no such file or directory",
		"runner":        "linux-prod-01",
	}

	blocks, isErr := renderRunBlocks(run, false)
	if !isErr {
		t.Fatalf("error status should mark isError; got false")
	}

	text := flatten(blocks)
	if !strings.Contains(text, "no such file or directory") {
		t.Errorf("error_message missing: %q", text)
	}
	if !strings.Contains(text, "status=error") {
		t.Errorf("status missing: %q", text)
	}
	if !strings.Contains(text, "exit_code=-1") {
		t.Errorf("exit_code missing: %q", text)
	}
}

func TestRenderRunBlocks_MultiRunnerPrependsHeader(t *testing.T) {
	run := map[string]any{
		"status":    "success",
		"exit_code": float64(0),
		"stdout":    "ok\n",
		"runner":    "db-prod-02",
	}

	blocks, _ := renderRunBlocks(run, true)
	text := flatten(blocks)

	if !strings.Contains(text, "[db-prod-02]") {
		t.Errorf("multi-runner output should include runner header: %q", text)
	}
}

func TestRenderRunBlocks_PendingApprovalTellsLLMToWait(t *testing.T) {
	run := map[string]any{
		"status": "pending_approval",
		"run_id": "00000000-0000-0000-0000-000000000abc",
		"runner": "db-prod-02",
	}

	blocks, isErr := renderRunBlocks(run, true)
	// Pending isn't a failure — must stay non-error so the model
	// doesn't bail out before the operator decides.
	if isErr {
		t.Fatalf("pending_approval should not mark isError; got true")
	}

	text := flatten(blocks)
	if !strings.Contains(text, "wait_for_run") {
		t.Errorf("pending message should tell the LLM to call wait_for_run: %q", text)
	}
	if !strings.Contains(text, "00000000-0000-0000-0000-000000000abc") {
		t.Errorf("pending message should embed run_id: %q", text)
	}
	if !strings.Contains(text, "[db-prod-02]") {
		t.Errorf("pending message should include runner header in multi mode: %q", text)
	}
}

func TestRenderRunBlocks_DeniedByPolicySurfacesReason(t *testing.T) {
	run := map[string]any{
		"status": "denied_by_policy",
		"reason": "denied: production runner outside of change window",
		"runner": "prod-01",
	}

	blocks, isErr := renderRunBlocks(run, false)
	if !isErr {
		t.Fatalf("denied_by_policy should mark isError; got false")
	}

	text := flatten(blocks)
	if !strings.Contains(text, "Denied by policy") {
		t.Errorf("expected denial prefix: %q", text)
	}
	if !strings.Contains(text, "outside of change window") {
		t.Errorf("policy reason missing: %q", text)
	}
}

func TestRenderRunBlocks_RunnerLevelErrorEntry(t *testing.T) {
	// Multi-runner dispatch with one bad runner name in the list:
	// the cloud emits {runner, status: "error", error: "runner_not_found"}.
	// The LLM needs to see WHICH runner failed and WHY.
	run := map[string]any{
		"runner":  "typo-runner",
		"status":  "error",
		"error":   "runner_not_found",
		"message": "No runner named 'typo-runner' is registered for this account.",
	}

	blocks, isErr := renderRunBlocks(run, true)
	if !isErr {
		t.Fatalf("runner-not-found should mark isError; got false")
	}

	text := flatten(blocks)
	if !strings.Contains(text, "[typo-runner]") {
		t.Errorf("runner header missing: %q", text)
	}
	if !strings.Contains(text, "runner_not_found") {
		t.Errorf("error code missing: %q", text)
	}
	if !strings.Contains(text, "No runner named") {
		t.Errorf("error detail message missing: %q", text)
	}
}

func TestIsFailureStatus(t *testing.T) {
	failures := []string{"failed", "error", "validation_failed", "unknown_action",
		"cancelled", "timed_out", "denied", "denied_by_policy"}
	for _, s := range failures {
		if !isFailureStatus(s) {
			t.Errorf("expected %q to count as failure", s)
		}
	}

	nonFailures := []string{"success", "pending_approval", "running", "sent", "pending", ""}
	for _, s := range nonFailures {
		if isFailureStatus(s) {
			t.Errorf("expected %q to NOT count as failure", s)
		}
	}
}

// -- Layer 1: per-call idempotency key derivation --------------------
//
// The bridge mints an Idempotency-Key per JSON-RPC call so a transport
// retry collapses to one run at the cloud. These pin the contract:
// stable for a (session, id) pair, distinct across ids, absent for
// notifications, and quote-normalized so numeric and string ids agree.

func TestIdempotencyKey_StableForSameID(t *testing.T) {
	b := &bridge{sessionID: "deadbeef"}
	if got, want := b.idempotencyKey(json.RawMessage("1")), "deadbeef:1"; got != want {
		t.Fatalf("key = %q, want %q", got, want)
	}
	if a, c := b.idempotencyKey(json.RawMessage("1")), b.idempotencyKey(json.RawMessage("1")); a != c {
		t.Errorf("same id should yield same key: %q vs %q", a, c)
	}
}

func TestIdempotencyKey_DiffersByID(t *testing.T) {
	b := &bridge{sessionID: "deadbeef"}
	if a, c := b.idempotencyKey(json.RawMessage("1")), b.idempotencyKey(json.RawMessage("2")); a == c {
		t.Errorf("distinct ids must not collide: both %q", a)
	}
}

func TestIdempotencyKey_EmptyForNotification(t *testing.T) {
	b := &bridge{sessionID: "deadbeef"}
	if got := b.idempotencyKey(json.RawMessage("")); got != "" {
		t.Errorf("missing id should yield empty key, got %q", got)
	}
	if got := b.idempotencyKey(json.RawMessage("null")); got != "" {
		t.Errorf("null id should yield empty key, got %q", got)
	}
}

func TestIdempotencyKey_NormalizesStringID(t *testing.T) {
	b := &bridge{sessionID: "s"}
	if got := b.idempotencyKey(json.RawMessage(`"7"`)); got != "s:7" {
		t.Errorf("string id should strip quotes: got %q, want %q", got, "s:7")
	}
}

func TestNewSessionID_UniquePerProcess(t *testing.T) {
	if newSessionID() == newSessionID() {
		t.Error("two session ids collided — nonce isn't random")
	}
}

// callTool must put the derived key on the wire as Idempotency-Key so
// the cloud's dedup index can see it. A blank key must NOT set the
// header at all (so the cloud treats it as a fresh, un-keyed dispatch).
func TestCallTool_SendsIdempotencyHeader(t *testing.T) {
	var gotKey string
	var hadHeader bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotKey = r.Header.Get("Idempotency-Key")
		_, hadHeader = r.Header["Idempotency-Key"]
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"runs":[{"status":"success","exit_code":0,"stdout":"ok"}]}`))
	}))
	defer srv.Close()

	b := &bridge{baseURL: srv.URL, apiKey: "k", userAgent: "ua", http: srv.Client(), sessionID: "sess"}

	if _, err := b.callTool("linux.uptime", map[string]any{"reason": "t"}, "sess:7"); err != nil {
		t.Fatalf("callTool: %v", err)
	}
	if gotKey != "sess:7" {
		t.Errorf("Idempotency-Key = %q, want %q", gotKey, "sess:7")
	}

	if _, err := b.callTool("linux.uptime", map[string]any{"reason": "t"}, ""); err != nil {
		t.Fatalf("callTool (no key): %v", err)
	}
	if hadHeader {
		t.Error("empty key must not set the Idempotency-Key header at all")
	}
}

func flatten(blocks []map[string]any) string {
	var parts []string
	for _, b := range blocks {
		if t, ok := b["text"].(string); ok {
			parts = append(parts, t)
		}
	}
	return strings.Join(parts, "\n---\n")
}
