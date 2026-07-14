package main

import (
	"fmt"
	"strings"
	"testing"
)

func TestParseProtocolJSONCapturesExactActionValues(t *testing.T) {
	frame := []byte(`{
  "jsonrpc":"2.0",
  "id":7,
  "method":"tools/call",
  "params": { "name":"run_action", "arguments": { "action_id":"cockroach.pause_job", "args": { "job_id" : 9007199254740993, "ratio": 1.2300e+4 }, "reason":"maintenance", "runner_refs":["db~0123456789abcdef0123456789abcdef"] } }
}`)

	parsed, err := parseProtocolJSON(frame)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Method != "tools/call" || parsed.ToolName != "run_action" {
		t.Fatalf("method/tool = %q/%q", parsed.Method, parsed.ToolName)
	}
	if got, want := string(parsed.Params), `{ "name":"run_action", "arguments": { "action_id":"cockroach.pause_job", "args": { "job_id" : 9007199254740993, "ratio": 1.2300e+4 }, "reason":"maintenance", "runner_refs":["db~0123456789abcdef0123456789abcdef"] } }`; got != want {
		t.Errorf("params = %q, want exact %q", got, want)
	}
	if got, want := string(parsed.Arguments), `{ "action_id":"cockroach.pause_job", "args": { "job_id" : 9007199254740993, "ratio": 1.2300e+4 }, "reason":"maintenance", "runner_refs":["db~0123456789abcdef0123456789abcdef"] }`; got != want {
		t.Errorf("arguments = %q, want exact %q", got, want)
	}
	if got, want := string(parsed.ActionArgs), `{ "job_id" : 9007199254740993, "ratio": 1.2300e+4 }`; got != want {
		t.Errorf("action args = %q, want exact %q", got, want)
	}
}

func TestParseProtocolJSONUsesExactFieldNames(t *testing.T) {
	frame := []byte(`{"method":"tools/call","METHOD":"ping","params":{"name":"run_action","NAME":"get_action","arguments":{"args":{"safe":1},"ARGS":{"danger":2}}}}`)
	parsed, err := parseProtocolJSON(frame)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Method != "tools/call" || parsed.ToolName != "run_action" {
		t.Fatalf("case aliases changed routing to %q/%q", parsed.Method, parsed.ToolName)
	}
	if got, want := string(parsed.ActionArgs), `{"safe":1}`; got != want {
		t.Fatalf("case alias changed signed args to %s, want %s", got, want)
	}
}

func TestParseProtocolJSONRejectsUnsafeJSON(t *testing.T) {
	tests := []struct {
		name    string
		frame   []byte
		message string
	}{
		{
			name:    "duplicate root key",
			frame:   []byte(`{"method":"ping","method":"tools/list"}`),
			message: `duplicate object key "method"`,
		},
		{
			name:    "duplicate escaped key",
			frame:   []byte(`{"method":"tools/call","params":{"name":"run_action","arguments":{"args":{"a":1,"\u0061":2}}}}`),
			message: `duplicate object key "a"`,
		},
		{
			name:    "duplicate in array object",
			frame:   []byte(`{"items":[{"x":1,"x":2}]}`),
			message: `duplicate object key "x"`,
		},
		{
			name:    "invalid UTF-8",
			frame:   []byte{'{', '"', 'x', '"', ':', '"', 0xff, '"', '}'},
			message: "not valid UTF-8",
		},
		{
			name:    "unpaired high surrogate",
			frame:   []byte(`{"x":"\uD800"}`),
			message: "unpaired high surrogate",
		},
		{
			name:    "unpaired low surrogate",
			frame:   []byte(`{"x":"\uDC00"}`),
			message: "unpaired low surrogate",
		},
		{
			name:    "high followed by non-low",
			frame:   []byte(`{"x":"\uD800\u0041"}`),
			message: "not followed by a low surrogate",
		},
		{
			name:    "trailing value",
			frame:   []byte(`{"x":1} {"y":2}`),
			message: "trailing JSON value",
		},
		{
			name:    "leading-zero number",
			frame:   []byte(`{"x":01}`),
			message: "leading zero",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := parseProtocolJSON(tt.frame)
			if err == nil || !strings.Contains(err.Error(), tt.message) {
				t.Fatalf("error = %v, want containing %q", err, tt.message)
			}
		})
	}
}

func TestParseProtocolJSONAcceptsPairedSurrogates(t *testing.T) {
	frame := []byte(`{"method":"custom/read","params":{"emoji":"\uD83D\uDE00"}}`)
	parsed, err := parseProtocolJSON(frame)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(parsed.Params), `{"emoji":"\uD83D\uDE00"}`; got != want {
		t.Errorf("params = %q, want exact %q", got, want)
	}
}

func TestParseProtocolJSONActionArgsByteLimit(t *testing.T) {
	frameWithArgsSize := func(size int) []byte {
		t.Helper()
		const overhead = len(`{"value":""}`)
		args := `{"value":"` + strings.Repeat("a", size-overhead) + `"}`
		return []byte(fmt.Sprintf(`{"method":"tools/call","params":{"name":"run_action","arguments":{"args":%s}}}`, args))
	}

	parsed, err := parseProtocolJSON(frameWithArgsSize(maxRawActionArgsBytes))
	if err != nil {
		t.Fatalf("boundary args rejected: %v", err)
	}
	if len(parsed.ActionArgs) != maxRawActionArgsBytes {
		t.Fatalf("action args = %d bytes, want %d", len(parsed.ActionArgs), maxRawActionArgsBytes)
	}

	_, err = parseProtocolJSON(frameWithArgsSize(maxRawActionArgsBytes + 1))
	if err == nil || !strings.Contains(err.Error(), "32769 bytes, limit is 32768") {
		t.Fatalf("over-limit error = %v", err)
	}
}

func TestParseProtocolJSONRejectsExcessiveNesting(t *testing.T) {
	frame := []byte(strings.Repeat("[", maxJSONNestingDepth+1) + "0" + strings.Repeat("]", maxJSONNestingDepth+1))
	_, err := parseProtocolJSON(frame)
	if err == nil || !strings.Contains(err.Error(), "JSON nesting exceeds") {
		t.Fatalf("error = %v", err)
	}
}

func TestParseProtocolJSONCapturesParamsWithoutInterpretingNumbers(t *testing.T) {
	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"custom/read","params": { "large":9007199254740993, "decimal":-0.000e+9 } }`)
	parsed, err := parseProtocolJSON(frame)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(parsed.Params), `{ "large":9007199254740993, "decimal":-0.000e+9 }`; got != want {
		t.Errorf("params = %q, want exact %q", got, want)
	}
}
