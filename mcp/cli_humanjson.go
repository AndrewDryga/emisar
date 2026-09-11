package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// The human renderer for `--json`-less CLI output: one general-purpose walk
// over a decoded JSON value, printing records and fields an operator reads in
// a terminal. Split out of cli.go, which had accreted three unrelated
// concerns; this one knows nothing about the bridge, the transport, or the
// tool being called.

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
		width = max(width, len([]rune(field.label)))
	}
	width = min(width, maxCLIHumanFieldAlignmentRunes)
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
			head := runes[:limit]
			short := string(head)
			// Break at the last whitespace in the kept text, but only past the
			// halfway point. Compare RUNE positions: strings.LastIndexFunc
			// returns a byte offset, so on multibyte text (e.g. CJK) it clears
			// the limit/2 rune threshold far too early and discards most of the
			// budget.
			lastSpace := -1
			for index, char := range head {
				if unicode.IsSpace(char) {
					lastSpace = index
				}
			}
			if lastSpace >= limit/2 {
				short = strings.TrimSpace(string(head[:lastSpace]))
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
