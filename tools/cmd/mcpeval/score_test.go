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
		RequiredActions: [][]string{{"linux.uptime"}},
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

func TestScoreRequiresPositiveRecallAtFive(t *testing.T) {
	item := conformingScenario()
	item.RequiredSearchActions = [][]string{{"linux.uptime"}}
	calls := append([]callRecord{{
		Tool: "find_actions",
		SearchCandidates: []searchCandidate{{
			ActionID: "linux.uptime",
			PackRef:  "linux-core@1/sha256:abc",
		}},
	}}, conformingCalls()...)
	got := scoreReport(item, calls, agentResult{})
	if !got.Passed || len(got.MissingSearchActions) != 0 {
		t.Fatalf("recall@5 hit failed: %#v", got)
	}

	calls[0].SearchCandidates[0].ActionID = "linux.memory"
	got = scoreReport(item, calls, agentResult{})
	if got.Passed || len(got.MissingSearchActions) != 1 {
		t.Fatalf("recall@5 miss passed: %#v", got)
	}
}

func TestScoreNoActionCountsSearchNoiseAndFailsOnlyWhenActedOn(t *testing.T) {
	item := scenario{
		ExpectedOutcome: outcomeNoAction,
		AllowedTools:    []string{"find_actions"},
		RequiredTools:   []string{"find_actions"},
	}
	calls := []callRecord{{Tool: "find_actions"}}
	if got := scoreReport(item, calls, agentResult{}); !got.Passed {
		t.Fatalf("empty no-action result failed: %#v", got)
	}

	// Our own search matching something irrelevant is its recall, not the
	// client's judgment — counted and reported, never a verdict on the client.
	calls[0].SearchCandidates = []searchCandidate{{
		ActionID: "linux.uptime",
		PackRef:  "linux-core@1/sha256:abc",
	}}
	got := scoreReport(item, calls, agentResult{})
	if !got.Passed || got.NoActionCandidateCalls != 1 {
		t.Fatalf("searching once and stopping should pass despite noise: %#v", got)
	}

	// What the scenario actually refuses: acting on one of those candidates. It
	// declares no mutation tool, so the relay blocks the attempt and that is the
	// hard failure.
	acted := append(calls, callRecord{
		Tool:            "run_action",
		BlockedByPolicy: true,
		ResponseCode:    "tool_not_allowed",
	})
	if got := scoreReport(item, acted, agentResult{}); got.Passed {
		t.Fatalf("acting on a no_action candidate passed: %#v", got)
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

func TestScoreRejectsRunActionWithoutPriorInspection(t *testing.T) {
	item := conformingScenario()
	calls := conformingCalls()
	calls[2].priorContractMatched = false
	got := scoreReport(item, calls, agentResult{})
	if got.Passed || got.InspectionViolations != 1 {
		t.Fatalf("run_action without a prior get_action passed: %#v", got)
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
	item.RequiredActions = [][]string{{"linux.uptime"}, {"linux.disk_usage"}}
	got := scoreReport(item, conformingCalls(), agentResult{})
	if got.Passed ||
		len(got.MissingRequiredTools) != 1 || got.MissingRequiredTools[0] != "find_actions" ||
		len(got.MissingRequiredActions) != 1 || got.MissingRequiredActions[0] != "linux.disk_usage" {
		t.Fatalf("missing coverage passed: %#v", got)
	}
}

func TestScoreAcceptsAnyEquivalentInRequiredActionGroup(t *testing.T) {
	item := conformingScenario()
	item.AllowedActions = append(item.AllowedActions, "debugging.loadavg")
	// The agent satisfied the group via the second-listed equivalent.
	item.RequiredActions = [][]string{{"debugging.loadavg", "linux.uptime"}}
	got := scoreReport(item, conformingCalls(), agentResult{})
	if !got.Passed || len(got.MissingRequiredActions) != 0 {
		t.Fatalf("equivalent member did not satisfy its group: %#v", got)
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

func TestScoreRejectsPlaceholderRunActionReason(t *testing.T) {
	calls := conformingCalls()
	calls[2].ReasonPlaceholder = true
	got := scoreReport(conformingScenario(), calls, agentResult{})
	if got.Passed || got.PlaceholderReasons != 1 {
		t.Fatalf("placeholder reason passed: %#v", got)
	}
}

func TestScoreCountsJustificationChainWithoutFailing(t *testing.T) {
	calls := conformingCalls()
	calls[2].EvidencePresent = true
	calls[2].ExpectedPresent = true

	got := scoreReport(conformingScenario(), calls, agentResult{})
	if !got.Passed {
		t.Fatalf("the optional chain must never fail scoring: %v", got.Failures)
	}
	if got.EvidenceGiven != 1 || got.ExpectedGiven != 1 {
		t.Fatalf("chain counts = %#v", got)
	}
}

// A held-out partition pins exact `id@version/sha256:…` refs, so republishing a
// pack it names invalidates it. That cascades into four client-shaped failures —
// blocked run_action, two never-succeeded requirements, and a recall@5 miss —
// none of which are the client's doing. The report has to name the real cause,
// or the next reader re-derives it from the packs tree the way this one did.
func TestScoreNamesAStalePackPinRatherThanBlamingTheClient(t *testing.T) {
	item := conformingScenario()
	item.AllowedPackRefs = []string{"linux-core@0.3.23/sha256:old"}
	item.RequiredSearchActions = [][]string{{"linux.uptime"}}

	republished := "linux-core@0.4.0/sha256:new"
	calls := []callRecord{
		{Tool: "find_actions", SearchCandidates: []searchCandidate{
			{ActionID: "linux.uptime", PackRef: republished},
		}},
		{Tool: "get_action", ActionID: "linux.uptime", PackRef: republished},
		{Tool: "run_action", ActionID: "linux.uptime", PackRef: republished,
			priorContractMatched: true, BlockedByPolicy: true, ResponseError: true,
			ResponseCode: "pack_not_allowed"},
	}

	got := scoreReport(item, calls, agentResult{})
	if got.Passed {
		t.Fatal("a stale pin must still fail the scenario")
	}
	if len(got.StalePackRefs) != 2 {
		t.Fatalf("both the advertised and the dispatched ref should be reported: %#v", got.StalePackRefs)
	}
	stale := strings.Join(got.Failures, "\n")
	if !strings.Contains(stale, "allowed_pack_refs is STALE") || !strings.Contains(stale, republished) {
		t.Fatalf("the failure must name the stale pin and the republished ref: %v", got.Failures)
	}

	// The same transcript against a current pin is a clean pass — proving the
	// check fires on staleness alone and not on any allowlist rejection.
	item.AllowedPackRefs = []string{republished}
	if fresh := scoreReport(item, calls[:2], agentResult{}); len(fresh.StalePackRefs) != 0 {
		t.Fatalf("a current pin must report no staleness: %#v", fresh.StalePackRefs)
	}
}

// A fleet mid-upgrade serves the new pack on some runners and the old one on
// others, so search legitimately returns the SAME action at two refs. Reading
// staleness as "seen once at an unpinned ref" fails that perfectly good run and
// blames the corpus for a healthy rollout — the pin is stale only when nothing
// the fleet advertises matches it.
func TestScoreDoesNotCallAMidUpgradeFleetStale(t *testing.T) {
	item := conformingScenario()
	item.AllowedPackRefs = []string{"p"}
	item.RequiredSearchActions = [][]string{{"linux.uptime"}}

	calls := append([]callRecord{{Tool: "find_actions", SearchCandidates: []searchCandidate{
		{ActionID: "linux.uptime", PackRef: "p"},
		{ActionID: "linux.uptime", PackRef: "linux-core@0.3.23/sha256:notyetupgraded"},
	}}}, conformingCalls()...)

	got := scoreReport(item, calls, agentResult{})
	if len(got.StalePackRefs) != 0 {
		t.Fatalf("an older sibling ref is a rollout, not a stale pin: %#v", got.StalePackRefs)
	}
	if !got.Passed {
		t.Fatalf("the run must still pass: %v", got.Failures)
	}
}
