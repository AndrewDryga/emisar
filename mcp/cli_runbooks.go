package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"runtime"
	"sort"
	"strings"
)

const (
	maxCLIRunbookStepArgs        = 6
	maxCLIRunbookStepTargets     = 4
	maxCLIRunbookStepDetailRunes = 720
)

type cliRunbookSide struct {
	RunbookRef       string `json:"runbook_ref"`
	DefinitionSHA256 string `json:"definition_sha256"`
}

type cliRunbookSummary struct {
	Slug              string          `json:"slug"`
	Title             string          `json:"title"`
	Summary           string          `json:"summary"`
	Available         bool            `json:"available"`
	UnavailableReason string          `json:"unavailable_reason"`
	Live              *cliRunbookSide `json:"live"`
	Draft             *cliRunbookSide `json:"draft"`
	InputCount        int             `json:"input_count"`
	StageCount        int             `json:"stage_count"`
	StepCount         int             `json:"step_count"`
}

type cliRunbookDetail struct {
	RunbookRef       string          `json:"runbook_ref"`
	Slug             string          `json:"slug"`
	DraftID          string          `json:"draft_id"`
	Status           string          `json:"status"`
	DefinitionSHA256 string          `json:"definition_sha256"`
	DraftSHA256      string          `json:"draft_definition_sha256"`
	LiveRef          string          `json:"live_ref"`
	Title            string          `json:"title"`
	Description      string          `json:"description"`
	Summary          cliRunbookCount `json:"summary"`
	Definition       json.RawMessage `json:"definition"`
}

type cliRunbookCount struct {
	InputCount int `json:"input_count"`
	StageCount int `json:"stage_count"`
	StepCount  int `json:"step_count"`
}

type cliRunbookDefinition struct {
	Inputs []struct {
		Name        string `json:"name"`
		ID          string `json:"id"`
		Type        string `json:"type"`
		Required    bool   `json:"required"`
		Description string `json:"description"`
	} `json:"inputs"`
	Stages []struct {
		ID    string           `json:"id"`
		Title string           `json:"title"`
		Mode  string           `json:"mode"`
		Steps []cliRunbookStep `json:"steps"`
	} `json:"stages"`
}

type cliRunbookStep struct {
	ID     string `json:"id"`
	Action string `json:"action"`
	Pack   struct {
		ID string `json:"id"`
	} `json:"pack"`
	Targets struct {
		Selection string   `json:"selection"`
		Refs      []string `json:"refs"`
	} `json:"targets"`
	Args map[string]cliRunbookBinding `json:"args"`
}

type cliRunbookBinding struct {
	Source string          `json:"source"`
	Value  json.RawMessage `json:"value"`
	Ref    string          `json:"ref"`
}

type cliRunbookExecution struct {
	RunbookExecutionID string                  `json:"runbook_execution_id"`
	RunbookRef         string                  `json:"runbook_ref"`
	Kind               string                  `json:"kind"`
	DefinitionSHA256   string                  `json:"definition_sha256"`
	Status             string                  `json:"status"`
	Blocking           *cliRunbookBlocking     `json:"blocking"`
	Stages             []cliRunbookStageResult `json:"stages"`
	Approval           *cliApprovalResult      `json:"approval"`
	WaitUntil          string                  `json:"wait_until"`
	Next               cliToolResultNext       `json:"next"`
	OutputsNext        cliToolResultNext       `json:"outputs_next"`
}

type cliRunbookBlocking struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	StageID   string `json:"stage_id"`
	StepID    string `json:"step_id"`
	RunnerRef string `json:"runner_ref"`
}

type cliRunbookStageResult struct {
	StageID     string                 `json:"stage_id"`
	Title       string                 `json:"title"`
	Mode        string                 `json:"mode"`
	Status      string                 `json:"status"`
	MaxParallel int                    `json:"max_parallel"`
	Items       []cliRunbookItemResult `json:"items"`
}

type cliRunbookItemResult struct {
	ItemID       string                   `json:"item_id"`
	StepID       string                   `json:"step_id"`
	RunnerRef    string                   `json:"runner_ref"`
	Status       string                   `json:"status"`
	ActionID     string                   `json:"action_id"`
	PackRef      string                   `json:"pack_ref"`
	Risk         string                   `json:"risk"`
	AttemptCount int                      `json:"attempt_count"`
	Outputs      []cliRunbookOutputResult `json:"outputs"`
	OutputCount  int                      `json:"output_count"`
	Error        *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
	LatestAttempt *struct {
		RunID         string `json:"run_id"`
		AttemptNumber int    `json:"attempt_number"`
		Status        string `json:"status"`
		DurationMS    *int64 `json:"duration_ms"`
	} `json:"latest_attempt"`
}

type cliRunbookOutputResult struct {
	OutputID  string          `json:"output_id"`
	ItemID    string          `json:"item_id"`
	StageID   string          `json:"stage_id"`
	StepID    string          `json:"step_id"`
	RunnerRef string          `json:"runner_ref"`
	Source    string          `json:"source"`
	Sensitive bool            `json:"sensitive"`
	Status    string          `json:"status"`
	Value     json.RawMessage `json:"value"`
}

type cliRunbookOutputPage struct {
	RunbookExecutionID string                   `json:"runbook_execution_id"`
	TotalCount         int                      `json:"total_count"`
	ReturnedCount      int                      `json:"returned_count"`
	RemainingCount     int                      `json:"remaining_count"`
	Outputs            []cliRunbookOutputResult `json:"outputs"`
	Next               cliToolResultNext        `json:"next"`
}

func renderCLIListRunbooks(w io.Writer, arguments, raw []byte, account string) (string, bool) {
	var result struct {
		OK         bool                `json:"ok"`
		Runbooks   []cliRunbookSummary `json:"runbooks"`
		NextCursor json.RawMessage     `json:"next_cursor"`
	}
	if json.Unmarshal(raw, &result) != nil || !result.OK {
		return "", false
	}
	for _, runbook := range result.Runbooks {
		if runbook.Slug == "" || runbook.Title == "" {
			return "", false
		}
	}
	if len(result.Runbooks) == 0 {
		var input struct {
			Query string `json:"query"`
		}
		_ = json.Unmarshal(arguments, &input)
		if input.Query != "" {
			return fmt.Sprintf("No runbooks found for %q.\n", cliResultText(input.Query, maxCLIHumanStringRunes)), true
		}
		return "No runbooks found.\n", true
	}

	var out strings.Builder
	fmt.Fprintf(&out, "%d %s\n", len(result.Runbooks), plural(len(result.Runbooks), "runbook", "runbooks"))
	for _, runbook := range result.Runbooks[:min(len(result.Runbooks), maxCLIResultItems)] {
		fmt.Fprintf(&out, "\n%s\n", cliStyledText(w, "1", cliResultText(runbook.Title, maxCLIHumanStringRunes)))
		fmt.Fprintf(&out, "  %s\n", cliResultText(runbook.Slug, 160))
		if summary := cliResultText(runbook.Summary, 720); summary != "" {
			fmt.Fprintf(&out, "  %s\n", summary)
		}
		fmt.Fprintf(&out, "  %s\n", cliRunbookCounts(runbook.InputCount, runbook.StageCount, runbook.StepCount))
		if runbook.Live != nil {
			fmt.Fprintf(&out, "  Live  %s\n", cliResultText(runbook.Live.RunbookRef, maxCLIFleetRefRunes))
			if command := cliRunbookInspectCommandForOS(runbook.Slug, "published", account, runtime.GOOS); command != "" {
				fmt.Fprintf(&out, "  Inspect live  %s\n", command)
			}
		}
		if runbook.Draft != nil {
			out.WriteString("  Draft  unpublished changes\n")
			if command := cliRunbookInspectCommandForOS(runbook.Slug, "draft", account, runtime.GOOS); command != "" {
				fmt.Fprintf(&out, "  Inspect draft  %s\n", command)
			}
		}
		if !runbook.Available && runbook.UnavailableReason != "" {
			fmt.Fprintf(&out, "  %s  %s\n", cliStyledText(w, "33", "Issue"), cliResultText(runbook.UnavailableReason, maxCLIHumanStringRunes))
		}
	}
	if hasJSONValue(result.NextCursor) || len(result.Runbooks) > maxCLIResultItems {
		out.WriteString("\nMore runbooks are available; use --json to continue with the returned cursor.\n")
	}
	return out.String(), true
}

func cliRunbookInspectCommandForOS(slug, status, account, goos string) string {
	if slug == "" || len(slug) > 160 || terminalSafeLine(slug) != slug ||
		(status != "published" && status != "draft") {
		return ""
	}
	arguments, err := json.Marshal(struct {
		Slug   string `json:"slug"`
		Status string `json:"status"`
	}{Slug: slug, Status: status})
	if err != nil {
		return ""
	}
	return cliFleetNextCommandForOS(cliFleetNext{
		Tool:      getRunbookToolName,
		Arguments: arguments,
	}, getRunbookToolName, account, goos)
}

func renderCLIGetRunbook(w io.Writer, raw []byte, account string) (string, bool) {
	var result struct {
		OK      bool             `json:"ok"`
		Runbook cliRunbookDetail `json:"runbook"`
	}
	if json.Unmarshal(raw, &result) != nil || !result.OK || result.Runbook.Status == "" ||
		result.Runbook.Title == "" || firstJSONByte(result.Runbook.Definition) != '{' {
		return "", false
	}
	runbook := result.Runbook
	identity := runbook.RunbookRef
	if identity == "" {
		identity = runbook.Slug
	}
	var out strings.Builder
	fmt.Fprintf(&out, "%s\n", cliStyledText(w, "1", cliResultText(runbook.Title, maxCLIHumanStringRunes)))
	fmt.Fprintf(&out, "%s · %s\n", cliResultText(identity, maxCLIFleetRefRunes), cliResultStatus(w, runbook.Status))
	if description := cliResultText(runbook.Description, 1_200); description != "" {
		fmt.Fprintf(&out, "\n%s\n", description)
	}
	fmt.Fprintf(&out, "\n%s\n", cliRunbookCounts(runbook.Summary.InputCount, runbook.Summary.StageCount, runbook.Summary.StepCount))
	writeCLIResultField(&out, "Definition", runbook.DefinitionSHA256, maxCLIFleetRefRunes)
	if runbook.DraftSHA256 != "" {
		out.WriteString("  Draft  unpublished changes exist\n")
	}
	writeCLIResultField(&out, "Live release", runbook.LiveRef, maxCLIFleetRefRunes)
	writeCLIRunbookDefinition(&out, w, runbook.Definition)
	if command := cliRunbookExecuteTemplateForOS(runbook, account, runtime.GOOS); command != "" {
		fmt.Fprintf(&out, "\n%s\n  %s\n", cliStyledText(w, "1", "Run"), command)
	}
	out.WriteString("\nUse --json for the complete definition and exact values.\n")
	return out.String(), true
}

func cliRunbookExecuteTemplateForOS(runbook cliRunbookDetail, account, goos string) string {
	var identity []byte
	var err error
	switch runbook.Status {
	case "published":
		if runbook.RunbookRef == "" || len(runbook.RunbookRef) > maxCLIFleetRefRunes ||
			terminalSafeLine(runbook.RunbookRef) != runbook.RunbookRef {
			return ""
		}
		identity, err = json.Marshal(struct {
			RunbookRef string `json:"runbook_ref"`
		}{RunbookRef: runbook.RunbookRef})
	case "draft":
		if runbook.Slug == "" || runbook.DefinitionSHA256 == "" || len(runbook.Slug) > 160 ||
			len(runbook.DefinitionSHA256) > maxCLIFleetRefRunes || terminalSafeLine(runbook.Slug) != runbook.Slug ||
			terminalSafeLine(runbook.DefinitionSHA256) != runbook.DefinitionSHA256 {
			return ""
		}
		identity, err = json.Marshal(struct {
			Slug             string `json:"slug"`
			AllowDraft       bool   `json:"allow_draft"`
			DefinitionSHA256 string `json:"definition_sha256"`
		}{Slug: runbook.Slug, AllowDraft: true, DefinitionSHA256: runbook.DefinitionSHA256})
	default:
		return ""
	}
	if err != nil {
		return ""
	}
	arguments := strings.TrimSuffix(string(identity), "}") + `,"reason":"<reason>","input_values":<input-values-json>}`
	if len(arguments) > maxCLIFleetCommand || terminalSafeText(arguments) != arguments {
		return ""
	}
	return cliToolInvocationForOS(executeRunbookToolName, account, goos) + " " + shellQuoteForOS(arguments, goos)
}

func writeCLIRunbookDefinition(out *strings.Builder, w io.Writer, raw json.RawMessage) {
	var definition cliRunbookDefinition
	if json.Unmarshal(raw, &definition) != nil {
		return
	}
	if len(definition.Inputs) > 0 {
		out.WriteString("\nInputs\n")
		for _, input := range definition.Inputs[:min(len(definition.Inputs), maxCLIResultItems)] {
			name := input.Name
			if name == "" {
				name = input.ID
			}
			status := "optional"
			if input.Required {
				status = "required"
			}
			fmt.Fprintf(out, "  %s — %s, %s\n", cliResultText(name, 160), cliResultText(input.Type, 80), status)
			if input.Description != "" {
				fmt.Fprintf(out, "    %s\n", cliResultText(input.Description, maxCLIHumanStringRunes))
			}
		}
		if len(definition.Inputs) > maxCLIResultItems {
			fmt.Fprintf(out, "  %d more inputs; use --json for the complete definition.\n", len(definition.Inputs)-maxCLIResultItems)
		}
	}
	if len(definition.Stages) == 0 {
		return
	}
	out.WriteString("\nWorkflow\n")
	for index, stage := range definition.Stages[:min(len(definition.Stages), maxCLIResultItems)] {
		title := stage.Title
		if title == "" {
			title = stage.ID
		}
		fmt.Fprintf(out, "  %d. %s — %s, %d %s\n", index+1, cliStyledText(w, "1", cliResultText(title, 160)), cliResultText(stage.Mode, 80), len(stage.Steps), plural(len(stage.Steps), "step", "steps"))
		for _, step := range stage.Steps[:min(len(stage.Steps), maxCLIResultItems)] {
			fmt.Fprintf(out, "     %s — %s\n", cliResultText(step.ID, 160), cliResultText(step.Action, 160))
			if context := cliRunbookStepContext(step); context != "" {
				fmt.Fprintf(out, "       %s\n", context)
			}
			if arguments := cliRunbookStepArguments(step.Args); arguments != "" {
				fmt.Fprintf(out, "       Args %s\n", arguments)
			}
		}
		if len(stage.Steps) > maxCLIResultItems {
			fmt.Fprintf(out, "     %d more steps; use --json for the complete definition.\n", len(stage.Steps)-maxCLIResultItems)
		}
	}
	if len(definition.Stages) > maxCLIResultItems {
		fmt.Fprintf(out, "  %d more stages; use --json for the complete definition.\n", len(definition.Stages)-maxCLIResultItems)
	}
}

func cliRunbookStepContext(step cliRunbookStep) string {
	parts := make([]string, 0, 2)
	if pack := cliRunbookInlineText(step.Pack.ID, 160); pack != "" {
		parts = append(parts, "Pack "+pack)
	}

	selection := ""
	switch step.Targets.Selection {
	case "all":
		selection = "all of "
	case "random_one":
		selection = "one of "
	}
	refs := make([]string, 0, min(len(step.Targets.Refs), maxCLIRunbookStepTargets))
	for _, ref := range step.Targets.Refs {
		if safe := cliRunbookInlineText(ref, 160); safe != "" {
			refs = append(refs, safe)
		}
	}
	if selection != "" && len(refs) > 0 {
		visible := refs[:min(len(refs), maxCLIRunbookStepTargets)]
		target := selection + strings.Join(visible, ", ")
		if len(refs) > len(visible) {
			target += fmt.Sprintf(" +%d more", len(refs)-len(visible))
		}
		parts = append(parts, "Target "+target)
	}
	return cliResultText(strings.Join(parts, " · "), maxCLIRunbookStepDetailRunes)
}

func cliRunbookStepArguments(arguments map[string]cliRunbookBinding) string {
	if len(arguments) == 0 {
		return ""
	}
	keys := make([]string, 0, len(arguments))
	for key := range arguments {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	parts := make([]string, 0, min(len(keys), maxCLIRunbookStepArgs))
	for _, key := range keys[:min(len(keys), maxCLIRunbookStepArgs)] {
		name := cliRunbookInlineText(key, 80)
		value := cliRunbookBindingValue(arguments[key])
		if name != "" && value != "" {
			parts = append(parts, name+"="+value)
		}
	}
	if len(keys) > maxCLIRunbookStepArgs {
		parts = append(parts, fmt.Sprintf("+%d more", len(keys)-maxCLIRunbookStepArgs))
	}
	return cliResultText(strings.Join(parts, " · "), maxCLIRunbookStepDetailRunes)
}

func cliRunbookBindingValue(binding cliRunbookBinding) string {
	switch binding.Source {
	case "input", "output":
		if ref := cliRunbookInlineText(binding.Ref, 160); ref != "" {
			return binding.Source + ":" + ref
		}
	case "literal":
		raw := bytes.TrimSpace(binding.Value)
		if len(raw) == 0 {
			return ""
		}
		if firstJSONByte(raw) == '"' {
			var value string
			if json.Unmarshal(raw, &value) != nil {
				return ""
			}
			if value == "" {
				return `""`
			}
			return cliRunbookInlineText(value, 160)
		}
		var compact bytes.Buffer
		if json.Compact(&compact, raw) == nil {
			return cliRunbookInlineText(compact.String(), 160)
		}
	}
	return ""
}

func cliRunbookInlineText(value string, limit int) string {
	return cliResultText(terminalSafeLine(value), limit)
}

func renderCLIRunbookDraft(w io.Writer, raw []byte, account string) (string, bool) {
	var result struct {
		OK               bool   `json:"ok"`
		OperationID      string `json:"operation_id"`
		DraftID          string `json:"draft_id"`
		Slug             string `json:"slug"`
		Status           string `json:"status"`
		DefinitionSHA256 string `json:"definition_sha256"`
		LiveRef          string `json:"live_ref"`
		ReviewURL        string `json:"review_url"`
	}
	if json.Unmarshal(raw, &result) != nil || !result.OK || result.OperationID == "" ||
		result.DraftID == "" || result.Slug == "" || result.Status != "draft" {
		return "", false
	}
	var out strings.Builder
	fmt.Fprintf(&out, "%s\n", cliStyledText(w, "1", "Draft saved"))
	fmt.Fprintf(&out, "\nRunbook      %s\n", cliResultText(result.Slug, 160))
	fmt.Fprintf(&out, "Draft ID     %s\n", cliResultText(result.DraftID, maxCLIFleetRefRunes))
	fmt.Fprintf(&out, "Definition   %s\n", cliResultText(result.DefinitionSHA256, maxCLIFleetRefRunes))
	fmt.Fprintf(&out, "Operation ID  %s\n", cliResultText(result.OperationID, maxCLIFleetRefRunes))
	if command := cliOperationInspectCommandForOS(result.OperationID, account, runtime.GOOS); command != "" {
		fmt.Fprintf(&out, "Inspect       %s\n", command)
	}
	writeCLIResultField(&out, "Live release", result.LiveRef, maxCLIFleetRefRunes)
	writeCLIResultField(&out, "Review", result.ReviewURL, maxCLIFleetCommand)
	out.WriteString("\nThe draft is not live until an operator reviews and publishes it.\n")
	return out.String(), true
}

func renderCLIExecuteRunbook(w io.Writer, raw []byte, account string) (string, bool) {
	var result struct {
		OK          bool            `json:"ok"`
		OperationID string          `json:"operation_id"`
		Execution   json.RawMessage `json:"execution"`
	}
	if json.Unmarshal(raw, &result) != nil || !result.OK || result.OperationID == "" ||
		firstJSONByte(result.Execution) != '{' {
		return "", false
	}
	rendered, ok := renderCLIRunbookExecution(w, result.Execution)
	if !ok {
		return "", false
	}
	var out strings.Builder
	fmt.Fprintf(&out, "%s\n\nOperation ID  %s\n", cliStyledText(w, "1", "Runbook execution started"), cliResultText(result.OperationID, maxCLIFleetRefRunes))
	if command := cliOperationInspectCommandForOS(result.OperationID, account, runtime.GOOS); command != "" {
		fmt.Fprintf(&out, "Inspect       %s\n", command)
	}
	out.WriteByte('\n')
	out.WriteString(rendered)
	return out.String(), true
}

func renderCLIRunbookExecution(w io.Writer, raw []byte) (string, bool) {
	var execution cliRunbookExecution
	if json.Unmarshal(raw, &execution) != nil || execution.RunbookExecutionID == "" ||
		execution.RunbookRef == "" || execution.Status == "" {
		return "", false
	}
	var out strings.Builder
	fmt.Fprintf(&out, "%s — %s\n", cliStyledText(w, "1", cliResultText(execution.RunbookRef, maxCLIFleetRefRunes)), cliResultStatus(w, execution.Status))
	fmt.Fprintf(&out, "  Execution ID  %s\n", cliResultText(execution.RunbookExecutionID, maxCLIFleetRefRunes))
	writeCLIResultField(&out, "Definition", execution.DefinitionSHA256, maxCLIFleetRefRunes)
	if execution.Approval != nil {
		writeCLIResultField(&out, "Approval", execution.Approval.URL, maxCLIFleetCommand)
		writeCLIResultField(&out, "Expires", cliFleetTime(execution.Approval.ExpiresAt), 80)
	}
	if execution.Blocking != nil {
		fmt.Fprintf(&out, "  %s  %s\n", cliStyledText(w, "31", "Blocked"), cliResultText(execution.Blocking.Message, maxCLIHumanStringRunes))
	}
	for _, stage := range execution.Stages[:min(len(execution.Stages), maxCLIResultItems)] {
		title := stage.Title
		if title == "" {
			title = stage.StageID
		}
		fmt.Fprintf(&out, "\n  %s — %s\n", cliStyledText(w, "1", cliResultText(title, 160)), cliResultStatus(w, stage.Status))
		fmt.Fprintf(&out, "    %s · %d %s\n", cliResultText(stage.Mode, 80), len(stage.Items), plural(len(stage.Items), "item", "items"))
		for _, item := range stage.Items[:min(len(stage.Items), maxCLIResultItems)] {
			fmt.Fprintf(&out, "\n    %s on %s — %s\n", cliResultText(item.StepID, 160), cliResultText(item.RunnerRef, maxCLIFleetRefRunes), cliResultStatus(w, item.Status))
			fmt.Fprintf(&out, "      %s · %s\n", cliResultText(item.ActionID, 160), cliFleetRisk(w, item.Risk))
			if item.AttemptCount > 0 {
				fmt.Fprintf(&out, "      %d %s\n", item.AttemptCount, plural(item.AttemptCount, "attempt", "attempts"))
			}
			if item.Error != nil {
				fmt.Fprintf(&out, "      %s  %s\n", cliStyledText(w, "31", "Error"), cliResultText(item.Error.Message, maxCLIHumanStringRunes))
			}
			writeCLIRunbookItemOutputs(&out, item.Outputs)
			totalOutputs := max(item.OutputCount, len(item.Outputs))
			if totalOutputs > len(item.Outputs) {
				fmt.Fprintf(&out, "      %d more outputs; follow outputs_next.\n", totalOutputs-len(item.Outputs))
			}
		}
		if len(stage.Items) > maxCLIResultItems {
			fmt.Fprintf(&out, "\n    %d more items; use --json for the complete stage.\n", len(stage.Items)-maxCLIResultItems)
		}
	}
	if len(execution.Stages) > maxCLIResultItems {
		fmt.Fprintf(&out, "\n  %d more stages; use --json for the complete execution.\n", len(execution.Stages)-maxCLIResultItems)
	}
	if execution.Next.Tool != "" {
		out.WriteString("\nStill running. The returned continuation can be followed with wait_for_run.\n")
	}
	if execution.OutputsNext.Tool != "" {
		out.WriteString("\nMore outputs are available through the returned outputs_next continuation.\n")
	}
	return out.String(), true
}

func writeCLIRunbookItemOutputs(out *strings.Builder, outputs []cliRunbookOutputResult) {
	for _, output := range outputs {
		label := output.OutputID
		if label == "" {
			label = output.Source
		}
		fmt.Fprintf(out, "      Output %s — %s\n", cliResultText(label, 160), cliResultText(output.Status, 80))
		writeCLIJSONBlock(out, "        ", output.Value)
	}
}

func renderCLIRunbookOutputs(_ io.Writer, raw []byte) (string, bool) {
	result, ok := parseCLIRunbookOutputs(raw)
	if !ok {
		return "", false
	}
	var out strings.Builder
	fmt.Fprintf(&out, "%d of %d runbook outputs\n", result.ReturnedCount, result.TotalCount)
	for _, output := range result.Outputs {
		fmt.Fprintf(&out, "\n%s · %s\n", cliResultText(output.StepID, 160), cliResultText(output.RunnerRef, maxCLIFleetRefRunes))
		fmt.Fprintf(&out, "  %s — %s\n", cliResultText(output.OutputID, 160), cliResultText(output.Status, 80))
		writeCLIJSONBlock(&out, "  ", output.Value)
	}
	if result.RemainingCount > 0 {
		fmt.Fprintf(&out, "\n%d outputs remain; follow the returned continuation with --json.\n", result.RemainingCount)
	}
	return out.String(), true
}

func parseCLIRunbookOutputs(raw []byte) (cliRunbookOutputPage, bool) {
	var result cliRunbookOutputPage
	if json.Unmarshal(raw, &result) != nil || result.RunbookExecutionID == "" ||
		result.TotalCount <= 0 || result.ReturnedCount <= 0 ||
		result.ReturnedCount != len(result.Outputs) || result.RemainingCount < 0 ||
		result.ReturnedCount+result.RemainingCount > result.TotalCount {
		return cliRunbookOutputPage{}, false
	}
	hasNext := cliToolContinuationPresent(result.Next)
	if hasNext != (result.RemainingCount > 0) {
		return cliRunbookOutputPage{}, false
	}
	return result, true
}

func cliRunbookCounts(inputs, stages, steps int) string {
	return fmt.Sprintf("%d %s · %d %s · %d %s", inputs, plural(inputs, "input", "inputs"), stages, plural(stages, "stage", "stages"), steps, plural(steps, "step", "steps"))
}

func writeCLIJSONBlock(out *strings.Builder, indent string, raw json.RawMessage) {
	if len(raw) == 0 || firstJSONByte(raw) == 'n' {
		return
	}
	var pretty bytes.Buffer
	if json.Indent(&pretty, bytes.TrimSpace(raw), "", "  ") != nil {
		return
	}
	value := cliResultMultiline(pretty.String(), maxCLIResultOutputRunes)
	for _, line := range strings.Split(value, "\n") {
		fmt.Fprintf(out, "%s%s\n", indent, terminalSafeText(line))
	}
}
