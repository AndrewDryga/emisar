package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"runtime"
	"strings"
)

type cliActionDetail struct {
	ActionID    string          `json:"action_id"`
	PackRef     string          `json:"pack_ref"`
	Title       string          `json:"title"`
	Description string          `json:"description"`
	Risk        string          `json:"risk"`
	SideEffects []string        `json:"side_effects"`
	ArgsSchema  json.RawMessage `json:"args_schema"`
}

type cliCompatibleRunner struct {
	RunnerRef        string `json:"runner_ref"`
	Name             string `json:"name"`
	Hostname         string `json:"hostname"`
	Group            string `json:"group"`
	Status           string `json:"status"`
	EnforceSignature bool   `json:"enforce_signatures"`
}

type cliCompatibleRunnerGroup struct {
	Name    string
	Runners []cliCompatibleRunner
}

func renderCLIGetAction(w io.Writer, raw []byte, account string) (string, bool) {
	var result struct {
		OK                    bool                  `json:"ok"`
		Action                cliActionDetail       `json:"action"`
		CompatibleRunners     []cliCompatibleRunner `json:"compatible_runners"`
		MoreCompatibleRunners bool                  `json:"more_compatible_runners"`
	}
	if json.Unmarshal(raw, &result) != nil || !result.OK || result.Action.ActionID == "" ||
		result.Action.PackRef == "" || result.Action.Risk == "" {
		return "", false
	}

	action := result.Action
	var out strings.Builder
	title := cliResultText(action.Title, maxCLIHumanStringRunes)
	if title == "" {
		title = cliResultText(action.ActionID, 160)
	}
	out.WriteString(cliStyledText(w, "1", title))
	out.WriteByte('\n')
	fmt.Fprintf(&out, "%s · %s\n", cliResultText(action.ActionID, 160), cliFleetRisk(w, action.Risk))
	if description := cliResultText(action.Description, 1_024); description != "" {
		fmt.Fprintf(&out, "\n%s\n", description)
	}
	writeCLIResultField(&out, "Pack", action.PackRef, maxCLIFleetRefRunes)
	if len(action.SideEffects) > 0 {
		fmt.Fprintf(&out, "\n%s\n", cliStyledText(w, "1", "Side effects"))
		for _, sideEffect := range action.SideEffects[:min(len(action.SideEffects), 16)] {
			if sideEffect = cliResultText(sideEffect, 1_024); sideEffect != "" {
				fmt.Fprintf(&out, "  - %s\n", sideEffect)
			}
		}
		if len(action.SideEffects) > 16 {
			fmt.Fprintf(&out, "  %d more side effects; use --json for the complete contract.\n", len(action.SideEffects)-16)
		}
	}
	writeCLIActionArguments(&out, action.ArgsSchema)
	if command := cliActionRunTemplateForOS(action, account, runtime.GOOS); command != "" {
		fmt.Fprintf(&out, "\n%s\n  %s\n", cliStyledText(w, "1", "Run"), command)
	}

	fmt.Fprintf(&out, "\n%s (%d)\n", cliStyledText(w, "1", "Compatible runners"), len(result.CompatibleRunners))
	if len(result.CompatibleRunners) == 0 {
		out.WriteString("  None currently available.\n")
	}
	for _, group := range groupCLICompatibleRunners(result.CompatibleRunners[:min(len(result.CompatibleRunners), maxCLIResultItems)]) {
		fmt.Fprintf(&out, "\n  %s (%d)\n", cliStyledText(w, "1", group.Name), len(group.Runners))
		for _, runner := range group.Runners {
			name := cliResultText(runner.Name, 160)
			if name == "" {
				name = cliResultText(runner.Hostname, 160)
			}
			if name == "" {
				name = cliResultText(runner.RunnerRef, maxCLIFleetRefRunes)
			}
			fmt.Fprintf(&out, "    %s — %s — %s", cliStyledText(w, "1", name), cliResultStatus(w, runner.Status), cliResultText(runner.RunnerRef, maxCLIFleetRefRunes))
			if runner.EnforceSignature {
				out.WriteString(" · signed dispatch required")
			}
			out.WriteByte('\n')
		}
	}
	if result.MoreCompatibleRunners || len(result.CompatibleRunners) > maxCLIResultItems {
		out.WriteString("\nMore compatible runners are available; use --json for continuation data.\n")
	}
	return out.String(), true
}

func groupCLICompatibleRunners(runners []cliCompatibleRunner) []cliCompatibleRunnerGroup {
	groups := make([]cliCompatibleRunnerGroup, 0)
	indexes := make(map[string]int)
	for _, runner := range runners {
		name := strings.TrimSpace(cliResultText(runner.Group, 160))
		if name == "" {
			name = "Ungrouped"
		}
		index, ok := indexes[name]
		if !ok {
			index = len(groups)
			indexes[name] = index
			groups = append(groups, cliCompatibleRunnerGroup{Name: name})
		}
		groups[index].Runners = append(groups[index].Runners, runner)
	}
	return groups
}

func cliActionRunTemplateForOS(action cliActionDetail, account, goos string) string {
	if action.ActionID == "" || action.PackRef == "" || len(action.ActionID) > 160 || len(action.PackRef) > maxCLIFleetRefRunes ||
		terminalSafeLine(action.ActionID) != action.ActionID || terminalSafeLine(action.PackRef) != action.PackRef {
		return ""
	}

	identity, err := json.Marshal(struct {
		ActionID string `json:"action_id"`
		PackRef  string `json:"pack_ref"`
	}{
		ActionID: action.ActionID,
		PackRef:  action.PackRef,
	})
	if err != nil {
		return ""
	}
	arguments := strings.TrimSuffix(string(identity), "}") + `,"runner_refs":["<runner-ref>"],"args":<arguments-json>,"reason":"<reason>"}`
	if len(arguments) > maxCLIFleetCommand || terminalSafeText(arguments) != arguments {
		return ""
	}
	return cliToolInvocationForOS(runActionToolName, account, goos) + " " + shellQuoteForOS(arguments, goos)
}

func writeCLIActionArguments(out *strings.Builder, raw json.RawMessage) {
	if firstJSONByte(raw) != '{' {
		return
	}
	var schema map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if decoder.Decode(&schema) != nil {
		return
	}
	arguments, crossField, ok := describeTopLevelArguments(schema)
	out.WriteString("\nArguments\n")
	if !ok {
		out.WriteString("  Complex schema; use --json for the complete contract.\n")
		return
	}
	if len(arguments) == 0 {
		out.WriteString("  None. Pass {}.\n")
		return
	}
	for _, argument := range arguments {
		status := "optional"
		if argument.Required {
			status = "required"
		}
		fmt.Fprintf(out, "  %s — %s, %s\n", cliResultText(argument.Name, 160), cliResultText(argument.Type, 160), status)
		if argument.Description != "" {
			fmt.Fprintf(out, "    %s\n", cliResultText(argument.Description, maxCLIHumanStringRunes))
		}
		if argument.Constraints != "" {
			fmt.Fprintf(out, "    %s\n", cliResultText(argument.Constraints, maxCLIHumanStringRunes))
		}
	}
	if crossField {
		out.WriteString("  Additional cross-field rules apply; use --json before dispatching.\n")
	}
}

func renderCLIRunAction(w io.Writer, raw []byte, account string) (string, bool) {
	var result struct {
		OK          bool           `json:"ok"`
		OperationID string         `json:"operation_id"`
		ActionID    string         `json:"action_id"`
		PackRef     string         `json:"pack_ref"`
		Runs        []cliRunResult `json:"runs"`
	}
	if json.Unmarshal(raw, &result) != nil || !result.OK || result.OperationID == "" ||
		result.ActionID == "" || result.PackRef == "" {
		return "", false
	}
	for _, run := range result.Runs {
		if run.RunID == "" || run.RunnerRef == "" || run.Status == "" {
			return "", false
		}
	}

	terminal := true
	failed := false
	for _, run := range result.Runs {
		terminal = terminal && cliRunTerminal(run.Status)
		failed = failed || cliRunFailed(run.Status)
	}
	verb := "dispatched to"
	if terminal && !failed {
		verb = "completed on"
	} else if terminal && failed {
		verb = "finished on"
	}
	var out strings.Builder
	fmt.Fprintf(&out, "%s\n", cliStyledText(w, "1", fmt.Sprintf("Action %s %d %s.", verb, len(result.Runs), plural(len(result.Runs), "runner", "runners"))))
	fmt.Fprintf(&out, "\nAction        %s\n", cliResultText(result.ActionID, 160))
	fmt.Fprintf(&out, "Pack          %s\n", cliResultText(result.PackRef, maxCLIFleetRefRunes))
	fmt.Fprintf(&out, "Operation ID  %s\n", cliResultText(result.OperationID, maxCLIFleetRefRunes))
	if command := cliOperationInspectCommandForOS(result.OperationID, account, runtime.GOOS); command != "" {
		fmt.Fprintf(&out, "Inspect       %s\n", command)
	}
	if len(result.Runs) > 0 {
		out.WriteByte('\n')
		out.WriteString(renderCLIRuns(w, result.Runs, true))
	}
	return out.String(), true
}

func cliOperationInspectCommandForOS(operationID, account, goos string) string {
	if operationID == "" || len(operationID) > maxCLIFleetRefRunes ||
		terminalSafeLine(operationID) != operationID {
		return ""
	}
	arguments, err := json.Marshal(struct {
		OperationID string `json:"operation_id"`
	}{OperationID: operationID})
	if err != nil || len(arguments) > maxCLIFleetCommand || terminalSafeText(string(arguments)) != string(arguments) {
		return ""
	}
	return cliToolInvocationForOS(getOperationToolName, account, goos) + " " + shellQuoteForOS(string(arguments), goos)
}

func renderCLIRecentRuns(w io.Writer, raw []byte) (string, bool) {
	var result struct {
		OK         bool            `json:"ok"`
		Runs       []cliRunResult  `json:"runs"`
		NextCursor json.RawMessage `json:"next_cursor"`
	}
	if json.Unmarshal(raw, &result) != nil || !result.OK {
		return "", false
	}
	for _, run := range result.Runs {
		if run.RunID == "" || run.Status == "" {
			return "", false
		}
	}
	if len(result.Runs) == 0 {
		return "No matching runs found.\n", true
	}

	var out strings.Builder
	fmt.Fprintf(&out, "%d recent %s\n\n", len(result.Runs), plural(len(result.Runs), "run", "runs"))
	out.WriteString(renderCLIRuns(w, result.Runs, true))
	if hasJSONValue(result.NextCursor) {
		out.WriteString("\nMore runs are available; use --json to continue with the returned cursor.\n")
	}
	return out.String(), true
}

func renderCLIGetOperation(w io.Writer, raw []byte, account string) (string, bool) {
	var result struct {
		OK        bool `json:"ok"`
		Operation struct {
			OperationID        string            `json:"operation_id"`
			Kind               string            `json:"kind"`
			ActionID           string            `json:"action_id"`
			PackRef            string            `json:"pack_ref"`
			RunbookExecutionID string            `json:"runbook_execution_id"`
			RunbookRef         string            `json:"runbook_ref"`
			DefinitionSHA256   string            `json:"definition_sha256"`
			DraftID            string            `json:"draft_id"`
			Slug               string            `json:"slug"`
			Status             string            `json:"status"`
			LiveRef            string            `json:"live_ref"`
			ReviewURL          string            `json:"review_url"`
			Next               cliToolResultNext `json:"next"`
		} `json:"operation"`
	}
	if json.Unmarshal(raw, &result) != nil || !result.OK ||
		result.Operation.OperationID == "" || result.Operation.Kind == "" {
		return "", false
	}
	op := result.Operation
	var out strings.Builder
	fmt.Fprintf(&out, "%s\n", cliStyledText(w, "1", "Operation found"))
	fmt.Fprintf(&out, "\nOperation ID  %s\n", cliResultText(op.OperationID, maxCLIFleetRefRunes))
	writeCLIResultField(&out, "Kind", strings.ReplaceAll(op.Kind, "_", " "), 80)
	writeCLIResultField(&out, "Action", op.ActionID, 160)
	writeCLIResultField(&out, "Pack", op.PackRef, maxCLIFleetRefRunes)
	writeCLIResultField(&out, "Runbook", op.RunbookRef, maxCLIFleetRefRunes)
	writeCLIResultField(&out, "Execution ID", op.RunbookExecutionID, maxCLIFleetRefRunes)
	writeCLIResultField(&out, "Draft", op.Slug, 160)
	writeCLIResultField(&out, "Draft ID", op.DraftID, maxCLIFleetRefRunes)
	writeCLIResultField(&out, "Definition", op.DefinitionSHA256, maxCLIFleetRefRunes)
	writeCLIResultField(&out, "Live release", op.LiveRef, maxCLIFleetRefRunes)
	writeCLIResultField(&out, "Review", op.ReviewURL, maxCLIFleetCommand)
	if op.Status != "" {
		fmt.Fprintf(&out, "  Status  %s\n", cliResultStatus(w, op.Status))
	}
	if command := cliOperationContinuation(op.OperationID, op.RunbookExecutionID, op.Next, account); command != "" {
		fmt.Fprintf(&out, "\nNext  %s\n", command)
	}
	return out.String(), true
}

func cliOperationContinuation(operationID, executionID string, next cliToolResultNext, account string) string {
	var arguments struct {
		OperationID        string `json:"operation_id"`
		RunbookExecutionID string `json:"runbook_execution_id"`
	}
	if json.Unmarshal(next.Arguments, &arguments) != nil {
		return ""
	}
	switch next.Tool {
	case recentRunsToolName:
		if arguments.OperationID != operationID {
			return ""
		}
	case waitForRunToolName:
		if executionID == "" || arguments.RunbookExecutionID != executionID {
			return ""
		}
	default:
		return ""
	}
	return cliFleetNextCommandForOS(next, next.Tool, account, runtime.GOOS)
}

func renderCLIWaitForRun(w io.Writer, raw []byte) (string, bool) {
	var envelope struct {
		OK               bool            `json:"ok"`
		Run              json.RawMessage `json:"run"`
		Execution        json.RawMessage `json:"execution"`
		ExecutionOutputs json.RawMessage `json:"execution_outputs"`
	}
	if json.Unmarshal(raw, &envelope) != nil || !envelope.OK {
		return "", false
	}
	switch {
	case firstJSONByte(envelope.Run) == '{':
		var run cliRunResult
		if json.Unmarshal(envelope.Run, &run) != nil || run.RunID == "" || run.Status == "" {
			return "", false
		}
		return renderCLIRuns(w, []cliRunResult{run}, true), true
	case firstJSONByte(envelope.Execution) == '{':
		return renderCLIRunbookExecution(w, envelope.Execution)
	case firstJSONByte(envelope.ExecutionOutputs) == '{':
		return renderCLIRunbookOutputs(w, envelope.ExecutionOutputs)
	default:
		return "", false
	}
}

func cliRunTerminal(status string) bool {
	switch status {
	case "success", "failed", "error", "validation_failed", "unknown_action",
		"cancelled", "timed_out", "refused", "denied":
		return true
	default:
		return false
	}
}

func cliRunFailed(status string) bool {
	switch status {
	case "failed", "error", "validation_failed", "unknown_action", "cancelled",
		"timed_out", "refused", "denied":
		return true
	default:
		return false
	}
}
