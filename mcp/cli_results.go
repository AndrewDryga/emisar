package main

import (
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
		return writeCLIToolError(w, raw, account)
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

func writeCLIToolError(w io.Writer, raw []byte, account string) (bool, error) {
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
	if result.Error.Path != "" {
		fmt.Fprintf(&out, "Path  %s\n", cliResultText(result.Error.Path, 240))
	}
	if result.DispatchStarted {
		out.WriteString("\nThe mutation may have started. Recover it before retrying.\n")
	}
	if command := cliSafeReadContinuation(result.Error.Next, account); command != "" {
		fmt.Fprintf(&out, "\nNext  %s\n", command)
	} else if len(result.Error.Details) > 0 && firstJSONByte(result.Error.Details) != 'n' {
		out.WriteString("\nMore details are available with --json.\n")
	}
	return true, writeString(w, out.String())
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
