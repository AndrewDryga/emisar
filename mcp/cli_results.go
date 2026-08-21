package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"runtime"
	"strings"
)

const (
	getActionToolName          = "get_action"
	runActionToolName          = "run_action"
	getOperationToolName       = "get_operation"
	waitForRunToolName         = "wait_for_run"
	recentRunsToolName         = "recent_runs"
	listRunbooksToolName       = "list_runbooks"
	getRunbookToolName         = "get_runbook"
	executeRunbookToolName     = "execute_runbook"
	createRunbookDraftToolName = "create_runbook_draft"
	updateRunbookDraftToolName = "update_runbook_draft"
	maxCLIResultItems          = 50
	maxCLIResultOutputRunes    = 16_384
	maxCLIErrorIssues          = 8
)

type cliToolResultNext struct {
	Tool      string          `json:"tool"`
	Arguments json.RawMessage `json:"arguments"`
}

type cliApprovalResult struct {
	RequestID string `json:"request_id"`
	URL       string `json:"url"`
	ExpiresAt string `json:"expires_at"`
}

type cliRunResult struct {
	RunID              string             `json:"run_id"`
	OperationID        string             `json:"operation_id"`
	ActionID           string             `json:"action_id"`
	PackRef            string             `json:"pack_ref"`
	RunnerRef          string             `json:"runner_ref"`
	RunbookExecutionID string             `json:"runbook_execution_id"`
	StepID             string             `json:"step_id"`
	Status             string             `json:"status"`
	CreatedAt          string             `json:"created_at"`
	FinishedAt         string             `json:"finished_at"`
	ExitCode           *int               `json:"exit_code"`
	DurationMS         *int64             `json:"duration_ms"`
	ErrorMessage       string             `json:"error_message"`
	Stdout             string             `json:"stdout"`
	Stderr             string             `json:"stderr"`
	EmittedStdoutBytes int64              `json:"emitted_stdout_bytes"`
	EmittedStderrBytes int64              `json:"emitted_stderr_bytes"`
	TruncatedStdout    bool               `json:"truncated_stdout"`
	TruncatedStderr    bool               `json:"truncated_stderr"`
	Output             []cliRunOutput     `json:"output"`
	OutputComplete     *bool              `json:"output_complete"`
	StructuredOutput   json.RawMessage    `json:"structured_output"`
	StructuredOmitted  bool               `json:"structured_output_omitted"`
	LocalAuditFailed   bool               `json:"local_audit_failed"`
	Approval           *cliApprovalResult `json:"approval"`
	WaitUntil          string             `json:"wait_until"`
	RunURL             string             `json:"run_url"`
	Next               cliToolResultNext  `json:"next"`
}

type cliRunOutput struct {
	Stream string `json:"stream"`
	Text   string `json:"text"`
}

func writeCLIOperatorOutput(
	w io.Writer,
	toolName string,
	arguments, raw []byte,
	account string,
	successful bool,
) (bool, error) {
	if err := validateStrictJSON(raw); err != nil {
		return false, nil
	}
	if !successful {
		return writeCLIToolError(w, toolName, arguments, raw, account)
	}

	var rendered string
	var ok bool
	switch toolName {
	case getActionToolName:
		rendered, ok = renderCLIGetAction(w, raw, account)
	case runActionToolName:
		rendered, ok = renderCLIRunAction(w, raw, account)
	case getOperationToolName:
		rendered, ok = renderCLIGetOperation(w, raw, account)
	case waitForRunToolName:
		rendered, ok = renderCLIWaitForRun(w, raw)
	case recentRunsToolName:
		rendered, ok = renderCLIRecentRuns(w, raw)
	case listRunbooksToolName:
		rendered, ok = renderCLIListRunbooks(w, arguments, raw, account)
	case getRunbookToolName:
		rendered, ok = renderCLIGetRunbook(w, raw, account)
	case executeRunbookToolName:
		rendered, ok = renderCLIExecuteRunbook(w, raw, account)
	case createRunbookDraftToolName, updateRunbookDraftToolName:
		rendered, ok = renderCLIRunbookDraft(w, raw, account)
	default:
		return false, nil
	}
	if !ok {
		return false, nil
	}
	_, err := io.WriteString(w, rendered)
	return true, err
}

func writeCLIToolError(w io.Writer, toolName string, arguments, raw []byte, account string) (bool, error) {
	var result struct {
		OK              bool `json:"ok"`
		DispatchStarted bool `json:"dispatch_started"`
		Error           struct {
			Code      string            `json:"code"`
			Message   string            `json:"message"`
			Retryable bool              `json:"retryable"`
			Path      string            `json:"path"`
			Details   json.RawMessage   `json:"details"`
			Next      cliToolResultNext `json:"next"`
		} `json:"error"`
	}
	if json.Unmarshal(raw, &result) != nil || result.OK || result.Error.Message == "" {
		return false, nil
	}

	var out strings.Builder
	out.WriteString(cliStyledText(w, "31;1", "Error: "))
	out.WriteString(cliResultText(result.Error.Message, maxCLIHumanStringRunes))
	out.WriteByte('\n')
	if result.Error.Code != "" {
		fmt.Fprintf(&out, "\nCode  %s\n", cliResultText(result.Error.Code, 120))
	}
	detailsRendered := writeCLIErrorIssues(&out, arguments, result.Error.Details)
	if result.Error.Path != "" && !detailsRendered {
		fmt.Fprintf(&out, "Path  %s\n", cliResultText(result.Error.Path, 240))
	}
	if result.DispatchStarted {
		out.WriteString("\nThe mutation may have started. Recover it before retrying.\n")
	}
	if command := cliSafeReadContinuation(result.Error.Next, account); command != "" {
		fmt.Fprintf(&out, "\nNext  %s\n", command)
	} else if detailsRendered && result.Error.Code == "invalid_args" {
		if command := cliToolHelpCommand(toolName, account); command != "" {
			fmt.Fprintf(&out, "\nView the accepted arguments and constraints:\n  %s\n", command)
		}
	} else if len(result.Error.Details) > 0 && firstJSONByte(result.Error.Details) != 'n' {
		out.WriteString("\nMore details are available with --json.\n")
	}
	return true, writeString(w, out.String())
}

type cliErrorIssue struct {
	Path    string `json:"path"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeCLIErrorIssues(out *strings.Builder, arguments, raw json.RawMessage) bool {
	var details struct {
		IssueCount      int             `json:"issue_count"`
		IssuesTruncated bool            `json:"issues_truncated"`
		Issues          []cliErrorIssue `json:"issues"`
	}
	if firstJSONByte(raw) != '{' || json.Unmarshal(raw, &details) != nil || len(details.Issues) == 0 {
		return false
	}

	visible := details.Issues[:min(len(details.Issues), maxCLIErrorIssues)]
	total := max(details.IssueCount, len(details.Issues))
	fmt.Fprintf(out, "\n%s\n", plural(total, "Problem", "Problems"))
	for _, issue := range visible {
		path := cliErrorIssuePath(issue.Path)
		message := cliErrorIssueMessage(issue, cliArgumentValueKind(arguments, issue.Path))
		fmt.Fprintf(out, "  %s  %s\n", path, message)
	}

	if total > len(visible) {
		fmt.Fprintf(out, "  %d more %s; use --json for the complete report.\n", total-len(visible), plural(total-len(visible), "problem", "problems"))
	} else if details.IssuesTruncated {
		out.WriteString("  More problems are available with --json.\n")
	}
	return true
}

func cliErrorIssuePath(path string) string {
	path = cliResultText(terminalSafeLine(path), 240)
	switch {
	case path == "" || path == "$":
		return "arguments"
	case strings.HasPrefix(path, "$."):
		return strings.TrimPrefix(path, "$.")
	default:
		return path
	}
}

func cliErrorIssueMessage(issue cliErrorIssue, valueKind string) string {
	if message := cliResultText(terminalSafeLine(issue.Message), maxCLIHumanStringRunes); message != "" {
		return message
	}
	switch issue.Code {
	case "required":
		return "Is required."
	case "unknown", "unknown_arg":
		return "Is not an accepted argument."
	case "type":
		return "Has the wrong JSON type."
	case "format":
		return "Does not match the required format."
	case "duration":
		return "Must be a valid duration."
	case "path":
		return "Must be a valid path."
	case "enum", "allowed":
		return "Is not one of the allowed values."
	case "range":
		return "Is outside the allowed range."
	case "min":
		switch valueKind {
		case "string":
			return "Is shorter than the allowed minimum."
		case "array":
			return "Contains fewer items than allowed."
		default:
			return "Is below the allowed minimum."
		}
	case "max":
		return "Is above the allowed maximum."
	case "min_duration":
		return "Is shorter than the minimum duration."
	case "max_duration":
		return "Is longer than the maximum duration."
	case "size":
		return "Exceeds the allowed size."
	case "max_length":
		return "Is longer than allowed."
	case "max_items":
		return "Contains too many items."
	case "unique":
		return "Contains duplicate items."
	case "conflict":
		return "Conflicts with another argument."
	case "dependency":
		return "Requires another argument."
	default:
		return "Does not match the published schema."
	}
}

func cliArgumentValueKind(arguments []byte, path string) string {
	if firstJSONByte(arguments) == 0 || validateStrictJSON(arguments) != nil {
		return ""
	}
	decoder := json.NewDecoder(bytes.NewReader(arguments))
	decoder.UseNumber()
	var value any
	if decoder.Decode(&value) != nil {
		return ""
	}
	if strings.HasPrefix(path, "$.") {
		for _, segment := range strings.Split(strings.TrimPrefix(path, "$."), ".") {
			object, ok := value.(map[string]any)
			if !ok {
				return ""
			}
			value, ok = object[segment]
			if !ok {
				return ""
			}
		}
	} else if path != "$" {
		return ""
	}
	switch value.(type) {
	case string:
		return "string"
	case []any:
		return "array"
	case json.Number:
		return "number"
	case map[string]any:
		return "object"
	case bool:
		return "boolean"
	default:
		return ""
	}
}

func cliToolHelpCommand(toolName, account string) string {
	if toolName == "" || len(toolName) > 128 || terminalSafeLine(toolName) != toolName {
		return ""
	}
	prefix := "emisar-mcp "
	if account != "" {
		prefix += "--account " + shellQuoteForOS(terminalSafeText(account), runtime.GOOS) + " "
	}
	return prefix + "help " + shellQuoteForOS(toolName, runtime.GOOS)
}

func cliSafeReadContinuation(next cliToolResultNext, account string) string {
	switch next.Tool {
	case listRunnersToolName, listPacksToolName, findActionsToolName, getActionToolName,
		getOperationToolName, waitForRunToolName, recentRunsToolName,
		listRunbooksToolName, getRunbookToolName:
		fleetNext := cliFleetNext(next)
		return cliFleetNextCommandForOS(fleetNext, next.Tool, account, runtime.GOOS)
	default:
		return ""
	}
}

func renderCLIRuns(w io.Writer, runs []cliRunResult, includeIdentity bool) string {
	var out strings.Builder
	for index, run := range runs[:min(len(runs), maxCLIResultItems)] {
		if index > 0 {
			out.WriteByte('\n')
		}
		identity := cliResultText(run.RunnerRef, maxCLIFleetRefRunes)
		if identity == "" {
			identity = cliResultText(run.RunID, maxCLIFleetRefRunes)
		}
		out.WriteString(cliStyledText(w, "1", identity))
		out.WriteString(" — ")
		out.WriteString(cliResultStatus(w, run.Status))
		out.WriteByte('\n')
		if includeIdentity {
			writeCLIResultField(&out, "Run ID", run.RunID, maxCLIFleetRefRunes)
		}
		if run.StepID != "" {
			writeCLIResultField(&out, "Step", run.StepID, 160)
		}
		if run.ExitCode != nil {
			fmt.Fprintf(&out, "  Exit code  %d\n", *run.ExitCode)
		}
		if run.DurationMS != nil {
			fmt.Fprintf(&out, "  Duration  %s\n", cliResultDuration(*run.DurationMS))
		}
		if run.ErrorMessage != "" {
			fmt.Fprintf(&out, "  %s  %s\n", cliStyledText(w, "31", "Error"), cliResultText(run.ErrorMessage, maxCLIHumanStringRunes))
		}
		if run.Approval != nil {
			writeCLIResultField(&out, "Approval", run.Approval.URL, maxCLIFleetCommand)
			writeCLIResultField(&out, "Expires", cliFleetTime(run.Approval.ExpiresAt), 80)
		}
		writeCLIRunOutput(&out, run)
		if run.LocalAuditFailed {
			out.WriteString("  Warning  The runner could not complete its local audit record.\n")
		}
		if run.OutputComplete != nil && !*run.OutputComplete {
			out.WriteString("  Output is incomplete; use --json to inspect continuation data.\n")
		}
		if run.StructuredOmitted {
			out.WriteString("  Structured result omitted here; follow the returned continuation with --json.\n")
		}
	}
	if len(runs) > maxCLIResultItems {
		fmt.Fprintf(&out, "\n%d more runs omitted; use --json for the complete result.\n", len(runs)-maxCLIResultItems)
	}
	return out.String()
}

func writeCLIRunOutput(out *strings.Builder, run cliRunResult) {
	if run.Stdout != "" {
		writeCLIOutputBlock(out, "Output", run.Stdout)
	}
	if run.Stderr != "" {
		writeCLIOutputBlock(out, "Error output", run.Stderr)
	}
	for _, segment := range run.Output {
		label := "Output"
		if segment.Stream == "stderr" {
			label = "Error output"
		}
		writeCLIOutputBlock(out, label, segment.Text)
	}
	if firstJSONByte(run.StructuredOutput) != 0 && firstJSONByte(run.StructuredOutput) != 'n' {
		out.WriteString("  Result\n")
		writeCLIJSONBlock(out, "    ", run.StructuredOutput)
	}
}

func writeCLIOutputBlock(out *strings.Builder, label, value string) {
	value = cliResultMultiline(value, maxCLIResultOutputRunes)
	if value == "" {
		return
	}
	fmt.Fprintf(out, "  %s\n", label)
	for _, line := range strings.Split(value, "\n") {
		fmt.Fprintf(out, "    %s\n", terminalSafeText(line))
	}
}

func writeCLIResultField(out *strings.Builder, label, value string, limit int) {
	value = cliResultText(value, limit)
	if value != "" {
		fmt.Fprintf(out, "  %s  %s\n", label, value)
	}
}

func cliResultStatus(w io.Writer, value string) string {
	value = cliResultText(value, 60)
	switch value {
	case "success", "completed", "succeeded", "connected", "published":
		return cliStyledText(w, "32", value)
	case "failed", "error", "validation_failed", "unknown_action", "denied", "cancelled",
		"timed_out", "refused", "expired", "halted":
		return cliStyledText(w, "31", value)
	case "pending", "pending_approval", "sent", "running", "cancelling", "draft":
		return cliStyledText(w, "33", strings.ReplaceAll(value, "_", " "))
	default:
		return strings.ReplaceAll(value, "_", " ")
	}
}

func cliResultText(value string, limit int) string {
	value = terminalSafeText(value)
	runes := []rune(value)
	if len(runes) > limit {
		return string(runes[:limit]) + "…"
	}
	return value
}

func cliResultMultiline(value string, limit int) string {
	runes := []rune(value)
	if len(runes) > limit {
		value = string(runes[:limit]) + "…"
	}
	lines := strings.Split(value, "\n")
	for index, line := range lines {
		lines[index] = terminalSafeText(line)
	}
	return strings.Join(lines, "\n")
}

func cliResultDuration(milliseconds int64) string {
	if milliseconds < 1_000 {
		return fmt.Sprintf("%d ms", milliseconds)
	}
	seconds := float64(milliseconds) / 1_000
	if milliseconds%1_000 == 0 {
		return fmt.Sprintf("%.0f s", seconds)
	}
	return fmt.Sprintf("%.1f s", seconds)
}

func writeString(w io.Writer, value string) error {
	_, err := io.WriteString(w, value)
	return err
}
