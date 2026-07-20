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

// scoreReport applies only hard conformance rules — facts the relay recorded
// about API behavior, robust to model drift. How the model phrases its answer
// is reported (agent stdout), never scored.
//
// Hard failures: (a) a policy-blocked call, (b) a portal invalid_args
// rejection, (c) run_action without its get_action receipt, (d) the same
// failing call repeated more than twice, (e) a started run left non-terminal,
// (f) a required tool or action that never succeeded, and an agent process
// that timed out or exited nonzero.
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
			result.fail(call.Tool + " sent schema-invalid arguments (portal rejected them as invalid_args)")
		}
		for _, state := range call.RunStates {
			runStatus[state.RunID] = state.Status
		}
		if call.Tool != "run_action" {
			continue
		}
		if !call.BlockedByPolicy {
			if !call.priorContractMatched {
				result.ReceiptViolations++
				result.fail("run_action was sent without a prior successful matching get_action")
			}
			if item.RequireContractRef && !call.ContractRefMatched {
				result.ReceiptViolations++
				result.fail("run_action omitted the contract_ref receipt returned by get_action")
			}
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
