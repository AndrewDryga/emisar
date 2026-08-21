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

const (
	maxCLIRunbookItems       = 256
	maxCLIRunbookResultPages = 256
)

type cliRunbookItemIdentity struct {
	stepID    string
	runnerRef string
	actionID  string
	packRef   string
}

type cliRunbookExpectedRun struct {
	identity cliRunbookItemIdentity
	status   string
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
	if !cliToolContinuationPresent(execution.Next) &&
		!cliToolContinuationPresent(execution.OutputsNext) &&
		!cliToolContinuationPresent(execution.RunsNext) {
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

	progress := newCLIRunbookProgressDisplay(stdout, execution.Stages)
	if cliToolContinuationPresent(execution.Next) {
		if progress.redraw && len(execution.Stages) > 0 {
			_, _ = io.WriteString(stdout, "\nWaiting for completion. Ctrl-C stops waiting; the runbook keeps running.\n\nProgress\n")
			progress.writeInitial(execution.Stages)
		} else {
			if len(execution.Stages) > 0 {
				_, _ = io.WriteString(stdout, "\nProgress\n")
				progress.writeInitial(execution.Stages)
			}
			_, _ = io.WriteString(stdout, "\nWaiting for completion. Ctrl-C stops waiting; the runbook keeps running.\n")
		}
	}
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
			!sameCLIRunbookLayout(initial.Execution, envelope.Execution) ||
			envelope.Execution.Status == "" {
			return b.writeCLIFollowFailure(stderr, operationID, errors.New("wait_for_run returned a different or invalid runbook execution"))
		}
		execution = envelope.Execution
		if cliToolContinuationPresent(execution.Next) &&
			!validCLIExecutionContinuation(execution.Next, execution.RunbookExecutionID) {
			return b.writeCLIFollowFailure(stderr, operationID, errors.New("the server changed or malformed the runbook wait continuation"))
		}
		progress.writeUpdate(execution.Stages)
	}
	if !cliRunbookTerminal(execution.Status) {
		return b.writeCLIFollowFailure(stderr, operationID, errors.New("wait_for_run stopped before the runbook reached a terminal status"))
	}

	runs, err := b.collectCLIRunbookResults(ctx, operationID, execution)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return b.writeCLIRunbookResultsCancelled(stderr, operationID)
		}
		return b.writeCLIFollowFailure(stderr, operationID, err)
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

	_, _ = io.WriteString(stdout, "\n"+renderCLIRunbookCompletion(stdout, execution))
	if rendered := renderCLIRunbookResults(stdout, execution, runs, b.cliAccount); rendered != "" {
		_, _ = io.WriteString(stdout, "\n"+rendered)
	}
	for _, page := range outputPages {
		_, _ = io.WriteString(stdout, "\n"+page)
	}
	if cliRunbookFailed(execution.Status) {
		return 1
	}
	return 0
}

func (b *bridge) collectCLIRunbookResults(
	ctx context.Context,
	operationID string,
	execution cliRunbookExecution,
) (map[string]cliRunResult, error) {
	expected, identities, err := expectedCLIRunbookRuns(execution)
	if err != nil {
		return nil, err
	}
	if len(expected) == 0 {
		return map[string]cliRunResult{}, nil
	}
	base, ok := parseCLIRunbookRunsNext(execution.RunsNext, execution.RunbookExecutionID)
	if !ok {
		return nil, errors.New("the runbook response contained an invalid action-results continuation")
	}

	found := make(map[string]cliRunResult, len(expected))
	seenRuns := make(map[string]struct{})
	seenCursors := make(map[string]struct{})
	next := execution.RunsNext
	for pageNumber := 0; pageNumber < maxCLIRunbookResultPages; pageNumber++ {
		pageRaw, callErr := b.callCLIContinuation(ctx, next)
		if callErr != nil {
			return nil, callErr
		}
		var page struct {
			OK         bool            `json:"ok"`
			Runs       []cliRunResult  `json:"runs"`
			NextCursor json.RawMessage `json:"next_cursor"`
		}
		if json.Unmarshal(pageRaw, &page) != nil || !page.OK || len(page.Runs) > 100 {
			return nil, errors.New("recent_runs returned invalid runbook action results")
		}
		for _, run := range page.Runs {
			identity := cliRunbookItemIdentity{
				stepID: run.StepID, runnerRef: run.RunnerRef,
				actionID: run.ActionID, packRef: run.PackRef,
			}
			if run.RunID == "" || run.OperationID != operationID ||
				run.RunbookExecutionID != execution.RunbookExecutionID ||
				!cliRunTerminal(run.Status) || run.EmittedStdoutBytes < 0 || run.EmittedStderrBytes < 0 ||
				(run.OutputComplete != nil && *run.OutputComplete) {
				return nil, errors.New("recent_runs returned a different or invalid runbook action")
			}
			if cliToolContinuationPresent(run.Next) && !validCLIRunContinuation(run.Next, run.RunID) {
				return nil, errors.New("recent_runs returned an invalid action-output continuation")
			}
			if _, belongs := identities[identity]; !belongs {
				return nil, errors.New("recent_runs returned a run outside this runbook execution")
			}
			if _, duplicate := seenRuns[run.RunID]; duplicate {
				return nil, errors.New("recent_runs repeated a run while loading runbook results")
			}
			seenRuns[run.RunID] = struct{}{}
			if expectedRun, wanted := expected[run.RunID]; wanted {
				if identity != expectedRun.identity || run.Status != expectedRun.status {
					return nil, errors.New("recent_runs changed a runbook action identity")
				}
				found[run.RunID] = run
			}
		}

		cursor, cursorOK := cliRunbookNextCursor(page.NextCursor)
		if !cursorOK {
			return nil, errors.New("recent_runs returned an invalid runbook results cursor")
		}
		if len(found) == len(expected) {
			return found, nil
		}
		if cursor == "" {
			return nil, errors.New("recent_runs ended before every runbook action result was returned")
		}
		if _, duplicate := seenCursors[cursor]; duplicate {
			return nil, errors.New("recent_runs repeated a cursor while loading runbook results")
		}
		seenCursors[cursor] = struct{}{}
		next, ok = cliRunbookRunsPageNext(base, cursor)
		if !ok {
			return nil, errors.New("could not preserve the runbook results continuation")
		}
	}
	return nil, errors.New("runbook action results exceeded the safe pagination limit")
}

func expectedCLIRunbookRuns(execution cliRunbookExecution) (
	map[string]cliRunbookExpectedRun,
	map[cliRunbookItemIdentity]struct{},
	error,
) {
	expected := make(map[string]cliRunbookExpectedRun)
	identities := make(map[cliRunbookItemIdentity]struct{})
	itemCount := 0
	for _, stage := range execution.Stages {
		for _, item := range stage.Items {
			itemCount++
			identity := cliRunbookItemIdentity{
				stepID: item.StepID, runnerRef: item.RunnerRef,
				actionID: item.ActionID, packRef: item.PackRef,
			}
			if item.StepID == "" || item.RunnerRef == "" || item.ActionID == "" || item.PackRef == "" ||
				!cliRunbookItemTerminal(item.Status) {
				return nil, nil, errors.New("the runbook response contained an invalid action identity")
			}
			identities[identity] = struct{}{}
			if item.LatestAttempt == nil {
				continue
			}
			if item.LatestAttempt.RunID == "" || !cliRunTerminal(item.LatestAttempt.Status) {
				return nil, nil, errors.New("the terminal runbook response contained an invalid latest action attempt")
			}
			if _, duplicate := expected[item.LatestAttempt.RunID]; duplicate {
				return nil, nil, errors.New("the runbook response repeated a latest action attempt")
			}
			expected[item.LatestAttempt.RunID] = cliRunbookExpectedRun{
				identity: identity,
				status:   item.LatestAttempt.Status,
			}
		}
	}
	if itemCount > maxCLIRunbookItems {
		return nil, nil, errors.New("the runbook response exceeded the published 256-action limit")
	}
	return expected, identities, nil
}

func cliRunbookItemTerminal(status string) bool {
	switch status {
	case "succeeded", "failed", "cancelled":
		return true
	default:
		return false
	}
}

type cliRunbookRunsArguments struct {
	RunbookExecutionID string `json:"runbook_execution_id"`
	Limit              int    `json:"limit"`
}

func parseCLIRunbookRunsNext(next cliToolResultNext, executionID string) (cliRunbookRunsArguments, bool) {
	if next.Tool != recentRunsToolName || firstJSONByte(next.Arguments) != '{' ||
		len(next.Arguments) > maxCLIFleetCommand || validateStrictJSON(next.Arguments) != nil {
		return cliRunbookRunsArguments{}, false
	}
	var fields map[string]json.RawMessage
	var arguments cliRunbookRunsArguments
	if json.Unmarshal(next.Arguments, &fields) != nil || len(fields) != 2 ||
		json.Unmarshal(next.Arguments, &arguments) != nil ||
		arguments.RunbookExecutionID != executionID || arguments.Limit < 1 || arguments.Limit > 100 {
		return cliRunbookRunsArguments{}, false
	}
	if _, ok := fields["runbook_execution_id"]; !ok {
		return cliRunbookRunsArguments{}, false
	}
	if _, ok := fields["limit"]; !ok {
		return cliRunbookRunsArguments{}, false
	}
	return arguments, true
}

func cliRunbookNextCursor(raw json.RawMessage) (string, bool) {
	if firstJSONByte(raw) == 0 || firstJSONByte(raw) == 'n' {
		return "", true
	}
	var cursor string
	if json.Unmarshal(raw, &cursor) != nil || cursor == "" || len(cursor) > 4096 {
		return "", false
	}
	return cursor, true
}

func cliRunbookRunsPageNext(base cliRunbookRunsArguments, cursor string) (cliToolResultNext, bool) {
	arguments, err := json.Marshal(struct {
		RunbookExecutionID string `json:"runbook_execution_id"`
		Limit              int    `json:"limit"`
		Cursor             string `json:"cursor"`
	}{base.RunbookExecutionID, base.Limit, cursor})
	if err != nil || len(arguments) > maxCLIFleetCommand {
		return cliToolResultNext{}, false
	}
	return cliToolResultNext{Tool: recentRunsToolName, Arguments: arguments}, true
}

func sameCLIRunbookIdentity(initial, next cliRunbookExecution) bool {
	return next.RunbookExecutionID == initial.RunbookExecutionID &&
		next.RunbookRef == initial.RunbookRef &&
		next.Kind == initial.Kind &&
		next.DefinitionSHA256 == initial.DefinitionSHA256
}

func sameCLIRunbookLayout(initial, next cliRunbookExecution) bool {
	if len(initial.Stages) != len(next.Stages) {
		return false
	}
	for stageIndex := range initial.Stages {
		beforeStage := initial.Stages[stageIndex]
		afterStage := next.Stages[stageIndex]
		if beforeStage.StageID != afterStage.StageID || beforeStage.Title != afterStage.Title ||
			beforeStage.Mode != afterStage.Mode || beforeStage.MaxParallel != afterStage.MaxParallel ||
			len(beforeStage.Items) != len(afterStage.Items) {
			return false
		}
		for itemIndex := range beforeStage.Items {
			beforeItem := beforeStage.Items[itemIndex]
			afterItem := afterStage.Items[itemIndex]
			if beforeItem.ItemID != afterItem.ItemID || beforeItem.StepID != afterItem.StepID ||
				beforeItem.RunnerRef != afterItem.RunnerRef || beforeItem.ActionID != afterItem.ActionID ||
				beforeItem.PackRef != afterItem.PackRef || beforeItem.Risk != afterItem.Risk {
				return false
			}
		}
	}
	return true
}

func (b *bridge) callCLIContinuation(ctx context.Context, next cliToolResultNext) (json.RawMessage, error) {
	continuation := "observation continuation"
	if next.Tool == waitForRunToolName || next.Tool == recentRunsToolName {
		continuation = next.Tool
	}
	response, _, err := b.cliRoundTripContext(ctx, "tools/call", next.Tool, next.Arguments)
	if err != nil {
		return nil, fmt.Errorf("observe running work: %w", err)
	}
	if len(response.Error) > 0 {
		return nil, fmt.Errorf("%s returned an MCP error", continuation)
	}
	var result struct {
		StructuredContent json.RawMessage `json:"structuredContent"`
		IsError           bool            `json:"isError"`
	}
	if json.Unmarshal(response.Result, &result) != nil || firstJSONByte(result.StructuredContent) != '{' {
		return nil, fmt.Errorf("%s returned an invalid tool response", continuation)
	}
	if result.IsError {
		var failure struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(result.StructuredContent, &failure) == nil && failure.Error.Message != "" {
			return nil, fmt.Errorf("%s: %s", continuation, cliResultText(failure.Error.Message, maxCLIHumanStringRunes))
		}
		return nil, fmt.Errorf("%s reported an error", continuation)
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

func (b *bridge) writeCLIRunbookResultsCancelled(stderr io.Writer, operationID string) int {
	writeCLIDiagnostic(stderr, cliDiagnostic{
		Kind:    cliDiagnosticWarning,
		Summary: "Stopped loading runbook results",
		Details: []string{"The runbook was not cancelled. Its result remains available in Emisar."},
		Next:    []string{b.cliOperationRecoveryCommand(operationID)},
	})
	return 130
}

func (b *bridge) writeCLIFollowFailure(stderr io.Writer, operationID string, followErr error) int {
	writeCLIDiagnostic(stderr, cliDiagnostic{
		Kind:    cliDiagnosticError,
		Summary: "Could not finish observing the operation",
		Details: []string{followErr.Error(), "The mutation was not retried and may still be running."},
		Next:    []string{b.cliOperationRecoveryCommand(operationID)},
	})
	return 1
}

func (b *bridge) cliOperationRecoveryCommand(operationID string) string {
	return cliOperationInspectCommandForOS(operationID, b.cliAccount, runtime.GOOS)
}
