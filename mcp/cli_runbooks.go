package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"runtime"
	"sort"
	"strings"
	"unicode"
)

const (
	maxCLIRunbookStepArgs        = 6
	maxCLIRunbookStepTargets     = 4
	maxCLIRunbookStepDetailRunes = 720
	maxCLIRunbookPreviewLines    = 8
	maxCLIRunbookPreviewRunes    = 720
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
	RunsNext           cliToolResultNext       `json:"runs_next"`
	Next               cliToolResultNext       `json:"next"`
	OutputsNext        cliToolResultNext       `json:"outputs_next"`
}

type cliRunbookBlocking struct {
	Message string `json:"message"`
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
		RunID  string `json:"run_id"`
		Status string `json:"status"`
	} `json:"latest_attempt"`
}

type cliRunbookOutputResult struct {
	OutputID  string          `json:"output_id"`
	StepID    string          `json:"step_id"`
	RunnerRef string          `json:"runner_ref"`
	Source    string          `json:"source"`
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
	return cliFleetNextCommandForOS(cliToolResultNext{
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
	if pack := cliInlineText(step.Pack.ID, 160); pack != "" {
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
		if safe := cliInlineText(ref, 160); safe != "" {
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
		name := cliInlineText(key, 80)
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
		if ref := cliInlineText(binding.Ref, 160); ref != "" {
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
			return cliInlineText(value, 160)
		}
		var compact bytes.Buffer
		if json.Compact(&compact, raw) == nil {
			return cliInlineText(compact.String(), 160)
		}
	}
	return ""
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
		OK          bool                `json:"ok"`
		OperationID string              `json:"operation_id"`
		Execution   cliRunbookExecution `json:"execution"`
	}
	if json.Unmarshal(raw, &result) != nil || !result.OK || result.OperationID == "" ||
		result.Execution.RunbookExecutionID == "" || result.Execution.RunbookRef == "" ||
		result.Execution.Status == "" {
		return "", false
	}
	var out strings.Builder
	fmt.Fprintf(&out, "%s\n\nOperation ID  %s\n", cliStyledText(w, "1", "Runbook execution started"), cliResultText(result.OperationID, maxCLIFleetRefRunes))
	if command := cliOperationInspectCommandForOS(result.OperationID, account, runtime.GOOS); command != "" {
		fmt.Fprintf(&out, "Inspect       %s\n", command)
	}
	fmt.Fprintf(&out, "\n%s\n", cliStyledText(w, "1", cliResultText(result.Execution.RunbookRef, maxCLIFleetRefRunes)))
	fmt.Fprintf(&out, "Execution ID  %s\n", cliResultText(result.Execution.RunbookExecutionID, maxCLIFleetRefRunes))
	writeCLIResultField(&out, "Definition", result.Execution.DefinitionSHA256, maxCLIFleetRefRunes)
	if result.Execution.Approval != nil {
		writeCLIResultField(&out, "Approval", result.Execution.Approval.URL, maxCLIFleetCommand)
		writeCLIResultField(&out, "Expires", cliFleetTime(result.Execution.Approval.ExpiresAt), 80)
	}
	if result.Execution.Blocking != nil {
		fmt.Fprintf(&out, "%s  %s\n", cliStyledText(w, "31", "Blocked"), cliResultText(result.Execution.Blocking.Message, maxCLIHumanStringRunes))
	}
	stages, items := cliRunbookExecutionSize(result.Execution)
	fmt.Fprintf(&out, "%d %s across %d %s\n", items, plural(items, "action", "actions"), stages, plural(stages, "stage", "stages"))
	if len(result.Execution.Stages) > 0 && !cliToolContinuationPresent(result.Execution.Next) {
		out.WriteString("\nProgress\n")
		writeCLIRunbookProgress(&out, w, nil, result.Execution.Stages)
	}
	return out.String(), true
}

func cliRunbookExecutionSize(execution cliRunbookExecution) (int, int) {
	items := 0
	for _, stage := range execution.Stages {
		items += len(stage.Items)
	}
	return len(execution.Stages), items
}

func writeCLIRunbookProgress(out *strings.Builder, w io.Writer, previous, current []cliRunbookStageResult) {
	previousByID := make(map[string]string, len(previous))
	for _, stage := range previous {
		previousByID[stage.StageID] = cliRunbookStageProgressKey(stage)
	}
	for _, stage := range current {
		if previousByID[stage.StageID] == cliRunbookStageProgressKey(stage) {
			continue
		}
		out.WriteString(cliRunbookProgressLine(w, stage))
		out.WriteByte('\n')
	}
}

type cliRunbookProgressDisplay struct {
	writer       io.Writer
	terminalSize func() (int, int, bool)
	previous     []cliRunbookStageResult
	redraw       bool
	lineCount    int
}

func newCLIRunbookProgressDisplay(writer io.Writer, stages []cliRunbookStageResult) cliRunbookProgressDisplay {
	width, height, terminal := cliRunbookProgressTerminalSize(writer)
	return cliRunbookProgressDisplay{
		writer: writer,
		terminalSize: func() (int, int, bool) {
			return cliRunbookProgressTerminalSize(writer)
		},
		redraw: terminal && cliRunbookProgressFitsTerminal(stages, width, height),
	}
}

func (display *cliRunbookProgressDisplay) writeInitial(stages []cliRunbookStageResult) {
	display.writeAll(stages, false)
	display.previous = stages
	display.lineCount = len(stages)
}

func (display *cliRunbookProgressDisplay) writeUpdate(stages []cliRunbookStageResult) {
	var changed strings.Builder
	writeCLIRunbookProgress(&changed, display.writer, display.previous, stages)
	if changed.Len() == 0 {
		display.previous = stages
		return
	}
	if display.redraw {
		width, height, terminal := display.terminalSize()
		if !terminal || display.lineCount != len(stages) ||
			!cliRunbookProgressFitsTerminal(stages, width, height) {
			display.redraw = false
		}
	}
	if display.redraw {
		fmt.Fprintf(display.writer, "\x1b[%dA", display.lineCount)
		display.writeAll(stages, true)
	} else {
		_, _ = io.WriteString(display.writer, changed.String())
	}
	display.previous = stages
}

func (display *cliRunbookProgressDisplay) writeAll(stages []cliRunbookStageResult, clear bool) {
	for _, stage := range stages {
		if clear {
			_, _ = io.WriteString(display.writer, "\r\x1b[2K")
		}
		_, _ = io.WriteString(display.writer, cliRunbookProgressLine(display.writer, stage)+"\n")
	}
}

func cliRunbookProgressLine(w io.Writer, stage cliRunbookStageResult) string {
	return fmt.Sprintf("  %s %s — %s", cliRunbookStageGlyph(w, stage.Status), cliRunbookStageTitle(stage), cliRunbookStageProgress(stage))
}

func cliRunbookProgressTerminalSize(writer io.Writer) (int, int, bool) {
	if runtime.GOOS == "windows" || os.Getenv("TERM") == "dumb" {
		return 0, 0, false
	}
	file, ok := writer.(*os.File)
	if !ok {
		return 0, 0, false
	}
	return fileTerminalSize(file)
}

func cliRunbookProgressFitsWidth(stages []cliRunbookStageResult, width int) bool {
	if len(stages) == 0 || width < 1 {
		return false
	}
	for _, stage := range stages {
		title := cliRunbookStageTitle(stage)
		if strings.IndexFunc(title, func(r rune) bool { return r > unicode.MaxASCII }) >= 0 {
			return false
		}
		line := "  ● " + title + " — " + cliRunbookStageProgress(stage)
		if len([]rune(line)) >= width {
			return false
		}
	}
	return true
}

func cliRunbookProgressFitsTerminal(stages []cliRunbookStageResult, width, height int) bool {
	return len(stages) < height && cliRunbookProgressFitsWidth(stages, width)
}

func cliRunbookStageProgressKey(stage cliRunbookStageResult) string {
	counts := cliRunbookItemStatusCounts(stage.Items)
	return fmt.Sprintf("%s:%d:%d:%d:%d:%d", stage.Status, counts.succeeded, counts.failed, counts.running, counts.waiting, counts.pending)
}

type cliRunbookItemCounts struct {
	succeeded int
	failed    int
	running   int
	waiting   int
	pending   int
}

func cliRunbookItemStatusCounts(items []cliRunbookItemResult) cliRunbookItemCounts {
	var counts cliRunbookItemCounts
	for _, item := range items {
		switch item.Status {
		case "succeeded":
			counts.succeeded++
		case "failed", "cancelled":
			counts.failed++
		case "running":
			counts.running++
		case "waiting":
			counts.waiting++
		case "pending":
			counts.pending++
		}
	}
	return counts
}

func cliRunbookStageTitle(stage cliRunbookStageResult) string {
	title := stage.Title
	if title == "" {
		title = stage.StageID
	}
	return cliResultText(title, 160)
}

func cliRunbookStageGlyph(w io.Writer, status string) string {
	switch status {
	case "succeeded":
		return cliStyledText(w, "32", "✓")
	case "halted", "cancelled":
		return cliStyledText(w, "31", "✗")
	case "active":
		return cliStyledText(w, "33", "●")
	default:
		return "○"
	}
}

func cliRunbookStageProgress(stage cliRunbookStageResult) string {
	total := len(stage.Items)
	counts := cliRunbookItemStatusCounts(stage.Items)
	complete := counts.succeeded + counts.failed
	switch stage.Status {
	case "succeeded":
		return fmt.Sprintf("%d/%d succeeded", counts.succeeded, total)
	case "halted", "cancelled":
		return fmt.Sprintf("%d/%d complete · %s", complete, total, stage.Status)
	case "pending":
		return fmt.Sprintf("waiting · %d %s", total, plural(total, "action", "actions"))
	default:
		parts := []string{fmt.Sprintf("%d/%d complete", complete, total)}
		if counts.running > 0 {
			parts = append(parts, fmt.Sprintf("%d running", counts.running))
		}
		if counts.waiting > 0 {
			parts = append(parts, fmt.Sprintf("%d retrying", counts.waiting))
		}
		return strings.Join(parts, " · ")
	}
}

func renderCLIRunbookCompletion(w io.Writer, execution cliRunbookExecution) string {
	_, total := cliRunbookExecutionSize(execution)
	var counts cliRunbookItemCounts
	for _, stage := range execution.Stages {
		stageCounts := cliRunbookItemStatusCounts(stage.Items)
		counts.succeeded += stageCounts.succeeded
		counts.failed += stageCounts.failed
	}
	status := cliResultStatus(w, execution.Status)
	if execution.Status == "succeeded" {
		return fmt.Sprintf("%s Runbook %s — %d/%d actions succeeded\n", cliStyledText(w, "32", "✓"), status, counts.succeeded, total)
	}
	return fmt.Sprintf("%s Runbook %s — %d succeeded · %d failed · %d total\n", cliStyledText(w, "31", "✗"), status, counts.succeeded, counts.failed, total)
}

func renderCLIRunbookResults(
	w io.Writer,
	execution cliRunbookExecution,
	runs map[string]cliRunResult,
	account string,
) string {
	if len(execution.Stages) == 0 {
		return ""
	}
	var out strings.Builder
	out.WriteString("Results\n")
	for _, stage := range execution.Stages {
		fmt.Fprintf(&out, "\n%s\n", cliStyledText(w, "1", cliRunbookStageTitle(stage)))
		for _, item := range stage.Items {
			var run cliRunResult
			hasRun := item.LatestAttempt != nil
			if hasRun {
				run, hasRun = runs[item.LatestAttempt.RunID]
			}
			writeCLIRunbookResult(&out, w, item, run, hasRun, account)
		}
	}
	return out.String()
}

func writeCLIRunbookResult(
	out *strings.Builder,
	w io.Writer,
	item cliRunbookItemResult,
	run cliRunResult,
	hasRun bool,
	account string,
) {
	status := item.Status
	if hasRun {
		status = run.Status
	}
	step := cliResultText(item.StepID, 160)
	runner := cliRunbookRunnerName(item.RunnerRef)
	fmt.Fprintf(out, "\n  %s %s · %s", cliRunbookResultGlyph(w, status), step, runner)
	if hasRun && run.DurationMS != nil {
		fmt.Fprintf(out, " · %s", cliResultDuration(*run.DurationMS))
	}
	if status != "success" && status != "succeeded" {
		fmt.Fprintf(out, " · %s", cliResultStatus(w, status))
	}
	out.WriteByte('\n')
	fmt.Fprintf(out, "    %s", cliResultText(item.ActionID, 160))
	if item.AttemptCount > 1 {
		fmt.Fprintf(out, " · %d attempts", item.AttemptCount)
	}
	out.WriteByte('\n')
	if item.Error != nil && item.Error.Message != "" {
		fmt.Fprintf(out, "    %s  %s\n", cliStyledText(w, "31", "Error"), cliResultText(item.Error.Message, maxCLIHumanStringRunes))
	} else if hasRun && run.ErrorMessage != "" {
		fmt.Fprintf(out, "    %s  %s\n", cliStyledText(w, "31", "Error"), cliResultText(run.ErrorMessage, maxCLIHumanStringRunes))
	}
	if !hasRun {
		out.WriteString("    Output\n      No action attempt was recorded.\n")
		return
	}

	detailsNeeded := writeCLIRunbookRunOutput(out, run)
	if cliRunFailed(run.Status) {
		detailsNeeded = true
	}
	if detailsNeeded {
		runURL := safeCLIRunURL(run.RunURL)
		command := cliRunbookRunDetailsCommand(run, account)
		if run.localOutputClipped {
			if runURL != "" {
				fmt.Fprintf(out, "    Details  %s\n", cliStyledText(w, "4", runURL))
			}
		} else if command != "" {
			fmt.Fprintf(out, "    More  %s\n", command)
		} else if runURL != "" {
			fmt.Fprintf(out, "    Details  %s\n", cliStyledText(w, "4", runURL))
		}
	}
}

func cliRunbookResultGlyph(w io.Writer, status string) string {
	if status == "success" || status == "succeeded" {
		return cliStyledText(w, "32", "✓")
	}
	if cliRunFailed(status) {
		return cliStyledText(w, "31", "✗")
	}
	return "–"
}

func cliRunbookRunnerName(runnerRef string) string {
	name, _, _ := strings.Cut(runnerRef, "~")
	if name == "" {
		name = runnerRef
	}
	return cliResultText(name, 160)
}

func writeCLIRunbookRunOutput(out *strings.Builder, run cliRunResult) bool {
	wrote := false
	detailsNeeded := run.StructuredOmitted || (run.OutputComplete != nil && !*run.OutputComplete)
	if len(run.Output) > 0 {
		remaining := maxCLIResultOutputRunes
		outputClipped := run.localOutputClipped
		for _, segment := range run.Output {
			if segment.Text == "" {
				continue
			}
			wrote = true
			label := "Output"
			if segment.Stream == "stderr" {
				label = "Error output"
			}
			var clipped bool
			remaining, clipped = writeCLIRunbookOutput(out, label, segment.Text, remaining)
			outputClipped = outputClipped || clipped
		}
		if outputClipped {
			out.WriteString("    … output exceeds the 16,384-character terminal display limit\n")
			detailsNeeded = true
		}
	} else {
		if run.Stdout != "" || run.EmittedStdoutBytes > 0 {
			wrote = true
			clipped := writeCLIRunbookPreview(out, "Output", run.Stdout)
			if clipped || run.TruncatedStdout {
				writeCLIRunbookPreviewNotice(out, run.EmittedStdoutBytes)
				detailsNeeded = true
			}
		}
		if run.Stderr != "" || run.EmittedStderrBytes > 0 {
			wrote = true
			clipped := writeCLIRunbookPreview(out, "Error output", run.Stderr)
			if clipped || run.TruncatedStderr {
				writeCLIRunbookPreviewNotice(out, run.EmittedStderrBytes)
				detailsNeeded = true
			}
		}
	}
	if firstJSONByte(run.StructuredOutput) != 0 && firstJSONByte(run.StructuredOutput) != 'n' {
		var pretty bytes.Buffer
		if json.Indent(&pretty, bytes.TrimSpace(run.StructuredOutput), "", "  ") == nil {
			wrote = true
			if writeCLIRunbookPreview(out, "Result", pretty.String()) {
				detailsNeeded = true
			}
		}
	}
	if !wrote {
		out.WriteString("    Output\n      No output.\n")
	}
	if run.StructuredOmitted {
		out.WriteString("    … structured result omitted from this preview\n")
	}
	if run.OutputComplete != nil && !*run.OutputComplete {
		out.WriteString("    … output may have gaps\n")
	}
	return detailsNeeded
}

func writeCLIRunbookOutput(out *strings.Builder, label, value string, remaining int) (int, bool) {
	runes := []rune(value)
	clipped := len(runes) > remaining
	if clipped {
		runes = runes[:remaining]
	}
	if len(runes) == 0 {
		return remaining, clipped
	}
	fmt.Fprintf(out, "    %s\n", label)
	for _, line := range strings.Split(string(runes), "\n") {
		fmt.Fprintf(out, "      %s\n", terminalSafeText(line))
	}
	return remaining - len(runes), clipped
}

func writeCLIRunbookPreview(out *strings.Builder, label, value string) bool {
	fmt.Fprintf(out, "    %s\n", label)
	if value == "" {
		out.WriteString("      Preview unavailable.\n")
		return false
	}
	lines := strings.Split(value, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	clipped := len(lines) > maxCLIRunbookPreviewLines
	if clipped {
		lines = lines[:maxCLIRunbookPreviewLines]
	}
	remaining := maxCLIRunbookPreviewRunes
	for index, line := range lines {
		safe := []rune(terminalSafeText(line))
		if len(safe) > remaining {
			safe = safe[:remaining]
			clipped = true
		}
		fmt.Fprintf(out, "      %s\n", string(safe))
		remaining -= len(safe)
		if remaining == 0 {
			clipped = clipped || index < len(lines)-1
			break
		}
	}
	return clipped
}

func writeCLIRunbookPreviewNotice(out *strings.Builder, emittedBytes int64) {
	if emittedBytes > 0 {
		fmt.Fprintf(out, "    … preview truncated · %s total\n", cliHumanBytes(emittedBytes))
		return
	}
	out.WriteString("    … preview truncated\n")
}

func cliHumanBytes(size int64) string {
	const (
		kilobyte = int64(1_000)
		megabyte = int64(1_000_000)
	)
	switch {
	case size < kilobyte:
		return fmt.Sprintf("%d B", size)
	case size < megabyte:
		return cliHumanUnit(size, kilobyte, "kB")
	default:
		return cliHumanUnit(size, megabyte, "MB")
	}
}

func cliHumanUnit(size, unit int64, label string) string {
	if size%unit == 0 {
		return fmt.Sprintf("%d %s", size/unit, label)
	}
	return fmt.Sprintf("%.1f %s", float64(size)/float64(unit), label)
}

func cliRunbookRunDetailsCommand(run cliRunResult, account string) string {
	if !validCLIRunContinuation(run.Next, run.RunID) {
		return ""
	}
	return cliSafeReadContinuation(run.Next, account)
}

func safeCLIRunURL(raw string) string {
	if raw == "" || len(raw) > 2048 || terminalSafeText(raw) != raw {
		return ""
	}
	parsed, err := url.ParseRequestURI(raw)
	if err != nil || parsed.Host == "" || parsed.User != nil ||
		(parsed.Scheme != "https" && parsed.Scheme != "http") {
		return ""
	}
	return raw
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
