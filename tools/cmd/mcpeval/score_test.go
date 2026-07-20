package main

import (
	"strings"
	"testing"
)

func conformingScenario() scenario {
	return scenario{
		AllowedTools:    []string{"list_runners", "find_actions", "get_action", "run_action", "wait_for_run"},
		RequiredTools:   []string{"list_runners", "get_action", "run_action"},
		AllowedActions:  []string{"linux.uptime"},
		RequiredActions: []string{"linux.uptime"},
	}
}

func conformingCalls() []callRecord {
	return []callRecord{
		{Tool: "list_runners"},
		{Tool: "get_action", ActionID: "linux.uptime", PackRef: "p"},
		{Tool: "run_action", ActionID: "linux.uptime", PackRef: "p", priorContractMatched: true,
			RunStates: []runState{{RunID: "r1", OperationID: "op_1", Status: "queued"}}},
		{Tool: "wait_for_run",
			RunStates: []runState{{RunID: "r1", OperationID: "op_1", Status: "success"}}},
	}
}

func TestScoreAcceptsContinuationDrivenTerminalTranscript(t *testing.T) {
	got := scoreReport(conformingScenario(), conformingCalls(), agentResult{})
	if !got.Passed {
		t.Fatalf("score failed: %v", got.Failures)
	}
	if got.TotalCalls != 4 || got.RunsStarted != 1 || got.RunsTerminal != 1 {
		t.Fatalf("counters = %#v", got)
	}
}

func TestScoreRejectsPolicyBlockedCall(t *testing.T) {
	calls := append(conformingCalls(), callRecord{
		Tool: "run_action", ActionID: "linux.shutdown", BlockedByPolicy: true,
		ResponseError: true, ResponseCode: "action_not_allowed",
	})
	got := scoreReport(conformingScenario(), calls, agentResult{})
	if got.Passed || got.PolicyBlockedCalls != 1 {
		t.Fatalf("blocked call passed: %#v", got)
	}
}

func TestScoreRejectsPortalInvalidArgsOnMutations(t *testing.T) {
	calls := append(conformingCalls(), callRecord{Tool: "run_action", ResponseError: true, ResponseCode: "invalid_args"})
	got := scoreReport(conformingScenario(), calls, agentResult{})
	if got.Passed || got.InvalidArgsCalls != 1 {
		t.Fatalf("mutation invalid_args passed: %#v", got)
	}
}

func TestScoreReportsButAllowsDiscoveryInvalidArgs(t *testing.T) {
	calls := append(conformingCalls(), callRecord{Tool: "find_actions", ResponseError: true, ResponseCode: "invalid_args"})
	got := scoreReport(conformingScenario(), calls, agentResult{})
	if !got.Passed || got.InvalidArgsCalls != 1 {
		t.Fatalf("recovered discovery probe should pass with the count reported: %#v", got)
	}
}

func TestScoreRejectsRunActionWithoutReceipt(t *testing.T) {
	item := conformingScenario()
	calls := conformingCalls()
	calls[2].priorContractMatched = false
	got := scoreReport(item, calls, agentResult{})
	if got.Passed || got.ReceiptViolations != 1 {
		t.Fatalf("receiptless run_action passed: %#v", got)
	}

	item.RequireContractRef = true
	calls = conformingCalls()
	got = scoreReport(item, calls, agentResult{})
	if got.Passed || got.ReceiptViolations != 1 {
		t.Fatalf("missing contract_ref passed: %#v", got)
	}
	calls[2].ContractRefMatched = true
	if got := scoreReport(item, calls, agentResult{}); !got.Passed {
		t.Fatalf("matched contract_ref failed: %v", got.Failures)
	}
}

func TestScoreToleratesTwoIdenticalFailuresRejectsMore(t *testing.T) {
	for repeats, wantPassed := range map[int]bool{2: true, 3: false} {
		calls := conformingCalls()
		for range repeats {
			calls = append(calls, callRecord{Tool: "find_actions", ArgumentsDigest: "same", ResponseError: true})
		}
		got := scoreReport(conformingScenario(), calls, agentResult{})
		if got.Passed != wantPassed {
			t.Fatalf("%d identical failures: passed=%t (%v)", repeats, got.Passed, got.Failures)
		}
	}
}

func TestScoreRejectsRunLeftNonTerminal(t *testing.T) {
	calls := conformingCalls()[:3]
	got := scoreReport(conformingScenario(), calls, agentResult{})
	if got.Passed || len(got.NonTerminalRuns) != 1 || got.NonTerminalRuns[0] != "r1" {
		t.Fatalf("abandoned run passed: %#v", got)
	}
}

func TestScoreRejectsMissingRequiredToolsAndActions(t *testing.T) {
	item := conformingScenario()
	item.RequiredTools = []string{"list_runners", "get_action", "run_action", "find_actions"}
	item.RequiredActions = []string{"linux.uptime", "linux.disk_usage"}
	got := scoreReport(item, conformingCalls(), agentResult{})
	if got.Passed ||
		len(got.MissingRequiredTools) != 1 || got.MissingRequiredTools[0] != "find_actions" ||
		len(got.MissingRequiredActions) != 1 || got.MissingRequiredActions[0] != "linux.disk_usage" {
		t.Fatalf("missing coverage passed: %#v", got)
	}
}

func TestScoreIgnoresFailedRunActionForRequiredActions(t *testing.T) {
	calls := conformingCalls()
	calls[2].ResponseError = true
	calls[2].ResponseCode = "runner_unavailable"
	got := scoreReport(conformingScenario(), calls, agentResult{})
	if got.Passed || len(got.MissingRequiredActions) != 1 {
		t.Fatalf("failed run_action satisfied a required action: %#v", got)
	}
}

func TestScoreRejectsAgentProcessFailure(t *testing.T) {
	if got := scoreReport(conformingScenario(), conformingCalls(), agentResult{ExitCode: 3}); got.Passed {
		t.Fatalf("nonzero agent exit passed: %#v", got)
	}
	got := scoreReport(conformingScenario(), conformingCalls(), agentResult{TimedOut: true, ExitCode: -1})
	if got.Passed || !strings.Contains(strings.Join(got.Failures, "\n"), "timeout") {
		t.Fatalf("timed-out agent passed: %#v", got)
	}
}

func TestTerminalStatusesMatchPublishedActionRunContract(t *testing.T) {
	want := []string{
		"success", "failed", "error", "validation_failed", "unknown_action",
		"cancelled", "timed_out", "refused", "denied",
	}
	if len(terminalStatuses) != len(want) {
		t.Fatalf("terminal statuses = %#v", terminalStatuses)
	}
	for _, status := range want {
		if !terminalStatuses[status] {
			t.Errorf("missing terminal status %q", status)
		}
	}
}
