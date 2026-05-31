package main

import (
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

func flatten(blocks []map[string]any) string {
	var parts []string
	for _, b := range blocks {
		if t, ok := b["text"].(string); ok {
			parts = append(parts, t)
		}
	}
	return strings.Join(parts, "\n---\n")
}
