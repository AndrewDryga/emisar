package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"runtime"
	"strconv"
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
	arguments, raw, inputSchema []byte,
	account string,
	successful bool,
) (bool, error) {
	if err := validateStrictJSON(raw); err != nil {
		return false, nil
	}
	if !successful {
		return writeCLIToolError(w, toolName, arguments, raw, inputSchema, account)
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

func writeCLIToolError(w io.Writer, toolName string, arguments, raw, inputSchema []byte, account string) (bool, error) {
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
	detailsRendered := writeCLIErrorIssues(&out, arguments, result.Error.Details, inputSchema)
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

func writeCLIErrorIssues(out *strings.Builder, arguments, raw, inputSchema json.RawMessage) bool {
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
	schema := cliDecodedSchema(inputSchema)
	fmt.Fprintf(out, "\n%s\n", plural(total, "Problem", "Problems"))
	for _, issue := range visible {
		path := cliErrorIssuePath(issue.Path)
		valueKind := cliArgumentValueKind(arguments, issue.Path)
		message := cliErrorIssueMessage(issue, valueKind, cliSchemaAtPath(schema, issue.Path))
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

func cliErrorIssueMessage(issue cliErrorIssue, valueKind string, schema map[string]any) string {
	if message := cliErrorConstraintMessage(issue.Code, valueKind, schema); message != "" {
		return message
	}
	if message := cliResultText(terminalSafeLine(issue.Message), maxCLIHumanStringRunes); message != "" {
		return message
	}
	switch issue.Code {
	case "required":
		return "Add this required argument."
	case "unknown", "unknown_arg":
		return "Remove this argument; it is not accepted."
	case "type":
		return "Use the required JSON type."
	case "format":
		return "Does not match the required format."
	case "duration":
		return "Must be a valid duration."
	case "path":
		return "Must be a valid path."
	case "enum", "allowed":
		return "Use one of the allowed values."
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
		return "Remove duplicate items."
	case "conflict":
		return "Remove one of the conflicting arguments."
	case "dependency":
		return "Requires another argument."
	default:
		return "Does not match the published schema."
	}
}

func cliDecodedSchema(raw json.RawMessage) map[string]any {
	if firstJSONByte(raw) != '{' || validateStrictJSON(raw) != nil {
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var schema map[string]any
	if decoder.Decode(&schema) != nil {
		return nil
	}
	return schema
}

func cliSchemaAtPath(root map[string]any, path string) map[string]any {
	if root == nil || path == "" || path == "$" || len(path) > 1024 || !strings.HasPrefix(path, "$.") {
		return nil
	}
	current := root
	for _, segment := range strings.Split(strings.TrimPrefix(path, "$."), ".") {
		resolved, ok := resolveSchema(current, root, map[string]bool{}, 0)
		if !ok {
			return nil
		}
		for typeValue(resolved["type"]) == "array" {
			items, ok := resolved["items"].(map[string]any)
			if !ok {
				return nil
			}
			resolved, ok = resolveSchema(items, root, map[string]bool{}, 0)
			if !ok {
				return nil
			}
		}
		properties := make(map[string]any)
		if !collectTopLevelSchema(resolved, root, properties, map[string]bool{}, map[string]bool{}, 0) {
			return nil
		}
		next, ok := properties[segment].(map[string]any)
		if !ok {
			return nil
		}
		current = next
	}
	resolved, ok := resolveSchema(current, root, map[string]bool{}, 0)
	if !ok {
		return nil
	}
	return resolved
}

func cliErrorConstraintMessage(code, valueKind string, schema map[string]any) string {
	if schema == nil {
		return ""
	}
	if valueKind == "" {
		valueKind = typeValue(schema["type"])
	}
	switch code {
	case "min":
		if valueKind == "string" {
			return cliErrorBoundMessage(schema["minLength"], "at least", "character", "characters")
		}
		if valueKind == "array" {
			return cliErrorBoundMessage(schema["minItems"], "at least", "item", "items")
		}
		return cliErrorBoundMessage(schema["minimum"], "at least", "", "")
	case "max":
		if valueKind == "string" {
			return cliErrorBoundMessage(schema["maxLength"], "at most", "character", "characters")
		}
		if valueKind == "array" {
			return cliErrorBoundMessage(schema["maxItems"], "at most", "item", "items")
		}
		return cliErrorBoundMessage(schema["maximum"], "at most", "", "")
	case "max_length":
		return cliErrorBoundMessage(schema["maxLength"], "at most", "character", "characters")
	case "max_items":
		return cliErrorBoundMessage(schema["maxItems"], "at most", "item", "items")
	case "enum", "allowed":
		return cliErrorAllowedValues(schema["enum"])
	case "type":
		return cliErrorTypeMessage(typeValue(schema["type"]))
	case "format":
		if stringValue(schema["pattern"]) == `\S` {
			return "Use a non-blank value."
		}
	}
	return ""
}

func cliErrorBoundMessage(value any, relation, singular, pluralValue string) string {
	number, ok := value.(json.Number)
	if !ok || len(number.String()) > 32 {
		return ""
	}
	if _, err := strconv.ParseFloat(number.String(), 64); err != nil {
		return ""
	}
	encoded := schemaJSONValue(value)
	if encoded == "" {
		return ""
	}
	if singular == "" {
		if relation == "at least" {
			return cliResultText(fmt.Sprintf("Use %s or greater.", encoded), maxCLIHumanStringRunes)
		}
		if relation == "at most" {
			return cliResultText(fmt.Sprintf("Use %s or less.", encoded), maxCLIHumanStringRunes)
		}
		return ""
	}
	unit := pluralValue
	if encoded == "1" {
		unit = singular
	}
	return cliResultText(fmt.Sprintf("Use %s %s %s.", relation, encoded, unit), maxCLIHumanStringRunes)
}

func cliErrorAllowedValues(value any) string {
	values, ok := value.([]any)
	if !ok || len(values) == 0 || len(values) > 16 {
		return ""
	}
	rendered := make([]string, 0, len(values))
	for _, value := range values {
		encoded := schemaJSONValue(value)
		if encoded == "" || len(encoded) > 160 {
			return ""
		}
		rendered = append(rendered, encoded)
	}
	return cliResultText("Use one of: "+strings.Join(rendered, ", ")+".", maxCLIHumanStringRunes)
}

func cliErrorTypeMessage(value string) string {
	switch value {
	case "string":
		return "Use a JSON string."
	case "integer":
		return "Use a whole JSON number."
	case "number":
		return "Use a JSON number."
	case "array":
		return "Use a JSON array."
	case "object":
		return "Use a JSON object."
	case "boolean":
		return "Use true or false."
	default:
		return ""
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
