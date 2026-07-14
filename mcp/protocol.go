package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"unicode/utf8"

	"github.com/andrewdryga/emisar/mcp/internal/attest"
)

const (
	maxRawActionArgsBytes = 32 << 10
	maxJSONNestingDepth   = 64
)

// parsedProtocolFrame retains the exact JSON value bytes needed by the bridge's
// action-signing path. Surrounding delimiter whitespace is not part of a JSON
// value; whitespace, escapes, object order, and number spelling inside each
// captured value are preserved byte for byte.
type parsedProtocolFrame struct {
	Method     string
	Params     json.RawMessage
	ToolName   string
	Arguments  json.RawMessage
	ActionArgs json.RawMessage
}

// parseProtocolJSON validates one strict JSON protocol object and extracts the
// raw values action signing needs. serve applies the same strict
// parser to every frame before this semantic extraction is used.
func parseProtocolJSON(frame []byte) (parsedProtocolFrame, error) {
	if err := validateStrictJSON(frame); err != nil {
		return parsedProtocolFrame{}, err
	}

	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(frame, &envelope); err != nil {
		return parsedProtocolFrame{}, fmt.Errorf("decode protocol object: %w", err)
	}
	if firstJSONByte(frame) != '{' {
		return parsedProtocolFrame{}, errors.New("protocol frame must be a JSON object")
	}

	method, err := exactJSONString(envelope, "method")
	if err != nil {
		return parsedProtocolFrame{}, fmt.Errorf("decode protocol method: %w", err)
	}
	parsed := parsedProtocolFrame{Method: method, Params: envelope["params"]}
	if method != "tools/call" {
		return parsed, nil
	}
	if firstJSONByte(parsed.Params) != '{' {
		return parsedProtocolFrame{}, errors.New("tools/call params must be a JSON object")
	}

	var params map[string]json.RawMessage
	if err := json.Unmarshal(parsed.Params, &params); err != nil {
		return parsedProtocolFrame{}, fmt.Errorf("decode tools/call params: %w", err)
	}
	name, err := exactJSONString(params, "name")
	if err != nil || name == "" {
		return parsedProtocolFrame{}, errors.New("tools/call params.name must be a nonempty string")
	}
	parsed.ToolName = name
	parsed.Arguments = params["arguments"]
	if name != attest.Tool {
		return parsed, nil
	}
	if firstJSONByte(parsed.Arguments) != '{' {
		return parsedProtocolFrame{}, errors.New("run_action params.arguments must be a JSON object")
	}

	args, err := extractRawActionArgs(parsed.Arguments, "run_action args")
	if err != nil {
		return parsedProtocolFrame{}, err
	}
	parsed.ActionArgs = args

	return parsed, nil
}

func extractRawActionArgs(arguments json.RawMessage, label string) (json.RawMessage, error) {
	var input map[string]json.RawMessage
	if err := json.Unmarshal(arguments, &input); err != nil {
		return nil, fmt.Errorf("decode %s: %w", label, err)
	}
	args := input["args"]
	if len(args) == 0 {
		return nil, fmt.Errorf("%s are required", label)
	}
	if firstJSONByte(args) != '{' {
		return nil, fmt.Errorf("%s must be a JSON object", label)
	}
	if len(args) > maxRawActionArgsBytes {
		return nil, fmt.Errorf("%s are %d bytes, limit is %d", label, len(args), maxRawActionArgsBytes)
	}
	return args, nil
}

func exactJSONString(fields map[string]json.RawMessage, key string) (string, error) {
	raw, ok := fields[key]
	if !ok {
		return "", fmt.Errorf("field %q is required", key)
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", fmt.Errorf("field %q must be a string", key)
	}
	return value, nil
}

func firstJSONByte(raw []byte) byte {
	for _, value := range raw {
		switch value {
		case ' ', '\t', '\r', '\n':
			continue
		default:
			return value
		}
	}
	return 0
}

func validateStrictJSON(data []byte) error {
	if !utf8.Valid(data) {
		return errors.New("protocol JSON is not valid UTF-8")
	}
	parser := strictJSONParser{data: data}
	parser.skipSpace()
	if parser.pos == len(data) {
		return errors.New("protocol JSON is empty")
	}
	if err := parser.parseValue(0); err != nil {
		return err
	}
	parser.skipSpace()
	if parser.pos != len(data) {
		return parser.errorf("trailing JSON value")
	}
	return nil
}

type strictJSONParser struct {
	data []byte
	pos  int
}

func (p *strictJSONParser) parseValue(depth int) error {
	if depth > maxJSONNestingDepth {
		return p.errorf("JSON nesting exceeds %d", maxJSONNestingDepth)
	}
	p.skipSpace()
	if p.pos == len(p.data) {
		return p.errorf("expected a JSON value")
	}

	switch p.data[p.pos] {
	case '{':
		return p.parseObject(depth + 1)
	case '[':
		return p.parseArray(depth + 1)
	case '"':
		_, err := p.parseString()
		return err
	case 't':
		return p.parseLiteral("true")
	case 'f':
		return p.parseLiteral("false")
	case 'n':
		return p.parseLiteral("null")
	default:
		return p.parseNumber()
	}
}

func (p *strictJSONParser) parseObject(depth int) error {
	p.pos++
	p.skipSpace()
	if p.consume('}') {
		return nil
	}

	seen := make(map[string]struct{})
	for {
		keyAt := p.pos
		key, err := p.parseString()
		if err != nil {
			return err
		}
		if _, duplicate := seen[key]; duplicate {
			return p.errorAtf(keyAt, "duplicate object key %q", key)
		}
		seen[key] = struct{}{}
		p.skipSpace()
		if !p.consume(':') {
			return p.errorf("expected ':' after object key")
		}
		if err := p.parseValue(depth); err != nil {
			return err
		}
		p.skipSpace()
		if p.consume('}') {
			return nil
		}
		if !p.consume(',') {
			return p.errorf("expected ',' or '}' in object")
		}
		p.skipSpace()
	}
}

func (p *strictJSONParser) parseArray(depth int) error {
	p.pos++
	p.skipSpace()
	if p.consume(']') {
		return nil
	}
	for {
		if err := p.parseValue(depth); err != nil {
			return err
		}
		p.skipSpace()
		if p.consume(']') {
			return nil
		}
		if !p.consume(',') {
			return p.errorf("expected ',' or ']' in array")
		}
		p.skipSpace()
	}
}

func (p *strictJSONParser) parseString() (string, error) {
	if !p.consume('"') {
		return "", p.errorf("expected a JSON string")
	}
	start := p.pos - 1
	for p.pos < len(p.data) {
		value := p.data[p.pos]
		switch {
		case value == '"':
			p.pos++
			var decoded string
			if err := json.Unmarshal(p.data[start:p.pos], &decoded); err != nil {
				return "", p.errorAtf(start, "invalid JSON string: %v", err)
			}
			return decoded, nil
		case value == '\\':
			if err := p.parseEscape(); err != nil {
				return "", err
			}
		case value < 0x20:
			return "", p.errorf("unescaped control character in JSON string")
		default:
			p.pos++
		}
	}
	return "", p.errorAtf(start, "unterminated JSON string")
}

func (p *strictJSONParser) parseEscape() error {
	escapeAt := p.pos
	p.pos++
	if p.pos == len(p.data) {
		return p.errorAtf(escapeAt, "unterminated JSON escape")
	}
	escape := p.data[p.pos]
	p.pos++
	switch escape {
	case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
		return nil
	}
	if escape != 'u' {
		return p.errorAtf(escapeAt, "invalid JSON escape %q", []byte{'\\', escape})
	}

	value, err := p.parseHexQuad()
	if err != nil {
		return err
	}
	if value >= 0xDC00 && value <= 0xDFFF {
		return p.errorAtf(escapeAt, "unpaired low surrogate in JSON string")
	}
	if value < 0xD800 || value > 0xDBFF {
		return nil
	}
	if p.pos+2 > len(p.data) || p.data[p.pos] != '\\' || p.data[p.pos+1] != 'u' {
		return p.errorAtf(escapeAt, "unpaired high surrogate in JSON string")
	}
	p.pos += 2
	low, err := p.parseHexQuad()
	if err != nil {
		return err
	}
	if low < 0xDC00 || low > 0xDFFF {
		return p.errorAtf(escapeAt, "high surrogate is not followed by a low surrogate")
	}
	return nil
}

func (p *strictJSONParser) parseHexQuad() (uint16, error) {
	if p.pos+4 > len(p.data) {
		return 0, p.errorf("short Unicode escape in JSON string")
	}
	value, err := strconv.ParseUint(string(p.data[p.pos:p.pos+4]), 16, 16)
	if err != nil {
		return 0, p.errorf("invalid Unicode escape in JSON string")
	}
	p.pos += 4
	return uint16(value), nil
}

func (p *strictJSONParser) parseLiteral(literal string) error {
	if len(p.data)-p.pos < len(literal) || string(p.data[p.pos:p.pos+len(literal)]) != literal {
		return p.errorf("invalid JSON value")
	}
	p.pos += len(literal)
	return nil
}

func (p *strictJSONParser) parseNumber() error {
	start := p.pos
	if p.consume('-') && p.pos == len(p.data) {
		return p.errorAtf(start, "invalid JSON number")
	}
	if p.consume('0') {
		if p.pos < len(p.data) && isDigit(p.data[p.pos]) {
			return p.errorAtf(start, "invalid JSON number with a leading zero")
		}
	} else {
		if p.pos == len(p.data) || p.data[p.pos] < '1' || p.data[p.pos] > '9' {
			return p.errorAtf(start, "invalid JSON value")
		}
		for p.pos < len(p.data) && isDigit(p.data[p.pos]) {
			p.pos++
		}
	}
	if p.consume('.') {
		if p.pos == len(p.data) || !isDigit(p.data[p.pos]) {
			return p.errorAtf(start, "invalid JSON number")
		}
		for p.pos < len(p.data) && isDigit(p.data[p.pos]) {
			p.pos++
		}
	}
	if p.pos < len(p.data) && (p.data[p.pos] == 'e' || p.data[p.pos] == 'E') {
		p.pos++
		if p.pos < len(p.data) && (p.data[p.pos] == '+' || p.data[p.pos] == '-') {
			p.pos++
		}
		if p.pos == len(p.data) || !isDigit(p.data[p.pos]) {
			return p.errorAtf(start, "invalid JSON number")
		}
		for p.pos < len(p.data) && isDigit(p.data[p.pos]) {
			p.pos++
		}
	}
	return nil
}

func isDigit(value byte) bool { return value >= '0' && value <= '9' }

func (p *strictJSONParser) skipSpace() {
	for p.pos < len(p.data) {
		switch p.data[p.pos] {
		case ' ', '\t', '\r', '\n':
			p.pos++
		default:
			return
		}
	}
}

func (p *strictJSONParser) consume(want byte) bool {
	if p.pos < len(p.data) && p.data[p.pos] == want {
		p.pos++
		return true
	}
	return false
}

func (p *strictJSONParser) errorf(format string, args ...any) error {
	return p.errorAtf(p.pos, format, args...)
}

func (p *strictJSONParser) errorAtf(offset int, format string, args ...any) error {
	return fmt.Errorf("protocol JSON at byte %d: %s", offset, fmt.Sprintf(format, args...))
}
