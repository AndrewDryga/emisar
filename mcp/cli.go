package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

const cliProtocolVersion = "2026-07-28"

const findActionsToolName = "find_actions"

const cliOperationRecoveryStep = "The request may have reached the server. Use the operation ID in stdout with `get_operation` before retrying a mutation."

const maxCLISchemaRenderDepth = 32
const maxCLIOutputRenderDepth = 64
const maxCLIHumanStringRunes = 240
const maxCLIHumanUnbrokenStringRunes = 96
const maxCLIHumanFieldAlignmentRunes = 32

type cliRPCResponse struct {
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"`
}

type cliToolDescriptor struct {
	Name        string          `json:"name"`
	Title       string          `json:"title"`
	Description string          `json:"description"`
	Annotations cliAnnotations  `json:"annotations"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

type cliAnnotations struct {
	ReadOnly    bool `json:"readOnlyHint"`
	Destructive bool `json:"destructiveHint"`
}

func validateCLIInvocation(args []string) error {
	if len(args) == 0 {
		return nil
	}
	switch args[0] {
	case "--":
		if len(args) < 2 {
			return errors.New("usage: emisar-mcp -- <tool> [JSON | -] [--json]")
		}
		usage := cliToolCallUsage(args[1], true)
		callArgs, _, err := splitCLIJSONOutputFlag(args[2:])
		if err != nil {
			return fmt.Errorf("%w; usage: %s", err, usage)
		}
		if len(callArgs) > 1 {
			return fmt.Errorf("usage: %s", usage)
		}
	case "list_tools":
		if len(args) > 2 || (len(args) == 2 && args[1] != "--json") {
			return errors.New("usage: emisar-mcp list_tools [--json]")
		}
	case "help":
		if len(args) < 2 || len(args) > 3 || (len(args) == 3 && args[2] != "--json") {
			return errors.New("usage: emisar-mcp help <tool> [--json]")
		}
	default:
		usage := cliToolCallUsage(args[0], false)
		callArgs, _, err := splitCLIJSONOutputFlag(args[1:])
		if err != nil {
			return fmt.Errorf("%w; usage: %s", err, usage)
		}
		if len(callArgs) > 1 {
			return fmt.Errorf("usage: %s", usage)
		}
		if len(callArgs) == 1 && strings.HasPrefix(callArgs[0], "--") && callArgs[0] != "--help" {
			return fmt.Errorf("unknown option %q; usage: %s", displayCLIOption(callArgs[0]), usage)
		}
	}
	return nil
}

func cliToolCallUsage(toolName string, exact bool) string {
	if toolName == findActionsToolName {
		prefix := "emisar-mcp "
		if exact {
			prefix += "-- "
		}
		return prefix + findActionsToolName + " [TEXT | JSON | -] [--json]"
	}
	if exact {
		return "emisar-mcp -- <tool> [JSON | -] [--json]"
	}
	return "emisar-mcp <tool> [JSON | -] [--json]"
}

func (b *bridge) runCLI(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	return b.runCLIContext(context.Background(), args, stdin, stdout, stderr)
}

func (b *bridge) runCLIContext(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	b.directCLI = true
	b.diagnostics = stderr
	if err := validateCLIInvocation(args); err != nil {
		return cliUsageError(stderr, err.Error())
	}
	command := args[0]
	switch command {
	case "--":
		callArgs, exactJSON, _ := splitCLIJSONOutputFlag(args[2:])
		arguments, err := readCLIArguments(args[1], callArgs, stdin)
		if err != nil {
			return cliUsageError(stderr, err.Error())
		}
		return b.runToolCallContext(ctx, args[1], arguments, exactJSON, stdout, stderr)

	case "list_tools":
		return b.runListTools(len(args) == 2, stdout, stderr)

	case "help":
		return b.runToolHelp(args[1], len(args) == 3, stdout, stderr)

	default:
		callArgs, exactJSON, _ := splitCLIJSONOutputFlag(args[1:])
		if len(callArgs) == 1 && (callArgs[0] == "-h" || callArgs[0] == "--help") {
			return b.runToolHelp(command, exactJSON, stdout, stderr)
		}
		arguments, err := readCLIArguments(command, callArgs, stdin)
		if err != nil {
			return cliUsageError(stderr, err.Error())
		}
		return b.runToolCallContext(ctx, command, arguments, exactJSON, stdout, stderr)
	}
}

func splitCLIJSONOutputFlag(args []string) ([]string, bool, error) {
	if len(args) == 0 {
		return args, false, nil
	}
	for index, arg := range args {
		if arg != "--json" {
			continue
		}
		if index != len(args)-1 {
			return nil, false, errors.New("--json must be the final argument")
		}
		return args[:index], true, nil
	}
	return args, false, nil
}

func (b *bridge) runListTools(exactJSON bool, stdout, stderr io.Writer) int {
	tools, descriptors, code := b.fetchToolDescriptors(exactJSON, stdout, stderr)
	if code != 0 {
		return code
	}
	if exactJSON {
		if err := writePrettyJSON(stdout, tools); err != nil {
			return cliFailure(stderr, "write tool descriptors", err)
		}
		return 0
	}
	toolList, err := renderToolList(descriptors)
	if err != nil {
		return cliFailure(stderr, "render tool list", err)
	}
	if _, err := io.WriteString(stdout, toolList); err != nil {
		return cliFailure(stderr, "write tool list", err)
	}
	return 0
}

func (b *bridge) runToolHelp(name string, exactJSON bool, stdout, stderr io.Writer) int {
	_, descriptors, code := b.fetchToolDescriptors(exactJSON, stdout, stderr)
	if code != 0 {
		return code
	}
	for _, raw := range descriptors {
		var descriptor cliToolDescriptor
		if err := json.Unmarshal(raw, &descriptor); err != nil {
			return cliFailure(stderr, "decode tool descriptor", err)
		}
		if descriptor.Name != name {
			continue
		}
		if exactJSON {
			if err := writePrettyJSON(stdout, raw); err != nil {
				return cliFailure(stderr, "write tool descriptor", err)
			}
			return 0
		}
		help, err := renderToolHelp(descriptor)
		if err != nil {
			return cliFailure(stderr, "render tool help", err)
		}
		if _, err := io.WriteString(stdout, help); err != nil {
			return cliFailure(stderr, "write tool help", err)
		}
		return 0
	}
	return cliInputError(
		stderr,
		fmt.Sprintf("Unknown MCP tool %q", name),
		"Run `emisar-mcp list_tools` to see the tools published by this server.",
	)
}

func (b *bridge) runToolCallContext(ctx context.Context, name string, arguments json.RawMessage, exactJSON bool, stdout, stderr io.Writer) int {
	response, operationID, err := b.cliRoundTripContext(ctx, "tools/call", name, arguments)
	if err != nil {
		return b.writeCLICallFailure(operationID, err, exactJSON, stdout, stderr)
	}
	if len(response.Error) > 0 {
		if err := writeCLIOutput(stdout, response.Error, exactJSON); err != nil {
			return cliFailure(stderr, "write MCP error", err)
		}
		return 1
	}

	var result struct {
		StructuredContent json.RawMessage `json:"structuredContent"`
		IsError           bool            `json:"isError"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil {
		return b.writeCLICallResponseFailure(operationID, "decode tool result", err, exactJSON, stdout, stderr)
	}
	if len(result.StructuredContent) == 0 || firstJSONByte(result.StructuredContent) != '{' {
		return b.writeCLICallResponseFailure(
			operationID,
			"decode tool result",
			errors.New("control plane returned no structuredContent object"),
			exactJSON,
			stdout,
			stderr,
		)
	}
	if !exactJSON && !result.IsError {
		if err := validateCLIHumanMutation(name, operationID, result.StructuredContent); err != nil {
			return b.writeCLIFollowFailure(stderr, operationID, err)
		}
	}
	var inputSchema json.RawMessage
	if !exactJSON && result.IsError && cliInvalidArgumentsFailure(result.StructuredContent) {
		inputSchema = b.fetchCLIInputSchema(ctx, name)
	}
	if err := writeCLIToolOutputWithSchema(stdout, name, arguments, result.StructuredContent, inputSchema, b.cliAccount, exactJSON, !result.IsError); err != nil {
		return cliFailure(stderr, "write tool result", err)
	}
	if result.IsError {
		return 1
	}
	if !exactJSON {
		if handled, code := b.followCLIMutation(ctx, name, operationID, result.StructuredContent, stdout, stderr); handled {
			return code
		}
	}
	return 0
}

func cliInvalidArgumentsFailure(raw json.RawMessage) bool {
	var result struct {
		OK              bool `json:"ok"`
		DispatchStarted bool `json:"dispatch_started"`
		Error           struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	return json.Unmarshal(raw, &result) == nil && !result.OK && !result.DispatchStarted &&
		result.Error.Code == "invalid_args"
}

func (b *bridge) fetchCLIInputSchema(ctx context.Context, toolName string) json.RawMessage {
	response, _, err := b.cliRoundTripContext(ctx, "tools/list", "", nil)
	if err != nil || len(response.Error) > 0 {
		return nil
	}
	var result struct {
		Tools []json.RawMessage `json:"tools"`
	}
	if json.Unmarshal(response.Result, &result) != nil || validateToolDescriptors(result.Tools) != nil {
		return nil
	}
	for _, raw := range result.Tools {
		var descriptor cliToolDescriptor
		if json.Unmarshal(raw, &descriptor) == nil && descriptor.Name == toolName &&
			firstJSONByte(descriptor.InputSchema) == '{' && validateStrictJSON(descriptor.InputSchema) == nil {
			return descriptor.InputSchema
		}
	}
	return nil
}

func (b *bridge) fetchToolDescriptors(exactJSON bool, stdout, stderr io.Writer) (json.RawMessage, []json.RawMessage, int) {
	response, _, err := b.cliRoundTrip("tools/list", "", nil)
	if err != nil {
		return nil, nil, cliFailure(stderr, "list tools", err)
	}
	if len(response.Error) > 0 {
		if err := writeCLIOutput(stdout, response.Error, exactJSON); err != nil {
			return nil, nil, cliFailure(stderr, "write MCP error", err)
		}
		return nil, nil, 1
	}

	var result struct {
		Tools json.RawMessage `json:"tools"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil {
		return nil, nil, cliFailure(stderr, "decode tools/list result", err)
	}
	if firstJSONByte(result.Tools) != '[' {
		return nil, nil, cliFailure(stderr, "decode tools/list result", errors.New("control plane returned no tools array"))
	}
	var descriptors []json.RawMessage
	if err := json.Unmarshal(result.Tools, &descriptors); err != nil {
		return nil, nil, cliFailure(stderr, "decode tool descriptors", err)
	}
	if err := validateToolDescriptors(descriptors); err != nil {
		return nil, nil, cliFailure(stderr, "decode tool descriptors", err)
	}
	return result.Tools, descriptors, 0
}

func validateToolDescriptors(descriptors []json.RawMessage) error {
	seen := make(map[string]struct{}, len(descriptors))
	for index, raw := range descriptors {
		var descriptor cliToolDescriptor
		if err := json.Unmarshal(raw, &descriptor); err != nil {
			return fmt.Errorf("descriptor %d: %w", index+1, err)
		}
		if descriptor.Name == "" {
			return fmt.Errorf("descriptor %d: name is empty", index+1)
		}
		if _, duplicate := seen[descriptor.Name]; duplicate {
			return fmt.Errorf("descriptor %d: duplicate name %q", index+1, descriptor.Name)
		}
		seen[descriptor.Name] = struct{}{}
	}
	return nil
}

func (b *bridge) cliRoundTrip(method, name string, arguments json.RawMessage) (cliRPCResponse, string, error) {
	return b.cliRoundTripContext(context.Background(), method, name, arguments)
}

func (b *bridge) cliRoundTripContext(ctx context.Context, method, name string, arguments json.RawMessage) (cliRPCResponse, string, error) {
	frame, err := buildCLIFrame(method, name, arguments)
	if err != nil {
		return cliRPCResponse{}, "", localBridge(err)
	}
	if len(frame) > maxFrameBytes {
		return cliRPCResponse{}, "", localBridge(fmt.Errorf("request frame exceeds %d bytes", maxFrameBytes))
	}
	meta := parseRequestMeta(frame)
	b.stateMu.Lock()
	b.cliSequence++
	sequence := b.cliSequence
	b.stateMu.Unlock()
	requestToken := b.requestToken(sequence)
	operationID := toolCallOperationID(meta, requestToken)
	body, err := b.forwardRequestContext(ctx, frame, meta, requestHeaders{
		requestToken: requestToken,
		operationID:  operationID,
	})
	if err != nil {
		return cliRPCResponse{}, operationID, err
	}
	var response cliRPCResponse
	if err := json.Unmarshal(body, &response); err != nil {
		return cliRPCResponse{}, operationID, fmt.Errorf("decode JSON-RPC response: %w", err)
	}
	return response, operationID, nil
}

func buildCLIFrame(method, name string, arguments json.RawMessage) ([]byte, error) {
	params := struct {
		Name      string            `json:"name,omitempty"`
		Arguments json.RawMessage   `json:"arguments,omitempty"`
		Meta      map[string]string `json:"_meta"`
	}{
		Name:      name,
		Arguments: arguments,
		Meta:      map[string]string{protocolVersionMetaKey: cliProtocolVersion},
	}
	frame, err := json.Marshal(struct {
		JSONRPC string `json:"jsonrpc"`
		ID      int    `json:"id"`
		Method  string `json:"method"`
		Params  any    `json:"params"`
	}{
		JSONRPC: "2.0",
		ID:      1,
		Method:  method,
		Params:  params,
	})
	if err != nil {
		return nil, fmt.Errorf("encode CLI request: %w", err)
	}
	return frame, nil
}

func readCLIArguments(toolName string, args []string, stdin io.Reader) (json.RawMessage, error) {
	if len(args) == 0 {
		return json.RawMessage(`{}`), nil
	}
	var raw []byte
	if args[0] == "-" {
		var err error
		raw, err = io.ReadAll(io.LimitReader(stdin, maxFrameBytes+1))
		if err != nil {
			return nil, fmt.Errorf("read JSON arguments from stdin: %w", err)
		}
		if len(raw) > maxFrameBytes {
			return nil, fmt.Errorf("JSON arguments exceed %d bytes", maxFrameBytes)
		}
	} else {
		raw = []byte(args[0])
	}
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return nil, errors.New("tool arguments must be one JSON object")
	}
	if len(raw) > maxFrameBytes {
		return nil, fmt.Errorf("JSON arguments exceed %d bytes", maxFrameBytes)
	}
	if toolName == findActionsToolName && raw[0] != '{' && raw[0] != '[' {
		if !utf8.Valid(raw) {
			return nil, errors.New("find_actions text query must be valid UTF-8")
		}
		arguments, err := json.Marshal(struct {
			Query string `json:"query"`
		}{Query: string(raw)})
		if err != nil {
			return nil, fmt.Errorf("encode find_actions text query: %w", err)
		}
		if len(arguments) > maxFrameBytes {
			return nil, fmt.Errorf("JSON arguments exceed %d bytes", maxFrameBytes)
		}
		return arguments, nil
	}
	if err := validateStrictJSON(raw); err != nil {
		return nil, fmt.Errorf("tool arguments are not strict JSON: %w", err)
	}
	if firstJSONByte(raw) != '{' {
		return nil, errors.New("tool arguments must be one JSON object")
	}
	return json.RawMessage(raw), nil
}

func writePrettyJSON(w io.Writer, raw []byte) error {
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, bytes.TrimSpace(raw), "", "  "); err != nil {
		return err
	}
	pretty.WriteByte('\n')
	_, err := w.Write(pretty.Bytes())
	return err
}

func writeCLIOutput(w io.Writer, raw []byte, exactJSON bool) error {
	if exactJSON {
		return writePrettyJSON(w, raw)
	}
	return writeHumanJSON(w, raw)
}

func writeCLIToolOutput(
	w io.Writer,
	toolName string,
	arguments, raw []byte,
	account string,
	exactJSON, successful bool,
) error {
	return writeCLIToolOutputWithSchema(w, toolName, arguments, raw, nil, account, exactJSON, successful)
}

func writeCLIToolOutputWithSchema(
	w io.Writer,
	toolName string,
	arguments, raw, inputSchema []byte,
	account string,
	exactJSON, successful bool,
) error {
	if exactJSON {
		return writePrettyJSON(w, raw)
	}
	if successful {
		if handled, err := writeCLIFleetOutput(w, toolName, arguments, raw, account); handled {
			return err
		}
	}
	if handled, err := writeCLIOperatorOutput(w, toolName, arguments, raw, inputSchema, account, successful); handled {
		return err
	}
	return writeHumanJSON(w, raw)
}

func writeHumanJSON(w io.Writer, raw []byte) error {
	if err := validateStrictJSON(raw); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return err
	}
	var out strings.Builder
	renderer := cliHumanRenderer{out: &out}
	renderer.renderValue(value, "", 0)
	rendered := strings.TrimRight(out.String(), "\n")
	if rendered == "" {
		rendered = "No data."
	}
	_, err := io.WriteString(w, rendered+"\n")
	return err
}

type cliHumanRenderer struct {
	out *strings.Builder
}

type cliHumanField struct {
	key   string
	label string
	value any
}

func (r cliHumanRenderer) renderValue(value any, indent string, depth int) {
	if depth > maxCLIOutputRenderDepth {
		r.line(indent, "More details omitted; use --json.")
		return
	}
	if scalar, ok := humanJSONScalar(value); ok {
		r.line(indent, scalar)
		return
	}
	switch value := value.(type) {
	case map[string]any:
		r.renderObject(value, indent, depth)
	case []any:
		r.renderArray(value, indent, depth)
	}
}

func (r cliHumanRenderer) renderObject(value map[string]any, indent string, depth int) {
	if depth > maxCLIOutputRenderDepth {
		r.line(indent, "More details omitted; use --json.")
		return
	}
	fields := humanJSONFields(value)
	if len(fields) == 0 {
		r.line(indent, "Empty object")
		return
	}
	var simple, complex []cliHumanField
	for _, field := range fields {
		if _, ok := humanJSONFieldValue(field); ok {
			simple = append(simple, field)
			continue
		}
		complex = append(complex, field)
	}
	if len(simple) > 0 {
		r.renderFields(simple, indent)
	}
	for index, field := range complex {
		if len(simple) > 0 || index > 0 {
			r.blank()
		}
		switch child := field.value.(type) {
		case []any:
			r.line(indent, fmt.Sprintf("%s (%d)", field.label, len(child)))
			r.blank()
			r.renderArray(child, indent, depth+1)
		case map[string]any:
			r.line(indent, field.label)
			r.renderObject(child, indent+"  ", depth+1)
		}
	}
}

func (r cliHumanRenderer) renderArray(value []any, indent string, depth int) {
	if depth > maxCLIOutputRenderDepth {
		r.line(indent, "More details omitted; use --json.")
		return
	}
	if len(value) == 0 {
		r.line(indent, "Empty list")
		return
	}
	allScalars := true
	allObjects := true
	for _, child := range value {
		if _, ok := humanJSONScalar(child); !ok {
			allScalars = false
		}
		if _, ok := child.(map[string]any); !ok {
			allObjects = false
		}
	}
	if allScalars {
		for _, child := range value {
			scalar, _ := humanJSONScalar(child)
			r.line(indent+"• ", scalar)
		}
		return
	}
	if allObjects {
		for index, child := range value {
			if index > 0 {
				r.blank()
			}
			r.renderRecord(index+1, len(value), child.(map[string]any), indent, depth+1)
		}
		return
	}
	for index, child := range value {
		if index > 0 {
			r.blank()
		}
		if object, ok := child.(map[string]any); ok {
			r.renderRecord(index+1, len(value), object, indent, depth+1)
			continue
		}
		marker := fmt.Sprintf("Item %d of %d", index+1, len(value))
		if simple, ok := humanJSONSimpleValue(child); ok {
			r.line(indent+marker+" — ", simple)
			continue
		}
		r.line(indent, marker)
		r.renderValue(child, indent+"  ", depth+1)
	}
}

func (r cliHumanRenderer) renderRecord(number, total int, value map[string]any, indent string, depth int) {
	marker := fmt.Sprintf("Item %d of %d", number, total)
	contentIndent := indent + "  "
	if len(value) == 0 {
		r.line(indent+marker+" — ", "Empty object")
		return
	}
	r.line(indent, marker)
	r.renderObject(value, contentIndent, depth)
}

func (r cliHumanRenderer) renderFields(fields []cliHumanField, indent string) {
	width := 0
	for _, field := range fields {
		if length := len([]rune(field.label)); length > width && width < maxCLIHumanFieldAlignmentRunes {
			width = length
			if width > maxCLIHumanFieldAlignmentRunes {
				width = maxCLIHumanFieldAlignmentRunes
			}
		}
	}
	for _, field := range fields {
		value, _ := humanJSONFieldValue(field)
		paddingWidth := width - len([]rune(field.label))
		if paddingWidth < 0 {
			paddingWidth = 0
		}
		padding := strings.Repeat(" ", paddingWidth)
		prefix := indent + field.label + padding + "  "
		r.line(prefix, value)
	}
}

func (r cliHumanRenderer) line(prefix, text string) {
	r.out.WriteString(prefix)
	r.out.WriteString(text)
	r.out.WriteByte('\n')
}

func (r cliHumanRenderer) blank() {
	if r.out.Len() > 0 && !strings.HasSuffix(r.out.String(), "\n\n") {
		r.out.WriteByte('\n')
	}
}

func humanJSONScalar(value any) (string, bool) {
	switch value := value.(type) {
	case nil:
		return "Not set (null)", true
	case bool:
		if value {
			return "Yes", true
		}
		return "No", true
	case json.Number:
		return value.String(), true
	case string:
		if value == "" {
			return "Empty string", true
		}
		safe := terminalSafeLine(value)
		if strings.TrimSpace(safe) == "" {
			return "Blank string", true
		}
		runes := []rune(safe)
		limit := maxCLIHumanStringRunes
		if !strings.ContainsFunc(safe, unicode.IsSpace) {
			limit = maxCLIHumanUnbrokenStringRunes
		}
		if len(runes) > limit {
			short := string(runes[:limit])
			if lastSpace := strings.LastIndexFunc(short, unicode.IsSpace); lastSpace >= limit/2 {
				short = strings.TrimSpace(short[:lastSpace])
			}
			safe = short + "… [truncated; use --json]"
		}
		return safe, true
	default:
		return "", false
	}
}

func humanJSONSimpleValue(value any) (string, bool) {
	if scalar, ok := humanJSONScalar(value); ok {
		return scalar, true
	}
	switch value := value.(type) {
	case []any:
		if len(value) == 0 {
			return "Empty list", true
		}
	case map[string]any:
		if len(value) == 0 {
			return "Empty object", true
		}
	}
	return "", false
}

func humanJSONFieldValue(field cliHumanField) (string, bool) {
	return humanJSONSimpleValue(field.value)
}

func humanJSONFields(value map[string]any) []cliHumanField {
	fields := make([]cliHumanField, 0, len(value))
	for key, child := range value {
		fields = append(fields, cliHumanField{key: key, label: humanJSONLabel(key), value: child})
	}
	sort.Slice(fields, func(i, j int) bool {
		return fields[i].key < fields[j].key
	})
	labels := make(map[string]int, len(fields))
	for _, field := range fields {
		labels[field.label]++
	}
	for index, field := range fields {
		if labels[field.label] > 1 {
			fields[index].label += " [key " + strconv.QuoteToASCII(field.key) + "]"
		}
	}
	return fields
}

func humanJSONLabel(key string) string {
	safe := terminalSafeText(key)
	words := strings.FieldsFunc(safe, func(r rune) bool {
		return r == '_' || r == '-' || unicode.IsSpace(r)
	})
	if len(words) == 0 {
		return "Unnamed field [key " + strconv.QuoteToASCII(key) + "]"
	}
	for index, word := range words {
		switch strings.ToLower(word) {
		case "api", "id", "mcp", "ok", "sha", "sha256", "uri", "url":
			words[index] = strings.ToUpper(word)
		case "":
			continue
		default:
			if index == 0 {
				runes := []rune(word)
				runes[0] = unicode.ToUpper(runes[0])
				words[index] = string(runes)
			}
		}
	}
	return strings.Join(words, " ")
}

func (b *bridge) writeCLICallFailure(operationID string, callErr error, exactJSON bool, stdout, stderr io.Writer) int {
	message := "upstream transport error"
	if bridgeProducedError(callErr) {
		message = "emisar bridge could not send this request"
		operationID = ""
	}
	summary := "The control plane request failed"
	next := []string{"Check the control plane status and version, then try again."}
	if localTransportError(callErr) {
		summary = "Could not reach the control plane"
		next = []string{"Check the server URL and your network connection, then try again."}
	}
	if bridgeProducedError(callErr) {
		summary = "The request could not be sent"
		next = []string{"Fix the local error above, then try again."}
		switch message := callErr.Error(); {
		case strings.Contains(message, "request frame exceeds"):
			summary = "The request is too large"
			next = []string{"Reduce the JSON arguments, then try again."}
		case strings.Contains(message, "attest") || strings.Contains(message, "sign"):
			summary = "The request could not be signed"
			next = []string{"Check EMISAR_SIGNING_KEY and EMISAR_SIGNING_CERT, then try again."}
		case strings.Contains(message, "credential"):
			summary = "The account credential could not be used"
			next = []string{"Check the credential file permissions, then run `emisar-mcp auth` again if needed."}
		}
	}
	if operationID != "" {
		next = append([]string{cliOperationRecoveryStep}, next...)
	}
	writeCLIDiagnostic(stderr, cliDiagnostic{
		Kind:    cliDiagnosticError,
		Summary: summary,
		Details: []string{callErr.Error()},
		Next:    next,
	})
	return writeCLICallError(message, operationID, exactJSON, stdout, stderr)
}

func (b *bridge) writeCLICallResponseFailure(
	operationID, action string,
	responseErr error,
	exactJSON bool,
	stdout, stderr io.Writer,
) int {
	next := []string{"Upgrade the Emisar server and CLI together, then try again."}
	if operationID != "" {
		next = append([]string{cliOperationRecoveryStep}, next...)
	}
	writeCLIDiagnostic(stderr, cliDiagnostic{
		Kind:    cliDiagnosticError,
		Summary: "The control plane returned an invalid tool response",
		Details: []string{action + ": " + responseErr.Error()},
		Next:    next,
	})
	return writeCLICallError("invalid upstream tool response", operationID, exactJSON, stdout, stderr)
}

func writeCLICallError(message, operationID string, exactJSON bool, stdout, stderr io.Writer) int {
	var data *transportErrorData
	if operationID != "" {
		data = &transportErrorData{OperationID: operationID}
	}
	errorObject := struct {
		Code    int                 `json:"code"`
		Message string              `json:"message"`
		Data    *transportErrorData `json:"data,omitempty"`
	}{Code: -32603, Message: message, Data: data}
	raw, err := json.Marshal(errorObject)
	if err != nil {
		panic("marshal fixed CLI error: " + err.Error())
	}
	if err := writeCLIOutput(stdout, raw, exactJSON); err != nil {
		return cliFailure(stderr, "write transport error", err)
	}
	return 1
}

func renderToolList(rawDescriptors []json.RawMessage) (string, error) {
	descriptors := make([]cliToolDescriptor, 0, len(rawDescriptors))
	byName := make(map[string]cliToolDescriptor, len(rawDescriptors))
	for _, raw := range rawDescriptors {
		var descriptor cliToolDescriptor
		if err := json.Unmarshal(raw, &descriptor); err != nil {
			return "", fmt.Errorf("decode tool descriptor: %w", err)
		}
		if descriptor.Name == "" {
			return "", errors.New("decode tool descriptor: name is empty")
		}
		descriptors = append(descriptors, descriptor)
		byName[descriptor.Name] = descriptor
	}

	groups := []struct {
		title string
		names []string
	}{
		{"FLEET", []string{"list_runners", "list_packs"}},
		{"ACTIONS", []string{"find_actions", "get_action", "run_action", "get_operation", "recent_runs"}},
		{"RUNBOOKS", []string{"list_runbooks", "get_runbook", "execute_runbook", "create_runbook_draft", "update_runbook_draft"}},
		{"CONTINUATIONS", []string{"wait_for_run"}},
	}
	used := make(map[string]bool, len(descriptors))
	var out strings.Builder
	fmt.Fprintf(&out, "%d MCP tools\n", len(rawDescriptors))
	writeGroup := func(title string, members []cliToolDescriptor) {
		if len(members) == 0 {
			return
		}
		fmt.Fprintf(&out, "\n%s\n", title)
		for _, descriptor := range members {
			fmt.Fprintf(&out, "\n  %s  [%s]\n", terminalSafeText(descriptor.Name), descriptorKind(descriptor.Annotations))
			out.WriteString("    ")
			out.WriteString(terminalSafeLine(descriptor.Description))
			out.WriteByte('\n')
			used[descriptor.Name] = true
		}
	}
	for _, group := range groups {
		members := make([]cliToolDescriptor, 0, len(group.names))
		for _, name := range group.names {
			if descriptor, ok := byName[name]; ok {
				members = append(members, descriptor)
			}
		}
		writeGroup(group.title, members)
	}
	other := make([]cliToolDescriptor, 0)
	for _, descriptor := range descriptors {
		if !used[descriptor.Name] {
			other = append(other, descriptor)
		}
	}
	writeGroup("OTHER MCP TOOLS", other)
	out.WriteString("\nUse 'emisar-mcp help <tool>' for live arguments.\n")
	out.WriteString("Add --json for the exact descriptors used by scripts and LLMs.\n")
	return out.String(), nil
}

func renderToolHelp(descriptor cliToolDescriptor) (string, error) {
	var schema map[string]any
	decoder := json.NewDecoder(bytes.NewReader(descriptor.InputSchema))
	decoder.UseNumber()
	if err := decoder.Decode(&schema); err != nil {
		return "", fmt.Errorf("decode inputSchema: %w", err)
	}
	if schema == nil {
		return "", errors.New("decode inputSchema: expected an object")
	}

	var out strings.Builder
	title := descriptor.Title
	if title == "" {
		title = descriptor.Name
	}
	safeName := terminalSafeText(descriptor.Name)
	fmt.Fprintf(&out, "%s — %s\n", safeName, terminalSafeText(title))
	fmt.Fprintf(&out, "%s\n\n", descriptorKind(descriptor.Annotations))
	out.WriteString(terminalSafeLine(descriptor.Description))
	argumentUsage := "JSON | -"
	if descriptor.Name == findActionsToolName {
		argumentUsage = "TEXT | JSON | -"
	}
	fmt.Fprintf(&out, "\n\nUSAGE\n  %s [%s] [--json]\n", cliToolInvocation(descriptor.Name), argumentUsage)
	if descriptor.Name == findActionsToolName {
		out.WriteString("\nTEXT INPUT\n")
		out.WriteString("  Plain text is sent as the query argument. Use JSON for filters or cursors.\n")
	}

	arguments, crossFieldRules, ok := describeTopLevelArguments(schema)
	if crossFieldRules {
		out.WriteString("\nCROSS-FIELD RULES\n")
		out.WriteString("  Some arguments are conditionally required or mutually exclusive.\n")
		out.WriteString("  The complete input schema is authoritative; print it with the command below.\n")
	}
	out.WriteString("\nARGUMENTS\n")
	if !ok {
		out.WriteString("  Complex or recursive JSON object. Use the complete input schema.\n")
	} else if len(arguments) == 0 && crossFieldRules {
		out.WriteString("  Alternatives cannot be summarized safely. Use the complete input schema.\n")
	} else if len(arguments) == 0 {
		out.WriteString("  None. Omit the JSON object or pass {}.\n")
	} else {
		for _, argument := range arguments {
			status := "optional"
			if argument.Required {
				status = "required"
			}
			fmt.Fprintf(&out, "\n  %s  %s · %s", terminalSafeText(argument.Name), terminalSafeText(argument.Type), status)
			if argument.Default != "" {
				fmt.Fprintf(&out, " · default %s", terminalSafeLine(argument.Default))
			}
			out.WriteByte('\n')
			if argument.Description != "" {
				out.WriteString("    ")
				out.WriteString(terminalSafeLine(argument.Description))
				out.WriteByte('\n')
			}
			if argument.Constraints != "" {
				out.WriteString("    ")
				out.WriteString(terminalSafeLine("Constraints: " + argument.Constraints))
				out.WriteByte('\n')
			}
		}
	}
	out.WriteString("\nPass one JSON object inline, or '-' to read it from stdin.\n")
	fmt.Fprintf(&out, "Complete input schema: emisar-mcp help %s --json\n", shellQuote(safeName))
	out.WriteString("Emisar still enforces scope, policy, approvals, signing, and audit.\n")
	return out.String(), nil
}

func cliToolInvocation(name string) string {
	return cliToolInvocationForOS(name, "", runtime.GOOS)
}

func cliToolInvocationForOS(name, account, goos string) string {
	safeName := shellQuoteForOS(terminalSafeText(name), goos)
	prefix := "emisar-mcp "
	if account != "" {
		prefix += "--account " + shellQuoteForOS(terminalSafeText(account), goos) + " "
	}
	if name == "accounts" || name == "auth" || name == "help" ||
		name == "list_tools" || strings.HasPrefix(name, "-") {
		prefix += "-- "
	}
	return prefix + safeName
}

type cliArgument struct {
	Name        string
	Type        string
	Required    bool
	Default     string
	Description string
	Constraints string
}

func describeTopLevelArguments(schema map[string]any) ([]cliArgument, bool, bool) {
	properties := make(map[string]any)
	required := make(map[string]bool)
	if !collectTopLevelSchema(schema, schema, properties, required, map[string]bool{}, 0) {
		return nil, false, false
	}
	crossFieldRules, ok := hasCrossFieldRules(schema, schema, map[string]bool{}, 0)
	if !ok {
		return nil, false, false
	}
	names := make([]string, 0, len(properties))
	for name := range properties {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		if required[names[i]] != required[names[j]] {
			return required[names[i]]
		}
		return names[i] < names[j]
	})

	arguments := make([]cliArgument, 0, len(names))
	for _, name := range names {
		property, ok := properties[name].(map[string]any)
		if !ok {
			return nil, false, false
		}
		resolved, ok := resolveSchema(property, schema, map[string]bool{}, 0)
		if !ok {
			return nil, false, false
		}
		argumentType, ok := schemaType(resolved, schema, 0)
		if !ok {
			return nil, false, false
		}
		constraints, ok := schemaConstraints(resolved, schema, 0)
		if !ok {
			return nil, false, false
		}
		arguments = append(arguments, cliArgument{
			Name:        name,
			Type:        argumentType,
			Required:    required[name],
			Default:     schemaJSONValue(resolved["default"]),
			Description: stringValue(resolved["description"]),
			Constraints: constraints,
		})
	}
	return arguments, crossFieldRules, true
}

func collectTopLevelSchema(
	schema, root map[string]any,
	properties map[string]any,
	required map[string]bool,
	seen map[string]bool,
	depth int,
) bool {
	if depth > maxCLISchemaRenderDepth {
		return false
	}
	if ref, ok := schema["$ref"].(string); ok {
		if seen[ref] {
			return false
		}
		target, ok := resolveReference(ref, root)
		if !ok {
			return false
		}
		seen[ref] = true
		defer delete(seen, ref)
		if !collectTopLevelSchema(target, root, properties, required, seen, depth+1) {
			return false
		}
	}
	if direct, ok := schema["properties"].(map[string]any); ok {
		for name, property := range direct {
			properties[name] = property
		}
	}
	if values, ok := schema["required"].([]any); ok {
		for _, value := range values {
			if name, ok := value.(string); ok {
				required[name] = true
			}
		}
	}
	if allOf, ok := schema["allOf"].([]any); ok {
		for _, item := range allOf {
			child, ok := item.(map[string]any)
			if !ok || !collectTopLevelSchema(child, root, properties, required, seen, depth+1) {
				return false
			}
		}
	}
	return true
}

func hasCrossFieldRules(schema, root map[string]any, seen map[string]bool, depth int) (bool, bool) {
	if depth > maxCLISchemaRenderDepth {
		return false, false
	}
	for _, keyword := range []string{
		"oneOf", "anyOf", "not", "if", "then", "else", "dependentRequired", "dependentSchemas",
	} {
		if _, present := schema[keyword]; present {
			return true, true
		}
	}
	if ref, ok := schema["$ref"].(string); ok {
		if seen[ref] {
			return false, false
		}
		target, ok := resolveReference(ref, root)
		if !ok {
			return false, false
		}
		seen[ref] = true
		found, ok := hasCrossFieldRules(target, root, seen, depth+1)
		delete(seen, ref)
		if !ok || found {
			return found, ok
		}
	}
	if allOf, ok := schema["allOf"].([]any); ok {
		for _, item := range allOf {
			child, ok := item.(map[string]any)
			if !ok {
				return false, false
			}
			found, ok := hasCrossFieldRules(child, root, seen, depth+1)
			if !ok || found {
				return found, ok
			}
		}
	}
	return false, true
}

func resolveSchema(schema, root map[string]any, seen map[string]bool, depth int) (map[string]any, bool) {
	if depth > maxCLISchemaRenderDepth {
		return nil, false
	}
	resolved := make(map[string]any, len(schema))
	if ref, ok := schema["$ref"].(string); ok {
		if seen[ref] {
			return nil, false
		}
		target, ok := resolveReference(ref, root)
		if !ok {
			return nil, false
		}
		seen[ref] = true
		target, ok = resolveSchema(target, root, seen, depth+1)
		delete(seen, ref)
		if !ok {
			return nil, false
		}
		for key, value := range target {
			resolved[key] = value
		}
	}
	for key, value := range schema {
		if key != "$ref" {
			resolved[key] = value
		}
	}
	return resolved, true
}

func resolveReference(ref string, root map[string]any) (map[string]any, bool) {
	const prefix = "#/$defs/"
	if !strings.HasPrefix(ref, prefix) {
		return nil, false
	}
	definitions, ok := root["$defs"].(map[string]any)
	if !ok {
		return nil, false
	}
	definition, ok := definitions[strings.TrimPrefix(ref, prefix)].(map[string]any)
	if !ok {
		return nil, false
	}
	return definition, true
}

func schemaType(schema, root map[string]any, depth int) (string, bool) {
	if depth > maxCLISchemaRenderDepth {
		return "", false
	}
	if value := typeValue(schema["type"]); value != "" {
		if value == "array" {
			if items, ok := schema["items"].(map[string]any); ok {
				resolved, ok := resolveSchema(items, root, map[string]bool{}, depth+1)
				if !ok {
					return "", false
				}
				itemType, ok := schemaType(resolved, root, depth+1)
				if !ok {
					return "", false
				}
				return "array<" + itemType + ">", true
			}
		}
		return value, true
	}
	for _, keyword := range []string{"oneOf", "anyOf"} {
		variants, ok := schema[keyword].([]any)
		if !ok {
			continue
		}
		var types []string
		for _, variant := range variants {
			child, ok := variant.(map[string]any)
			if !ok {
				return "", false
			}
			resolved, ok := resolveSchema(child, root, map[string]bool{}, depth+1)
			if !ok {
				return "", false
			}
			variantType, ok := schemaType(resolved, root, depth+1)
			if !ok {
				return "", false
			}
			types = appendUnique(types, variantType)
		}
		if len(types) > 0 {
			return strings.Join(types, " | "), true
		}
	}
	return "JSON", true
}

func typeValue(value any) string {
	switch value := value.(type) {
	case string:
		return value
	case []any:
		var values []string
		for _, item := range value {
			if name, ok := item.(string); ok {
				values = appendUnique(values, name)
			}
		}
		return strings.Join(values, " | ")
	default:
		return ""
	}
}

func schemaConstraints(schema, root map[string]any, depth int) (string, bool) {
	if depth > maxCLISchemaRenderDepth {
		return "", false
	}
	var constraints []string
	if enum, ok := schema["enum"].([]any); ok {
		values := make([]string, 0, len(enum))
		for _, value := range enum {
			values = append(values, schemaJSONValue(value))
		}
		constraints = append(constraints, "one of "+strings.Join(values, ", "))
	}
	constraints = appendRange(constraints, schema, "minimum", "maximum", "value")
	constraints = appendRange(constraints, schema, "minLength", "maxLength", "characters")
	constraints = appendRange(constraints, schema, "minItems", "maxItems", "items")
	if pattern := stringValue(schema["pattern"]); pattern != "" {
		constraints = append(constraints, "pattern "+pattern)
	}
	if items, ok := schema["items"].(map[string]any); ok {
		resolved, ok := resolveSchema(items, root, map[string]bool{}, depth+1)
		if !ok {
			return "", false
		}
		itemConstraints, ok := schemaConstraints(resolved, root, depth+1)
		if !ok {
			return "", false
		}
		if itemConstraints != "" {
			constraints = append(constraints, "each item: "+itemConstraints)
		}
	}
	return strings.Join(constraints, "; "), true
}

func appendRange(constraints []string, schema map[string]any, minimum, maximum, unit string) []string {
	min, hasMin := schema[minimum]
	max, hasMax := schema[maximum]
	switch {
	case hasMin && hasMax:
		return append(constraints, fmt.Sprintf("%s %s–%s", unit, schemaJSONValue(min), schemaJSONValue(max)))
	case hasMin:
		return append(constraints, fmt.Sprintf("%s at least %s", unit, schemaJSONValue(min)))
	case hasMax:
		return append(constraints, fmt.Sprintf("%s at most %s", unit, schemaJSONValue(max)))
	default:
		return constraints
	}
}

func schemaJSONValue(value any) string {
	if value == nil {
		return ""
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return ""
	}
	return string(encoded)
}

func stringValue(value any) string {
	text, _ := value.(string)
	return text
}

func appendUnique(values []string, value string) []string {
	if value == "" {
		return values
	}
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}

func descriptorKind(annotations cliAnnotations) string {
	switch {
	case annotations.Destructive:
		return "destructive"
	case annotations.ReadOnly:
		return "read-only"
	default:
		return "writes data"
	}
}

func terminalSafeText(value string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Bidi_Control, r) || r == '\u2028' || r == '\u2029' {
			return ' '
		}
		return r
	}, value)
}

func terminalSafeLine(value string) string {
	return strings.Join(strings.Fields(terminalSafeText(value)), " ")
}

func shellQuote(value string) string {
	return shellQuoteForOS(value, runtime.GOOS)
}

func shellQuoteForOS(value, goos string) string {
	if value == "" {
		return "''"
	}
	bare := strings.IndexFunc(value, func(r rune) bool {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			return false
		case r == '-' || r == '_' || r == '.' || r == '/' || r == ':' ||
			r == '=' || r == '@' || r == ',' || r == '+':
			return false
		default:
			return true
		}
	}) == -1
	if bare {
		return value
	}
	if goos == "windows" {
		return "'" + strings.ReplaceAll(value, "'", "''") + "'"
	}
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}
