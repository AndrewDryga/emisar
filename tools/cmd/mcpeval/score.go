package main

import (
	"fmt"
	"slices"
	"sort"
	"strings"
)

// terminalStatuses mirrors the published ActionRun contract
// (portal Emisar.Runs.ActionRun @terminal_statuses).
var terminalStatuses = map[string]bool{
	"success": true, "failed": true, "error": true, "validation_failed": true,
	"unknown_action": true, "cancelled": true, "timed_out": true, "refused": true,
	"denied": true,
}

// mutationTools are the calls that must be composed from a retrieved contract
// on the first attempt; discovery reads self-heal by design.
var mutationTools = map[string]bool{
	"run_action": true, "execute_runbook": true, "create_runbook_draft": true,
}

// scoreReport applies only hard conformance rules — facts the relay recorded
// about API behavior, robust to model drift. How the model phrases its answer
// is reported (agent stdout), never scored.
//
// Hard failures: (a) a policy-blocked call, (b) a portal invalid_args
// rejection on a MUTATION (discovery reads are designed to self-heal — every
// rejection carries a recovery pointer, and unsteered models probe read
// filters differently each run; a read-side invalid_args is counted and
// reported, and still hard-fails via rule (d) if repeated identically), (c)
// run_action without a prior get_action for the same action and pack, (d) the
// same failing call repeated more than twice, (e) a started run left
// non-terminal, (f) a required tool or action that never succeeded, and an
// agent process that timed out or exited nonzero.
func scoreReport(item scenario, calls []callRecord, agent agentResult) score {
	result := score{Passed: true}
	succeededTools := map[string]bool{}
	succeededActions := map[string]bool{}
	failedCalls := map[string]int{}
	failedTools := map[string]string{}
	runStatus := map[string]string{}
	startedRuns := map[string]bool{}

	for _, call := range calls {
		result.TotalCalls++
		if call.BlockedByPolicy {
			result.PolicyBlockedCalls++
			result.fail(fmt.Sprintf("the evaluator blocked %s outside the scenario allowlist (%s)", call.Tool, call.ResponseCode))
		}
		if call.ResponseError {
			result.ErrorCalls++
			key := call.Tool + "\x00" + call.ArgumentsDigest
			failedCalls[key]++
			failedTools[key] = call.Tool
		} else {
			succeededTools[call.Tool] = true
		}
		if call.ResponseCode == "invalid_args" {
			result.InvalidArgsCalls++
			if mutationTools[call.Tool] {
				result.fail(call.Tool + " sent schema-invalid arguments (portal rejected them as invalid_args)")
			}
		}
		for _, state := range call.RunStates {
			runStatus[state.RunID] = state.Status
		}
		if call.Tool != "run_action" {
			continue
		}
		if !call.BlockedByPolicy && !call.priorContractMatched {
			result.InspectionViolations++
			result.fail("run_action was sent without a prior successful get_action for the same action and pack")
		}

		if !call.BlockedByPolicy && call.ReasonPlaceholder {
			result.PlaceholderReasons++
			result.fail("run_action carried a placeholder reason instead of an audit-worthy justification")
		}
		// The optional justification chain is measured, never enforced: count how
		// often the agent supplied evidence/expected, but add no failure rule.
		if call.EvidencePresent {
			result.EvidenceGiven++
		}
		if call.ExpectedPresent {
			result.ExpectedGiven++
		}
		if !call.ResponseError {
			succeededActions[call.ActionID] = true
			for _, state := range call.RunStates {
				startedRuns[state.RunID] = true
			}
		}
	}

	repeated := make([]string, 0)
	for key, count := range failedCalls {
		if count > 2 {
			result.RepeatedFailedCalls += count
			repeated = append(repeated, fmt.Sprintf("%s repeated the same failing call %d times", failedTools[key], count))
		}
	}
	sort.Strings(repeated)
	for _, message := range repeated {
		result.fail(message)
	}

	result.RunsStarted = len(startedRuns)
	for runID := range startedRuns {
		if terminalStatuses[runStatus[runID]] {
			result.RunsTerminal++
		} else {
			result.NonTerminalRuns = append(result.NonTerminalRuns, runID)
		}
	}
	sort.Strings(result.NonTerminalRuns)
	if len(result.NonTerminalRuns) > 0 {
		result.fail("runs were not driven to a terminal status via the returned continuations: " + strings.Join(result.NonTerminalRuns, ", "))
	}

	for _, tool := range item.RequiredTools {
		if !succeededTools[tool] {
			result.MissingRequiredTools = append(result.MissingRequiredTools, tool)
		}
	}
	if len(result.MissingRequiredTools) > 0 {
		result.fail("required tools never succeeded: " + strings.Join(result.MissingRequiredTools, ", "))
	}
	for _, action := range item.RequiredActions {
		if !succeededActions[action] {
			result.MissingRequiredActions = append(result.MissingRequiredActions, action)
		}
	}
	if len(result.MissingRequiredActions) > 0 {
		result.fail("required actions never succeeded: " + strings.Join(result.MissingRequiredActions, ", "))
	}

	if agent.TimedOut {
		result.fail("the agent process hit the evaluation timeout")
	} else if agent.ExitCode != 0 {
		result.fail(fmt.Sprintf("the agent process exited %d", agent.ExitCode))
	}
	return result
}

func (s *score) fail(message string) {
	s.Passed = false
	if !slices.Contains(s.Failures, message) {
		s.Failures = append(s.Failures, message)
	}
}

func stringSet(values []string) map[string]bool {
	out := make(map[string]bool, len(values))
	for _, value := range values {
		out[value] = true
	}
	return out
}
