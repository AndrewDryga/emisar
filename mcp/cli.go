package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"unicode"
)

const cliProtocolVersion = "2026-07-28"

const maxCLISchemaRenderDepth = 32

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
		if len(args) < 2 || len(args) > 3 {
			return errors.New("usage: emisar-mcp -- <tool> [JSON | -]")
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
		if len(args) > 2 {
			return errors.New("usage: emisar-mcp <tool> [JSON | -]")
		}
		if len(args) == 2 && strings.HasPrefix(args[1], "--") && args[1] != "--help" {
			return fmt.Errorf("unknown option %q; usage: emisar-mcp <tool> [JSON | -]", args[1])
		}
	}
	return nil
}

func (b *bridge) runCLI(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if err := validateCLIInvocation(args); err != nil {
		return cliUsageError(stderr, err.Error())
	}
	command := args[0]
	switch command {
	case "--":
		arguments, err := readCLIArguments(args[2:], stdin)
		if err != nil {
			return cliUsageError(stderr, err.Error())
		}
		return b.runToolCall(args[1], arguments, stdout, stderr)

	case "list_tools":
		return b.runListTools(len(args) == 2, stdout, stderr)

	case "help":
		return b.runToolHelp(args[1], len(args) == 3, stdout, stderr)

	default:
		if len(args) == 2 && (args[1] == "-h" || args[1] == "--help") {
			return b.runToolHelp(command, false, stdout, stderr)
		}
		arguments, err := readCLIArguments(args[1:], stdin)
		if err != nil {
			return cliUsageError(stderr, err.Error())
		}
		return b.runToolCall(command, arguments, stdout, stderr)
	}
}

func (b *bridge) runListTools(exactJSON bool, stdout, stderr io.Writer) int {
	tools, descriptors, code := b.fetchToolDescriptors(stdout, stderr)
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
	_, descriptors, code := b.fetchToolDescriptors(stdout, stderr)
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
	return cliUsageError(stderr, fmt.Sprintf("unknown MCP tool %q; run 'emisar-mcp list_tools'", name))
}

func (b *bridge) runToolCall(name string, arguments json.RawMessage, stdout, stderr io.Writer) int {
	response, operationID, err := b.cliRoundTrip("tools/call", name, arguments)
	if err != nil {
		return b.writeCLICallFailure(operationID, err, stdout, stderr)
	}
	if len(response.Error) > 0 {
		if err := writePrettyJSON(stdout, response.Error); err != nil {
			return cliFailure(stderr, "write MCP error", err)
		}
		return 1
	}

	var result struct {
		StructuredContent json.RawMessage `json:"structuredContent"`
		IsError           bool            `json:"isError"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil {
		return b.writeCLICallResponseFailure(operationID, "decode tool result", err, stdout, stderr)
	}
	if len(result.StructuredContent) == 0 || firstJSONByte(result.StructuredContent) != '{' {
		return b.writeCLICallResponseFailure(
			operationID,
			"decode tool result",
			errors.New("control plane returned no structuredContent object"),
			stdout,
			stderr,
		)
	}
	if err := writePrettyJSON(stdout, result.StructuredContent); err != nil {
		return cliFailure(stderr, "write tool result", err)
	}
	if result.IsError {
		return 1
	}
	return 0
}

func (b *bridge) fetchToolDescriptors(stdout, stderr io.Writer) (json.RawMessage, []json.RawMessage, int) {
	response, _, err := b.cliRoundTrip("tools/list", "", nil)
	if err != nil {
		return nil, nil, cliFailure(stderr, "list tools", err)
	}
	if len(response.Error) > 0 {
		if err := writePrettyJSON(stdout, response.Error); err != nil {
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
	frame, err := buildCLIFrame(method, name, arguments)
	if err != nil {
		return cliRPCResponse{}, "", localBridge(err)
	}
	if len(frame) > maxFrameBytes {
		return cliRPCResponse{}, "", localBridge(fmt.Errorf("request frame exceeds %d bytes", maxFrameBytes))
	}
	meta := parseRequestMeta(frame)
	requestToken := b.requestToken(1)
	operationID := toolCallOperationID(meta, requestToken)
	body, err := b.forwardRequestContext(context.Background(), frame, meta, requestHeaders{
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

func readCLIArguments(args []string, stdin io.Reader) (json.RawMessage, error) {
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

func cliUsageError(stderr io.Writer, message string) int {
	fmt.Fprintf(stderr, "%s: %s\n", bridgeName, terminalSafeText(message))
	return 2
}

func cliFailure(stderr io.Writer, action string, err error) int {
	fmt.Fprintf(stderr, "%s: %s: %s\n", bridgeName, terminalSafeText(action), terminalSafeText(err.Error()))
	return 1
}

func (b *bridge) writeCLICallFailure(operationID string, callErr error, stdout, stderr io.Writer) int {
	message := "upstream transport error"
	if bridgeProducedError(callErr) {
		message = "emisar bridge could not send this request"
		operationID = ""
	}
	if localTransportError(callErr) || bridgeProducedError(callErr) {
		b.diagnose("%v", callErr)
	}
	return writeCLICallError(message, operationID, stdout, stderr)
}

func (b *bridge) writeCLICallResponseFailure(
	operationID, action string,
	responseErr error,
	stdout, stderr io.Writer,
) int {
	b.diagnose("%s: %v", action, responseErr)
	return writeCLICallError("invalid upstream tool response", operationID, stdout, stderr)
}

func writeCLICallError(message, operationID string, stdout, stderr io.Writer) int {
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
	if err := writePrettyJSON(stdout, raw); err != nil {
		return cliFailure(stderr, "write transport error", err)
	}
	return 1
}

func renderToolList(rawDescriptors []json.RawMessage) (string, error) {
	var out strings.Builder
	fmt.Fprintf(&out, "%d MCP tools\n", len(rawDescriptors))
	for _, raw := range rawDescriptors {
		var descriptor cliToolDescriptor
		if err := json.Unmarshal(raw, &descriptor); err != nil {
			return "", fmt.Errorf("decode tool descriptor: %w", err)
		}
		if descriptor.Name == "" {
			return "", errors.New("decode tool descriptor: name is empty")
		}
		fmt.Fprintf(&out, "\n  %s  [%s]\n", terminalSafeText(descriptor.Name), descriptorKind(descriptor.Annotations))
		out.WriteString(wrapCLIText(descriptor.Description, "    ", 80))
		out.WriteByte('\n')
	}
	out.WriteString("\nUse 'emisar-mcp help <tool>' for arguments and the input schema.\n")
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
	out.WriteString(wrapCLIText(descriptor.Description, "", 80))
	fmt.Fprintf(&out, "\n\nUSAGE\n  %s [JSON | -]\n", cliToolInvocation(descriptor.Name))

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
				fmt.Fprintf(&out, " · default %s", argument.Default)
			}
			out.WriteByte('\n')
			if argument.Description != "" {
				out.WriteString(wrapCLIText(argument.Description, "    ", 80))
				out.WriteByte('\n')
			}
			if argument.Constraints != "" {
				out.WriteString(wrapCLIText("Constraints: "+argument.Constraints, "    ", 80))
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
	safeName := shellQuote(terminalSafeText(name))
	if name == "auth" || name == "help" || name == "list_tools" || strings.HasPrefix(name, "-") {
		return "emisar-mcp -- " + safeName
	}
	return "emisar-mcp " + safeName
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

func wrapCLIText(text, indent string, width int) string {
	words := strings.Fields(terminalSafeText(text))
	if len(words) == 0 {
		return indent
	}
	var out strings.Builder
	lineLength := len(indent)
	out.WriteString(indent)
	for _, word := range words {
		if lineLength > len(indent) && lineLength+1+len(word) > width {
			out.WriteByte('\n')
			out.WriteString(indent)
			out.WriteString(word)
			lineLength = len(indent) + len(word)
			continue
		}
		if lineLength > len(indent) {
			out.WriteByte(' ')
			lineLength++
		}
		out.WriteString(word)
		lineLength += len(word)
	}
	return out.String()
}

func terminalSafeText(value string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Bidi_Control, r) {
			return ' '
		}
		return r
	}, value)
}

func shellQuote(value string) string {
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
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}
