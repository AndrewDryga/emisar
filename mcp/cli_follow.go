package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"runtime"
	"sync"
)

type cliFollowedRun struct {
	index int
	run   cliRunResult
	err   error
}

func validateCLIHumanMutation(toolName, operationID string, raw []byte) error {
	switch toolName {
	case runActionToolName:
		var result struct {
			OK          bool           `json:"ok"`
			OperationID string         `json:"operation_id"`
			ActionID    string         `json:"action_id"`
			PackRef     string         `json:"pack_ref"`
			Runs        []cliRunResult `json:"runs"`
		}
		if json.Unmarshal(raw, &result) != nil || !result.OK || result.OperationID != operationID ||
			result.ActionID == "" || result.PackRef == "" || len(result.Runs) == 0 {
			return errors.New("the action response did not match its transport operation ID")
		}
		for _, run := range result.Runs {
			if run.RunID == "" || run.OperationID != operationID || run.RunnerRef == "" ||
				run.ActionID != result.ActionID || run.PackRef != result.PackRef || run.Status == "" {
				return errors.New("the action response contained an invalid run identity")
			}
		}
	case executeRunbookToolName:
		var result struct {
			OK          bool                `json:"ok"`
			OperationID string              `json:"operation_id"`
			Execution   cliRunbookExecution `json:"execution"`
		}
		if json.Unmarshal(raw, &result) != nil || !result.OK || result.OperationID != operationID ||
			result.Execution.RunbookExecutionID == "" || result.Execution.RunbookRef == "" ||
			result.Execution.Kind == "" || result.Execution.DefinitionSHA256 == "" ||
			result.Execution.Status == "" {
			return errors.New("the runbook response did not match its transport operation ID")
		}
	case createRunbookDraftToolName, updateRunbookDraftToolName:
		var result struct {
			OK          bool   `json:"ok"`
			OperationID string `json:"operation_id"`
			DraftID     string `json:"draft_id"`
			Slug        string `json:"slug"`
			Status      string `json:"status"`
		}
		if json.Unmarshal(raw, &result) != nil || !result.OK || result.OperationID != operationID ||
			result.DraftID == "" || result.Slug == "" || result.Status != "draft" {
			return errors.New("the runbook draft response did not match its transport operation ID")
		}
	}
	return nil
}

func (b *bridge) followCLIMutation(
	ctx context.Context,
	toolName, operationID string,
	raw []byte,
	stdout, stderr io.Writer,
) (bool, int) {
	switch toolName {
	case runActionToolName:
		return true, b.followCLIAction(ctx, operationID, raw, stdout, stderr)
	case executeRunbookToolName:
		return true, b.followCLIRunbook(ctx, operationID, raw, stdout, stderr)
	default:
		return false, 0
	}
}

func (b *bridge) followCLIAction(
	ctx context.Context,
	operationID string,
	raw []byte,
	stdout, stderr io.Writer,
) int {
	if err := validateCLIHumanMutation(runActionToolName, operationID, raw); err != nil {
		return b.writeCLIFollowFailure(stderr, operationID, err)
	}
	var initial struct {
		OK          bool           `json:"ok"`
		OperationID string         `json:"operation_id"`
		Runs        []cliRunResult `json:"runs"`
	}
	_ = json.Unmarshal(raw, &initial)

	pending := make([]struct {
		index int
		run   cliRunResult
	}, 0, len(initial.Runs))
	failed := false
	for index, run := range initial.Runs {
		if cliToolContinuationPresent(run.Next) {
			if !validCLIRunContinuation(run.Next, run.RunID) {
				return b.writeCLIFollowFailure(stderr, operationID, errors.New("the action response contained an invalid wait continuation"))
			}
			pending = append(pending, struct {
				index int
				run   cliRunResult
			}{index: index, run: run})
		} else if !cliRunTerminal(run.Status) {
			return b.writeCLIFollowFailure(stderr, operationID, errors.New("a non-terminal run had no wait continuation"))
		}
		failed = failed || cliRunFailed(run.Status)
	}
	if len(pending) == 0 {
		if failed {
			return 1
		}
		return 0
	}

	_, _ = io.WriteString(stdout, "\nWaiting for completion. Ctrl-C stops waiting; the action keeps running.\n")
	results := make(chan cliFollowedRun, len(pending))
	semaphore := make(chan struct{}, maxConcurrentRequests)
	followCtx, stopFollowing := context.WithCancel(ctx)
	defer stopFollowing()
	var waits sync.WaitGroup
	for _, target := range pending {
		waits.Add(1)
		go func(index int, run cliRunResult) {
			defer waits.Done()
			select {
			case semaphore <- struct{}{}:
				defer func() { <-semaphore }()
			case <-followCtx.Done():
				results <- cliFollowedRun{index: index, run: run, err: followCtx.Err()}
				return
			}
			followed, err := b.followOneCLIRun(followCtx, operationID, run)
			if err != nil {
				stopFollowing()
			}
			results <- cliFollowedRun{index: index, run: followed, err: err}
		}(target.index, target.run)
	}
	waits.Wait()
	close(results)

	completed := append([]cliRunResult(nil), initial.Runs...)
	var followErr error
	for result := range results {
		completed[result.index] = result.run
		if result.err != nil && !errors.Is(result.err, context.Canceled) && followErr == nil {
			followErr = result.err
		}
	}
	if ctx.Err() != nil {
		return b.writeCLIWaitCancelled(stderr, operationID, "action")
	}
	if followErr != nil {
		return b.writeCLIFollowFailure(stderr, operationID, followErr)
	}

	_, _ = io.WriteString(stdout, "\nFinal status\n\n")
	_, _ = io.WriteString(stdout, renderCLIRuns(stdout, completed, true))
	failed = false
	for _, run := range completed {
		failed = failed || cliRunFailed(run.Status)
	}
	if failed {
		return 1
	}
	return 0
}

func (b *bridge) followOneCLIRun(
	ctx context.Context,
	operationID string,
	initial cliRunResult,
) (cliRunResult, error) {
	current := initial
	var output []cliRunOutput
	for cliToolContinuationPresent(current.Next) {
		if !validCLIRunContinuation(current.Next, initial.RunID) {
			return current, errors.New("the server changed or malformed the run wait continuation")
		}
		raw, err := b.callCLIContinuation(ctx, current.Next)
		if err != nil {
			return current, err
		}
		var envelope struct {
			OK  bool         `json:"ok"`
			Run cliRunResult `json:"run"`
		}
		if json.Unmarshal(raw, &envelope) != nil || !envelope.OK ||
			!sameCLIRunIdentity(initial, envelope.Run) || envelope.Run.Status == "" {
			return current, errors.New("wait_for_run returned a different or invalid run")
		}
		output = appendCLIRunOutput(output, envelope.Run.Output...)
		current = envelope.Run
	}
	if !cliRunTerminal(current.Status) {
		return current, errors.New("wait_for_run stopped before the run reached a terminal status")
	}
	current.Output = output
	return current, nil
}

func sameCLIRunIdentity(initial, next cliRunResult) bool {
	return next.RunID == initial.RunID &&
		next.OperationID == initial.OperationID &&
		next.ActionID == initial.ActionID &&
		next.PackRef == initial.PackRef &&
		next.RunnerRef == initial.RunnerRef &&
		next.RunbookExecutionID == initial.RunbookExecutionID &&
		next.StepID == initial.StepID
}

func (b *bridge) followCLIRunbook(
	ctx context.Context,
	operationID string,
	raw []byte,
	stdout, stderr io.Writer,
) int {
	if err := validateCLIHumanMutation(executeRunbookToolName, operationID, raw); err != nil {
		return b.writeCLIFollowFailure(stderr, operationID, err)
	}
	var initial struct {
		OK          bool                `json:"ok"`
		OperationID string              `json:"operation_id"`
		Execution   cliRunbookExecution `json:"execution"`
	}
	_ = json.Unmarshal(raw, &initial)
	execution := initial.Execution
	if !cliToolContinuationPresent(execution.Next) && !cliToolContinuationPresent(execution.OutputsNext) {
		if cliRunbookFailed(execution.Status) {
			return 1
		}
		if !cliRunbookTerminal(execution.Status) {
			return b.writeCLIFollowFailure(stderr, operationID, errors.New("a non-terminal runbook execution had no wait continuation"))
		}
		return 0
	}
	if cliToolContinuationPresent(execution.Next) &&
		!validCLIExecutionContinuation(execution.Next, execution.RunbookExecutionID) {
		return b.writeCLIFollowFailure(stderr, operationID, errors.New("the runbook response contained an invalid wait continuation"))
	}

	_, _ = io.WriteString(stdout, "\nWaiting for completion. Ctrl-C stops waiting; the runbook keeps running.\n")
	for cliToolContinuationPresent(execution.Next) {
		raw, err := b.callCLIContinuation(ctx, execution.Next)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return b.writeCLIWaitCancelled(stderr, operationID, "runbook")
			}
			return b.writeCLIFollowFailure(stderr, operationID, err)
		}
		var envelope struct {
			OK        bool                `json:"ok"`
			Execution cliRunbookExecution `json:"execution"`
		}
		if json.Unmarshal(raw, &envelope) != nil || !envelope.OK ||
			!sameCLIRunbookIdentity(initial.Execution, envelope.Execution) ||
			envelope.Execution.Status == "" {
			return b.writeCLIFollowFailure(stderr, operationID, errors.New("wait_for_run returned a different or invalid runbook execution"))
		}
		execution = envelope.Execution
		if cliToolContinuationPresent(execution.Next) &&
			!validCLIExecutionContinuation(execution.Next, execution.RunbookExecutionID) {
			return b.writeCLIFollowFailure(stderr, operationID, errors.New("the server changed or malformed the runbook wait continuation"))
		}
	}
	if !cliRunbookTerminal(execution.Status) {
		return b.writeCLIFollowFailure(stderr, operationID, errors.New("wait_for_run stopped before the runbook reached a terminal status"))
	}

	var outputPages []string
	previousTotal := -1
	previousRemaining := -1
	next := execution.OutputsNext
	for cliToolContinuationPresent(next) {
		if !validCLIExecutionContinuation(next, execution.RunbookExecutionID) {
			return b.writeCLIFollowFailure(stderr, operationID, errors.New("the runbook response contained an invalid output continuation"))
		}
		pageRaw, err := b.callCLIContinuation(ctx, next)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return b.writeCLIWaitCancelled(stderr, operationID, "runbook")
			}
			return b.writeCLIFollowFailure(stderr, operationID, err)
		}
		var envelope struct {
			OK      bool            `json:"ok"`
			Outputs json.RawMessage `json:"execution_outputs"`
		}
		if json.Unmarshal(pageRaw, &envelope) != nil || !envelope.OK {
			return b.writeCLIFollowFailure(stderr, operationID, errors.New("wait_for_run returned different or invalid runbook outputs"))
		}
		page, valid := parseCLIRunbookOutputs(envelope.Outputs)
		if !valid || page.RunbookExecutionID != execution.RunbookExecutionID ||
			(previousTotal >= 0 && page.TotalCount != previousTotal) ||
			(previousTotal < 0 && page.ReturnedCount+page.RemainingCount != page.TotalCount) ||
			(previousRemaining >= 0 && page.ReturnedCount+page.RemainingCount != previousRemaining) {
			return b.writeCLIFollowFailure(stderr, operationID, errors.New("wait_for_run returned different or invalid runbook outputs"))
		}
		rendered, _ := renderCLIRunbookOutputs(stdout, envelope.Outputs)
		outputPages = append(outputPages, rendered)
		previousTotal = page.TotalCount
		previousRemaining = page.RemainingCount
		next = page.Next
	}

	_, _ = io.WriteString(stdout, "\nFinal status\n\n")
	executionRaw, _ := json.Marshal(execution)
	if rendered, ok := renderCLIRunbookExecution(stdout, executionRaw); ok {
		_, _ = io.WriteString(stdout, rendered)
	}
	for _, page := range outputPages {
		_, _ = io.WriteString(stdout, "\n"+page)
	}
	if cliRunbookFailed(execution.Status) {
		return 1
	}
	return 0
}

func sameCLIRunbookIdentity(initial, next cliRunbookExecution) bool {
	return next.RunbookExecutionID == initial.RunbookExecutionID &&
		next.RunbookRef == initial.RunbookRef &&
		next.Kind == initial.Kind &&
		next.DefinitionSHA256 == initial.DefinitionSHA256
}

func (b *bridge) callCLIContinuation(ctx context.Context, next cliToolResultNext) (json.RawMessage, error) {
	response, _, err := b.cliRoundTripContext(ctx, "tools/call", next.Tool, next.Arguments)
	if err != nil {
		return nil, fmt.Errorf("observe running work: %w", err)
	}
	if len(response.Error) > 0 {
		return nil, errors.New("wait_for_run returned an MCP error")
	}
	var result struct {
		StructuredContent json.RawMessage `json:"structuredContent"`
		IsError           bool            `json:"isError"`
	}
	if json.Unmarshal(response.Result, &result) != nil || firstJSONByte(result.StructuredContent) != '{' {
		return nil, errors.New("wait_for_run returned an invalid tool response")
	}
	if result.IsError {
		var failure struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(result.StructuredContent, &failure) == nil && failure.Error.Message != "" {
			return nil, fmt.Errorf("wait_for_run: %s", cliResultText(failure.Error.Message, maxCLIHumanStringRunes))
		}
		return nil, errors.New("wait_for_run reported an error")
	}
	return result.StructuredContent, nil
}

func validCLIRunContinuation(next cliToolResultNext, runID string) bool {
	if !validCLIWaitContinuation(next) {
		return false
	}
	var arguments map[string]json.RawMessage
	if json.Unmarshal(next.Arguments, &arguments) != nil {
		return false
	}
	for key := range arguments {
		if key != "run_id" && key != "cursor" && key != "timeout" {
			return false
		}
	}
	if !validCLIOptionalString(arguments, "cursor") || !validCLIOptionalString(arguments, "timeout") {
		return false
	}
	var returnedID string
	return json.Unmarshal(arguments["run_id"], &returnedID) == nil && returnedID == runID
}

func validCLIExecutionContinuation(next cliToolResultNext, executionID string) bool {
	if !validCLIWaitContinuation(next) {
		return false
	}
	var arguments map[string]json.RawMessage
	if json.Unmarshal(next.Arguments, &arguments) != nil {
		return false
	}
	for key := range arguments {
		if key != "runbook_execution_id" && key != "cursor" && key != "timeout" {
			return false
		}
	}
	if !validCLIOptionalString(arguments, "cursor") || !validCLIOptionalString(arguments, "timeout") {
		return false
	}
	var returnedID string
	return json.Unmarshal(arguments["runbook_execution_id"], &returnedID) == nil && returnedID == executionID
}

func validCLIWaitContinuation(next cliToolResultNext) bool {
	return next.Tool == waitForRunToolName && terminalSafeLine(next.Tool) == next.Tool &&
		firstJSONByte(next.Arguments) == '{' && len(next.Arguments) <= maxCLIFleetCommand &&
		validateStrictJSON(next.Arguments) == nil
}

func validCLIOptionalString(arguments map[string]json.RawMessage, key string) bool {
	raw, ok := arguments[key]
	if !ok {
		return true
	}
	var value string
	return json.Unmarshal(raw, &value) == nil
}

func appendCLIRunOutput(outputs []cliRunOutput, additions ...cliRunOutput) []cliRunOutput {
	for _, addition := range additions {
		if len(outputs) > 0 && outputs[len(outputs)-1].Stream == addition.Stream {
			outputs[len(outputs)-1].Text += addition.Text
			continue
		}
		outputs = append(outputs, addition)
	}
	return outputs
}

func cliToolContinuationPresent(next cliToolResultNext) bool {
	return next.Tool != "" || firstJSONByte(next.Arguments) != 0
}

func cliRunbookTerminal(status string) bool {
	switch status {
	case "succeeded", "halted", "cancelled":
		return true
	default:
		return false
	}
}

func cliRunbookFailed(status string) bool {
	return status == "halted" || status == "cancelled"
}

func (b *bridge) writeCLIWaitCancelled(stderr io.Writer, operationID, kind string) int {
	writeCLIDiagnostic(stderr, cliDiagnostic{
		Kind:    cliDiagnosticWarning,
		Summary: "Stopped waiting",
		Details: []string{fmt.Sprintf("The %s was not cancelled and may still be running.", kind)},
		Next:    []string{b.cliOperationRecoveryCommand(operationID)},
	})
	return 130
}

func (b *bridge) writeCLIFollowFailure(stderr io.Writer, operationID string, followErr error) int {
	writeCLIDiagnostic(stderr, cliDiagnostic{
		Kind:    cliDiagnosticError,
		Summary: "Could not finish waiting for the operation",
		Details: []string{followErr.Error(), "The mutation was not retried and may still be running."},
		Next:    []string{b.cliOperationRecoveryCommand(operationID)},
	})
	return 1
}

func (b *bridge) cliOperationRecoveryCommand(operationID string) string {
	return cliOperationInspectCommandForOS(operationID, b.cliAccount, runtime.GOOS)
}
