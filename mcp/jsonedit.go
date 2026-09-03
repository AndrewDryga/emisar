package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// An LLM client's configuration file belongs to the operator, not to us. VS
// Code and Zed ship commented JSONC, and every one of these files carries
// settings we must not disturb. So each edit here is TEXTUAL — locate the exact
// byte span of a member and splice — never parse-and-reserialize, which would
// drop the operator's comments and reorder every key in the document.
//
// A key is matched by its raw quoted spelling, so a container written with
// escapes (`"mcpServers"`) reads as absent and the edit adds a second
// container. Both spellings are legal JSON that no client emits; the textual
// match is what keeps the rest of the file byte-identical.

const maxJSONConfigBytes = 8 << 20

type jsonMemberSpan struct {
	keyStart   int
	valueStart int
	valueEnd   int
}

// skipJSONSpace advances past whitespace and JSONC comments.
func skipJSONSpace(raw string, index int) int {
	for index < len(raw) {
		switch {
		case raw[index] == ' ', raw[index] == '\t', raw[index] == '\r', raw[index] == '\n':
			index++
		case strings.HasPrefix(raw[index:], "//"):
			for index < len(raw) && raw[index] != '\n' {
				index++
			}
		case strings.HasPrefix(raw[index:], "/*"):
			end := strings.Index(raw[index+2:], "*/")
			if end < 0 {
				return len(raw)
			}
			index += 2 + end + 2
		default:
			return index
		}
	}
	return index
}

// jsonStringEnd returns the index just past the string literal starting at index.
func jsonStringEnd(raw string, index int) int {
	index++
	for index < len(raw) {
		switch raw[index] {
		case '\\':
			index += 2
		case '"':
			return index + 1
		default:
			index++
		}
	}
	return -1
}

func jsonCloseIndex(raw string, index int, open, closing byte) int {
	depth := 0
	for index < len(raw) {
		current := raw[index]
		if current == '"' {
			end := jsonStringEnd(raw, index)
			if end < 0 {
				return -1
			}
			index = end
			continue
		}
		if current == '/' && index+1 < len(raw) && (raw[index+1] == '/' || raw[index+1] == '*') {
			next := skipJSONSpace(raw, index)
			if next <= index {
				return -1
			}
			index = next
			continue
		}
		switch current {
		case open:
			depth++
		case closing:
			depth--
			if depth == 0 {
				return index
			}
		}
		index++
	}
	return -1
}

func skipJSONValue(raw string, index int) int {
	index = skipJSONSpace(raw, index)
	if index >= len(raw) {
		return index
	}
	switch raw[index] {
	case '"':
		return jsonStringEnd(raw, index)
	case '{':
		end := jsonCloseIndex(raw, index, '{', '}')
		if end < 0 {
			return -1
		}
		return end + 1
	case '[':
		end := jsonCloseIndex(raw, index, '[', ']')
		if end < 0 {
			return -1
		}
		return end + 1
	}
	for index < len(raw) && raw[index] != ',' && raw[index] != '}' && raw[index] != ']' {
		index++
	}
	return index
}

func jsonRootBrace(raw string) (int, error) {
	root := skipJSONSpace(raw, 0)
	if root >= len(raw) || raw[root] != '{' {
		return 0, errors.New("top-level JSON is not an object")
	}
	return root, nil
}

// findJSONMember locates one member of the object whose opening brace is at
// objectBrace.
func findJSONMember(raw string, objectBrace int, name string) (jsonMemberSpan, bool, error) {
	end := jsonCloseIndex(raw, objectBrace, '{', '}')
	if end < 0 {
		return jsonMemberSpan{}, false, errors.New("unterminated JSON object")
	}
	target := `"` + name + `"`
	index := objectBrace + 1
	for index < end {
		current := raw[index]
		if current == ' ' || current == '\t' || current == '\r' || current == '\n' || current == ',' {
			index++
			continue
		}
		if current == '/' && index+1 < len(raw) && (raw[index+1] == '/' || raw[index+1] == '*') {
			next := skipJSONSpace(raw, index)
			if next <= index {
				return jsonMemberSpan{}, false, errors.New("unterminated JSON comment")
			}
			index = next
			continue
		}
		if current != '"' {
			return jsonMemberSpan{}, false, fmt.Errorf("unexpected %q in JSON object", string(current))
		}
		keyEnd := jsonStringEnd(raw, index)
		if keyEnd < 0 {
			return jsonMemberSpan{}, false, errors.New("unterminated JSON string")
		}
		key := raw[index:keyEnd]
		colon := skipJSONSpace(raw, keyEnd)
		if colon >= end || raw[colon] != ':' {
			return jsonMemberSpan{}, false, errors.New("malformed JSON member")
		}
		valueStart := skipJSONSpace(raw, colon+1)
		valueEnd := skipJSONValue(raw, valueStart)
		if valueEnd < 0 || valueEnd > end {
			return jsonMemberSpan{}, false, errors.New("malformed JSON value")
		}
		if key == target {
			return jsonMemberSpan{keyStart: index, valueStart: valueStart, valueEnd: valueEnd}, true, nil
		}
		index = valueEnd
	}
	return jsonMemberSpan{}, false, nil
}

// resolveJSONContainer walks path from the root object and reports the brace of
// the deepest object that exists plus how much of the path it covers.
func resolveJSONContainer(raw string, path []string) (brace, depth int, err error) {
	brace, err = jsonRootBrace(raw)
	if err != nil {
		return 0, 0, err
	}
	for depth < len(path) {
		span, found, err := findJSONMember(raw, brace, path[depth])
		if err != nil {
			return 0, 0, err
		}
		if !found {
			return brace, depth, nil
		}
		if raw[span.valueStart] != '{' {
			return 0, 0, fmt.Errorf("existing config key is not an object: %s", path[depth])
		}
		brace = span.valueStart
		depth++
	}
	return brace, depth, nil
}

// jsonBraceIndent returns the leading whitespace of the line holding brace, so
// a member inserted into that object lines up one level deeper and its closing
// brace lines up with the opening one.
func jsonBraceIndent(raw string, brace int) string {
	lineStart := strings.LastIndexByte(raw[:brace], '\n') + 1
	base := raw[lineStart:brace]
	trimmed := strings.TrimLeft(base, " \t")
	return base[:len(base)-len(trimmed)]
}

func jsonMemberIndent(raw string, brace int) string {
	return jsonBraceIndent(raw, brace) + "  "
}

// marshalJSONIndent renders value with every line after the first prefixed, so
// a nested object lands correctly at the insertion column.
func marshalJSONIndent(value any, prefix string) (string, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent(prefix, "  ")
	if err := encoder.Encode(value); err != nil {
		return "", err
	}
	return strings.TrimRight(buffer.String(), "\n"), nil
}

func renderJSONMember(name string, value any, indent string) (string, error) {
	encoded, err := marshalJSONIndent(value, indent)
	if err != nil {
		return "", err
	}
	return `"` + name + `": ` + encoded, nil
}

// insertJSONMember adds name → value under path, creating any missing
// containers, and returns the edited document. An existing member is replaced.
func insertJSONMember(raw string, path []string, name string, value any) (string, error) {
	if strings.TrimSpace(raw) == "" {
		raw = "{}\n"
	}
	brace, depth, err := resolveJSONContainer(raw, path)
	if err != nil {
		return "", err
	}
	if depth == len(path) {
		if span, found, err := findJSONMember(raw, brace, name); err != nil {
			return "", err
		} else if found {
			encoded, err := marshalJSONIndent(value, jsonMemberIndent(raw, brace))
			if err != nil {
				return "", err
			}
			return raw[:span.valueStart] + encoded + raw[span.valueEnd:], nil
		}
	}

	// Every container below the deepest existing one is created here, and each
	// has exactly one member, so a single-key map renders unambiguously.
	nested := any(value)
	if depth < len(path) {
		nested = map[string]any{name: value}
		for level := len(path) - 1; level > depth; level-- {
			nested = map[string]any{path[level]: nested}
		}
		name = path[depth]
	}

	indent := jsonMemberIndent(raw, brace)
	member, err := renderJSONMember(name, nested, indent)
	if err != nil {
		return "", err
	}
	// An empty object closes on the same line it opened, so the insert has to
	// put its `}` on a line of its own; otherwise the existing members already
	// supply the newline and only a separator comma is needed.
	next := skipJSONSpace(raw, brace+1)
	block := "\n" + indent + member
	if next < len(raw) && raw[next] == '}' {
		block += "\n" + jsonBraceIndent(raw, brace)
	} else {
		block += ","
	}
	return raw[:brace+1] + block + raw[brace+1:], nil
}

// removeJSONMember cuts name from path, along with the separator comma that
// would otherwise dangle. It reports whether anything was removed.
func removeJSONMember(raw string, path []string, name string) (string, bool, error) {
	brace, depth, err := resolveJSONContainer(raw, path)
	if err != nil {
		return "", false, err
	}
	if depth != len(path) {
		return raw, false, nil
	}
	span, found, err := findJSONMember(raw, brace, name)
	if err != nil {
		return "", false, err
	}
	if !found {
		return raw, false, nil
	}
	start, end := span.keyStart, span.valueEnd
	// Only whitespace is crossed looking for the separator: a comment between a
	// value and its comma would otherwise be swallowed into the cut.
	if comma, ok := nextJSONByte(raw, end, ','); ok {
		end = comma + 1
		start = trimJSONLineStart(raw, start)
	} else if comma, ok := previousJSONByte(raw, start, ','); ok {
		start = comma
	} else {
		start = trimJSONLineStart(raw, start)
	}
	return raw[:start] + raw[end:], true, nil
}

func nextJSONByte(raw string, index int, want byte) (int, bool) {
	for index < len(raw) {
		switch raw[index] {
		case ' ', '\t', '\r', '\n':
			index++
		case want:
			return index, true
		default:
			return 0, false
		}
	}
	return 0, false
}

func previousJSONByte(raw string, index int, want byte) (int, bool) {
	for index > 0 {
		switch raw[index-1] {
		case ' ', '\t', '\r', '\n':
			index--
		case want:
			return index - 1, true
		default:
			return 0, false
		}
	}
	return 0, false
}

func trimJSONLineStart(raw string, index int) int {
	for index > 0 && (raw[index-1] == ' ' || raw[index-1] == '\t') {
		index--
	}
	if index > 0 && raw[index-1] == '\n' {
		index--
		if index > 0 && raw[index-1] == '\r' {
			index--
		}
	}
	return index
}

// stripJSONC rewrites a JSONC document as plain JSON so it can be validated
// with encoding/json.
func stripJSONC(raw string) string {
	var out strings.Builder
	out.Grow(len(raw))
	index := 0
	for index < len(raw) {
		current := raw[index]
		if current == '"' {
			end := jsonStringEnd(raw, index)
			if end < 0 {
				out.WriteString(raw[index:])
				break
			}
			out.WriteString(raw[index:end])
			index = end
			continue
		}
		if current == '/' && index+1 < len(raw) && (raw[index+1] == '/' || raw[index+1] == '*') {
			next := skipJSONSpace(raw, index)
			if next <= index {
				break
			}
			out.WriteByte(' ')
			index = next
			continue
		}
		out.WriteByte(current)
		index++
	}
	return dropTrailingCommas(out.String())
}

func dropTrailingCommas(raw string) string {
	var out strings.Builder
	out.Grow(len(raw))
	index := 0
	for index < len(raw) {
		current := raw[index]
		if current == '"' {
			end := jsonStringEnd(raw, index)
			if end < 0 {
				out.WriteString(raw[index:])
				break
			}
			out.WriteString(raw[index:end])
			index = end
			continue
		}
		if current == ',' {
			if next := skipJSONSpace(raw, index+1); next < len(raw) && (raw[next] == '}' || raw[next] == ']') {
				index++
				continue
			}
		}
		out.WriteByte(current)
		index++
	}
	return out.String()
}

// parseJSONConfig decodes a document that may be JSONC, for validation only.
// The strip is unconditional: VS Code and Cursor accept a trailing comma in a
// file with no comments in it at all, so gating it on a `//` made the bridge
// refuse to edit a config its own client loads without complaint.
func parseJSONConfig(raw string) (map[string]any, error) {
	if strings.TrimSpace(raw) == "" {
		return map[string]any{}, nil
	}
	text := stripJSONC(raw)
	var document map[string]any
	if err := json.Unmarshal([]byte(text), &document); err != nil {
		return nil, err
	}
	if document == nil {
		return nil, errors.New("top-level JSON is not an object")
	}
	return document, nil
}

// lookupJSONPath returns the value at path + name in a decoded document.
func lookupJSONPath(document map[string]any, path []string, name string) (any, bool) {
	node := document
	for _, key := range path {
		child, ok := node[key].(map[string]any)
		if !ok {
			return nil, false
		}
		node = child
	}
	value, ok := node[name]
	return value, ok
}

// sameJSONValue compares a decoded value against the value we meant to write.
func sameJSONValue(actual, expected any) bool {
	actualBytes, err := json.Marshal(actual)
	if err != nil {
		return false
	}
	encoded, err := json.Marshal(expected)
	if err != nil {
		return false
	}
	var normalized any
	if err := json.Unmarshal(encoded, &normalized); err != nil {
		return false
	}
	expectedBytes, err := json.Marshal(normalized)
	if err != nil {
		return false
	}
	return bytes.Equal(actualBytes, expectedBytes)
}
