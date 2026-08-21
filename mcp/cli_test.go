package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

const cliTestDescriptor = `{
  "name":"future_tool",
  "title":"Future tool",
  "description":"Inspect a future server-owned capability without requiring a bridge release.",
  "annotations":{"readOnlyHint":true,"destructiveHint":false},
  "inputSchema":{
    "type":"object",
    "allOf":[
      {"$ref":"#/$defs/future_arguments"},
      {"not":{"required":["mode","ids"]}}
    ],
    "$defs":{
      "future_arguments":{
        "type":"object",
        "required":["target"],
        "additionalProperties":false,
        "properties":{
          "target":{"type":"string","minLength":1,"maxLength":80,"description":"Exact target to inspect."},
          "mode":{"type":"string","enum":["brief","full"],"default":"brief","description":"Amount of detail to return."},
          "ids":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"integer","minimum":1,"maximum":9},"description":"Optional bounded identifiers."}
        }
      }
    }
  }
}`

func TestCLIListToolsUsesLiveDescriptors(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		assertCLIRequestHeaders(t, r, "tools/list", "")
		writeCLIResult(t, w, r, `{"tools":[`+cliTestDescriptor+`]}`)
	}))
	defer srv.Close()

	for _, tc := range []struct {
		name string
		args []string
		json bool
	}{
		{name: "human", args: []string{"list_tools"}},
		{name: "json", args: []string{"list_tools", "--json"}, json: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stdout, stderr, code := runCLITest(newTestBridge(srv), tc.args, "")
			if code != 0 || stderr != "" {
				t.Fatalf("exit=%d stderr=%q", code, stderr)
			}
			if tc.json {
				var descriptors []map[string]any
				if err := json.Unmarshal([]byte(stdout), &descriptors); err != nil {
					t.Fatalf("JSON output: %v\n%s", err, stdout)
				}
				if len(descriptors) != 1 || descriptors[0]["name"] != "future_tool" {
					t.Fatalf("descriptors = %#v", descriptors)
				}
				return
			}
			for _, want := range []string{
				"1 MCP tools",
				"OTHER MCP TOOLS",
				"future_tool  [read-only]",
				"future server-owned capability",
				"emisar-mcp help <tool>",
				"exact descriptors used by scripts and LLMs",
			} {
				if !strings.Contains(stdout, want) {
					t.Errorf("output missing %q:\n%s", want, stdout)
				}
			}
		})
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("tools/list calls = %d, want 2", got)
	}
}

func TestCLIListToolsGroupsKnownToolsAndKeepsUnknownToolsCallable(t *testing.T) {
	names := []string{"future_tool", "execute_runbook", "wait_for_run", "list_packs", "run_action"}
	descriptors := make([]json.RawMessage, 0, len(names))
	for _, name := range names {
		raw, err := json.Marshal(cliToolDescriptor{
			Name:        name,
			Description: "Live " + name + " descriptor.",
			InputSchema: json.RawMessage(`{"type":"object"}`),
		})
		if err != nil {
			t.Fatal(err)
		}
		descriptors = append(descriptors, raw)
	}
	output, err := renderToolList(descriptors)
	if err != nil {
		t.Fatal(err)
	}
	sections := []string{"\nFLEET\n", "\nACTIONS\n", "\nRUNBOOKS\n", "\nCONTINUATIONS\n", "\nOTHER MCP TOOLS\n"}
	previous := -1
	for _, section := range sections {
		at := strings.Index(output, section)
		if at <= previous {
			t.Fatalf("section %q missing or out of order:\n%s", strings.TrimSpace(section), output)
		}
		previous = at
	}
	if !strings.Contains(output, "future_tool") || !strings.Contains(output, "exact descriptors used by scripts and LLMs") {
		t.Fatalf("unknown-tool escape hatch missing:\n%s", output)
	}
}

func TestCLIDiscoveryErrorsUseSelectedOutputFormat(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"catalog unavailable"}}`)
	}))
	defer srv.Close()

	for _, tc := range []struct {
		name string
		args []string
		json bool
	}{
		{name: "list human", args: []string{"list_tools"}},
		{name: "list JSON", args: []string{"list_tools", "--json"}, json: true},
		{name: "help human", args: []string{"help", "future_tool"}},
		{name: "help JSON", args: []string{"help", "future_tool", "--json"}, json: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stdout, stderr, code := runCLITest(newTestBridge(srv), tc.args, "")
			if code != 1 || stderr != "" {
				t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
			}
			if tc.json {
				if !jsonEqual([]byte(stdout), []byte(`{"code":-32001,"message":"catalog unavailable"}`)) {
					t.Fatalf("JSON output = %q", stdout)
				}
				return
			}
			if stdout != "Code     -32001\nMessage  catalog unavailable\n" {
				t.Fatalf("human output = %q", stdout)
			}
		})
	}
}

func TestCLIToolHelpComesFromPublishedSchema(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertCLIRequestHeaders(t, r, "tools/list", "")
		writeCLIResult(t, w, r, `{"tools":[`+cliTestDescriptor+`]}`)
	}))
	defer srv.Close()

	for _, args := range [][]string{{"help", "future_tool"}, {"future_tool", "--help"}} {
		stdout, stderr, code := runCLITest(newTestBridge(srv), args, "")
		if code != 0 || stderr != "" {
			t.Fatalf("%v: exit=%d stderr=%q", args, code, stderr)
		}
		for _, want := range []string{
			"future_tool — Future tool",
			"read-only",
			"target  string · required",
			"characters 1–80",
			"mode  string · optional · default \"brief\"",
			"one of \"brief\", \"full\"",
			"ids  array<integer> · optional",
			"items 1–4; each item: value 1–9",
			"CROSS-FIELD RULES",
			"Some arguments are conditionally required or mutually exclusive.",
			"Complete input schema: emisar-mcp help future_tool --json",
		} {
			if !strings.Contains(stdout, want) {
				t.Errorf("%v: output missing %q:\n%s", args, want, stdout)
			}
		}
	}

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"help", "future_tool", "--json"}, "")
	if code != 0 || stderr != "" {
		t.Fatalf("JSON help: exit=%d stderr=%q", code, stderr)
	}
	var descriptor map[string]any
	if err := json.Unmarshal([]byte(stdout), &descriptor); err != nil {
		t.Fatalf("JSON help: %v\n%s", err, stdout)
	}
	if descriptor["name"] != "future_tool" {
		t.Fatalf("descriptor = %#v", descriptor)
	}

	_, stderr, code = runCLITest(newTestBridge(srv), []string{"help", "missing"}, "")
	if code != 2 || !strings.Contains(stderr, `Unknown MCP tool "missing"`) ||
		!strings.Contains(stderr, "emisar-mcp list_tools") {
		t.Fatalf("unknown help: exit=%d stderr=%q", code, stderr)
	}
}

func TestCLIToolCallsPreserveJSONAndReturnStructuredContent(t *testing.T) {
	tests := []struct {
		name       string
		args       []string
		stdin      string
		wantArgs   string
		result     string
		wantOutput string
		wantCode   int
	}{
		{
			name:       "omitted arguments are empty object",
			args:       []string{"future_tool", "--json"},
			wantArgs:   `{}`,
			result:     `{"structuredContent":{"ok":true,"source":"empty"},"content":[],"isError":false}`,
			wantOutput: `{"ok":true,"source":"empty"}`,
		},
		{
			name:       "inline preserves a large integer",
			args:       []string{"future_tool", `{"job_id":9007199254740993}`, "--json"},
			wantArgs:   `{"job_id":9007199254740993}`,
			result:     `{"structuredContent":{"ok":true,"job_id":9007199254740993},"content":[],"isError":false}`,
			wantOutput: `{"ok":true,"job_id":9007199254740993}`,
		},
		{
			name:       "stdin object",
			args:       []string{"future_tool", "-", "--json"},
			stdin:      "  {\n  \"query\": \"disk full\"\n}\n",
			wantArgs:   "{\n  \"query\": \"disk full\"\n}",
			result:     `{"structuredContent":{"ok":true,"source":"stdin"},"content":[],"isError":false}`,
			wantOutput: `{"ok":true,"source":"stdin"}`,
		},
		{
			name:       "tool-domain error stays JSON",
			args:       []string{"future_tool", `{}`, "--json"},
			wantArgs:   `{}`,
			result:     `{"structuredContent":{"ok":false,"error":{"code":"denied"}},"content":[],"isError":true}`,
			wantOutput: `{"ok":false,"error":{"code":"denied"}}`,
			wantCode:   1,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				assertCLIRequestHeaders(t, r, "tools/call", "future_tool")
				var request struct {
					Params struct {
						Arguments json.RawMessage `json:"arguments"`
					} `json:"params"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Fatalf("decode request: %v", err)
				}
				if !jsonEqual(request.Params.Arguments, []byte(tc.wantArgs)) {
					t.Errorf("arguments = %s, want %s", request.Params.Arguments, tc.wantArgs)
				}
				writeCLIResult(t, w, r, tc.result)
			}))
			defer srv.Close()

			stdout, stderr, code := runCLITest(newTestBridge(srv), tc.args, tc.stdin)
			if code != tc.wantCode || stderr != "" {
				t.Fatalf("exit=%d want=%d stderr=%q", code, tc.wantCode, stderr)
			}
			if !jsonEqual([]byte(stdout), []byte(tc.wantOutput)) {
				t.Fatalf("output = %s, want %s", stdout, tc.wantOutput)
			}
		})
	}
}

func TestCLIFindActionsAcceptsTextAndJSONObject(t *testing.T) {
	tests := []struct {
		name     string
		args     []string
		stdin    string
		wantArgs string
	}{
		{
			name:     "inline text",
			args:     []string{"find_actions", `postgres "primary" replication`, "--json"},
			wantArgs: `{"query":"postgres \"primary\" replication"}`,
		},
		{
			name:     "stdin text",
			args:     []string{"find_actions", "-", "--json"},
			stdin:    "  diagnose disk pressure\n",
			wantArgs: `{"query":"diagnose disk pressure"}`,
		},
		{
			name:     "JSON object",
			args:     []string{"find_actions", `{"query":"postgres replication","risk":"low"}`, "--json"},
			wantArgs: `{"query":"postgres replication","risk":"low"}`,
		},
		{
			name:     "exact-name escape",
			args:     []string{"--", "find_actions", "postgres replication", "--json"},
			wantArgs: `{"query":"postgres replication"}`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				assertCLIRequestHeaders(t, r, "tools/call", "find_actions")
				var request struct {
					Params struct {
						Arguments json.RawMessage `json:"arguments"`
					} `json:"params"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Fatalf("decode request: %v", err)
				}
				if !jsonEqual(request.Params.Arguments, []byte(test.wantArgs)) {
					t.Errorf("arguments = %s, want %s", request.Params.Arguments, test.wantArgs)
				}
				writeCLIResult(t, w, r, `{"structuredContent":{"ok":true},"content":[],"isError":false}`)
			}))
			defer srv.Close()

			stdout, stderr, code := runCLITest(newTestBridge(srv), test.args, test.stdin)
			if code != 0 || stderr != "" || !jsonEqual([]byte(stdout), []byte(`{"ok":true}`)) {
				t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
			}
		})
	}
}

func TestCLIFindActionsExplainsAnEmptyHumanResult(t *testing.T) {
	structured := `{"ok":true,"next":null,"candidates":[],"observed_at":"2026-08-21T02:34:14.407355Z"}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertCLIRequestHeaders(t, r, "tools/call", findActionsToolName)
		writeCLIResult(t, w, r, `{"structuredContent":`+structured+`,"content":[],"isError":false}`)
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"find_actions", "postgres replication"}, "")
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stderr=%q", code, stderr)
	}
	if want := "No matching actions found for \"postgres replication\".\n"; stdout != want {
		t.Fatalf("human output = %q, want %q", stdout, want)
	}

	stdout, stderr, code = runCLITest(newTestBridge(srv), []string{"find_actions", "postgres replication", "--json"}, "")
	if code != 0 || stderr != "" || !jsonEqual([]byte(stdout), []byte(structured)) {
		t.Fatalf("JSON output changed: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestCLIFindActionsEmptyHumanResultSanitizesAndBoundsTheQuery(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"candidates":[]},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	hostile := "postgres\n\x1b[31mred\u202espoof " + strings.Repeat("x", maxCLIHumanStringRunes+20)
	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"find_actions", hostile}, "")
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stderr=%q", code, stderr)
	}
	body := strings.TrimSuffix(stdout, "\n")
	if strings.ContainsAny(body, "\n\x1b") || strings.Contains(body, "\u202e") {
		t.Fatalf("human output retained a terminal control: %q", stdout)
	}
	if !strings.Contains(stdout, "postgres [31mred spoof") ||
		!strings.Contains(stdout, "…") || strings.Contains(stdout, strings.Repeat("x", maxCLIHumanStringRunes+20)) {
		t.Fatalf("human output was not safely bounded: %q", stdout)
	}

	stdout, stderr, code = runCLITest(newTestBridge(srv), []string{"find_actions", `{"risk":"low"}`}, "")
	if code != 0 || stderr != "" || stdout != "No matching actions found.\n" {
		t.Fatalf("filter-only output: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestCLIToolCallsRenderReadableTextByDefault(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertCLIRequestHeaders(t, r, "tools/call", "list_packs")
		writeCLIResult(t, w, r, `{"structuredContent":{"packs":[{"version":"1.2.3","id":"postgres"}],"ok":true,"job_id":9007199254740993},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"list_packs"}, "")
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stderr=%q", code, stderr)
	}
	want := "Job ID  9007199254740993\nOK      Yes\n\nPacks (1)\n\nItem 1 of 1\n  ID       postgres\n  Version  1.2.3\n"
	if stdout != want {
		t.Fatalf("output = %q, want %q", stdout, want)
	}
}

func TestCLIHumanOutputKeepsNestedObjectListsReadable(t *testing.T) {
	raw := []byte(`{"items":[{"name":"postgres","status":{"ok":true}},{},[]]}`)
	var stdout bytes.Buffer
	if err := writeHumanJSON(&stdout, raw); err != nil {
		t.Fatalf("write human JSON: %v", err)
	}
	want := "Items (3)\n\nItem 1 of 3\n  Name  postgres\n\n  Status\n    OK  Yes\n\nItem 2 of 3 — Empty object\n\nItem 3 of 3 — Empty list\n"
	if stdout.String() != want {
		t.Fatalf("output = %q, want %q", stdout.String(), want)
	}
}

func TestCLIHumanOutputPresentsCatalogRecordsForPeople(t *testing.T) {
	raw := []byte(`{
		"ok":true,
		"next_cursor":"opaque-page-token",
		"observed_at":"2026-08-20T18:39:03Z",
		"packs":[{
			"pack_ref":"bonding@0.1.2/sha256:abc",
			"availability":"executable",
			"issues":[],
			"actions":[{
				"action_id":"bonding.link",
				"title":"Show bond detail",
				"summary":"Show link-layer and bond detail for one interface.",
				"availability":"executable",
				"risk":"low"
			}]
		}]
	}`)
	var stdout bytes.Buffer
	if err := writeHumanJSON(&stdout, raw); err != nil {
		t.Fatalf("write human JSON: %v", err)
	}
	want := "Next cursor  opaque-page-token\n" +
		"Observed at  2026-08-20T18:39:03Z\n" +
		"OK           Yes\n\n" +
		"Packs (1)\n\n" +
		"Item 1 of 1\n" +
		"  Availability  executable\n" +
		"  Issues        Empty list\n" +
		"  Pack ref      bonding@0.1.2/sha256:abc\n\n" +
		"  Actions (1)\n\n" +
		"  Item 1 of 1\n" +
		"    Action ID     bonding.link\n" +
		"    Availability  executable\n" +
		"    Risk          low\n" +
		"    Summary       Show link-layer and bond detail for one interface.\n" +
		"    Title         Show bond detail\n"
	if stdout.String() != want {
		t.Fatalf("output = %q, want %q", stdout.String(), want)
	}
}

func TestCLIHumanOutputDistinguishesEmptyJSONValues(t *testing.T) {
	raw := []byte(`{"empty_string":"","empty_list":[],"empty_object":{},"null":null}`)
	var stdout bytes.Buffer
	if err := writeHumanJSON(&stdout, raw); err != nil {
		t.Fatalf("write human JSON: %v", err)
	}
	want := "Empty list    Empty list\n" +
		"Empty object  Empty object\n" +
		"Empty string  Empty string\n" +
		"Null          Not set (null)\n"
	if stdout.String() != want {
		t.Fatalf("output = %q, want %q", stdout.String(), want)
	}
	for _, tc := range []struct {
		raw  string
		want string
	}{
		{raw: `{}`, want: "Empty object\n"},
		{raw: `[]`, want: "Empty list\n"},
	} {
		stdout.Reset()
		if err := writeHumanJSON(&stdout, []byte(tc.raw)); err != nil {
			t.Fatalf("write root %s: %v", tc.raw, err)
		}
		if stdout.String() != tc.want {
			t.Fatalf("root %s output = %q, want %q", tc.raw, stdout.String(), tc.want)
		}
	}
}

func TestCLIHumanOutputDisambiguatesNormalizedLabels(t *testing.T) {
	raw := []byte(`{"foo_bar":1,"foo-bar":2}`)
	var stdout bytes.Buffer
	if err := writeHumanJSON(&stdout, raw); err != nil {
		t.Fatalf("write human JSON: %v", err)
	}
	want := "Foo bar [key \"foo-bar\"]  2\nFoo bar [key \"foo_bar\"]  1\n"
	if stdout.String() != want {
		t.Fatalf("output = %q, want %q", stdout.String(), want)
	}
}

func TestCLIHumanOutputIdentifiesAControlOnlyKey(t *testing.T) {
	var stdout bytes.Buffer
	if err := writeHumanJSON(&stdout, []byte(`{"\u001b":1}`)); err != nil {
		t.Fatalf("write human JSON: %v", err)
	}
	want := "Unnamed field [key \"\\x1b\"]  1\n"
	if stdout.String() != want {
		t.Fatalf("output = %q, want %q", stdout.String(), want)
	}
}

func TestCLIHumanOutputDoesNotAmplifyLongKeysThroughAlignment(t *testing.T) {
	value := make(map[string]any, 201)
	value[strings.Repeat("x", 64*1024)] = "long key"
	for index := range 200 {
		value[fmt.Sprintf("field_%03d", index)] = index
	}
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal fixture: %v", err)
	}
	var stdout bytes.Buffer
	if err := writeHumanJSON(&stdout, raw); err != nil {
		t.Fatalf("write human JSON: %v", err)
	}
	if stdout.Len() > len(raw)*3 {
		t.Fatalf("human output amplified %d input bytes to %d bytes", len(raw), stdout.Len())
	}
}

func TestCLIToolHumanOutputCannotEmitTerminalControls(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeCLIResult(t, w, r, `{"structuredContent":{"message":"first\n\u001b[31mred\u2028line\u2029paragraph\u202e","unsafe\u001b":"value"},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"future_tool"}, "")
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stderr=%q", code, stderr)
	}
	for _, control := range []string{"\n\u001b", "\u001b", "\u2028", "\u2029", "\u202e"} {
		if strings.Contains(stdout, control) {
			t.Fatalf("human output retained terminal control %q: %q", control, stdout)
		}
	}
	if !strings.Contains(stdout, "Message  first [31mred line paragraph") || !strings.Contains(stdout, "Unsafe   value") {
		t.Fatalf("sanitized human output = %q", stdout)
	}
}

func TestCLIHumanOutputBoundsLongStrings(t *testing.T) {
	long := strings.Repeat("x", maxCLIHumanStringRunes+20)
	value, ok := humanJSONScalar(long)
	wantPrefix := strings.Repeat("x", maxCLIHumanUnbrokenStringRunes) + "…"
	if !ok || !strings.HasPrefix(value, wantPrefix) ||
		!strings.HasSuffix(value, "… [truncated; use --json]") || strings.Contains(value, long) {
		t.Fatalf("bounded value = %q", value)
	}
}

func TestCLIHumanTextLeavesLineWrappingToTheTerminal(t *testing.T) {
	sentence := strings.TrimSpace(strings.Repeat("Different terminals choose their own display width. ", 4))
	raw, err := json.Marshal(map[string]string{"summary": sentence})
	if err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	if err := writeHumanJSON(&stdout, raw); err != nil {
		t.Fatalf("write human JSON: %v", err)
	}
	if want := "Summary  " + sentence + "\n"; stdout.String() != want {
		t.Fatalf("structured output inserted a display-width newline:\n%s", stdout.String())
	}

	descriptor := cliToolDescriptor{
		Name:        "future_tool",
		Description: sentence,
		InputSchema: json.RawMessage(`{"type":"object"}`),
	}
	rawDescriptor, err := json.Marshal(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	list, err := renderToolList([]json.RawMessage{rawDescriptor})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(list, "\n    "+sentence+"\n") {
		t.Fatalf("tool list inserted a display-width newline:\n%s", list)
	}
	help, err := renderToolHelp(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(help, "\n\n"+sentence+"\n\nUSAGE") {
		t.Fatalf("tool help inserted a display-width newline:\n%s", help)
	}
}

func TestCLIExactToolEscapeCallsNamesReservedByTheLocalCLI(t *testing.T) {
	for _, name := range []string{"auth", "help", "list_tools", "--future"} {
		t.Run(name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				assertCLIRequestHeaders(t, r, "tools/call", name)
				writeCLIResult(t, w, r, fmt.Sprintf(
					`{"structuredContent":{"ok":true,"tool":%q},"content":[],"isError":false}`,
					name,
				))
			}))
			defer srv.Close()

			stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"--", name, "--json"}, "")
			if code != 0 || stderr != "" {
				t.Fatalf("exit=%d stderr=%q", code, stderr)
			}
			if !jsonEqual([]byte(stdout), []byte(fmt.Sprintf(`{"ok":true,"tool":%q}`, name))) {
				t.Fatalf("output = %s", stdout)
			}
		})
	}
}

func TestMainCLIExactAuthToolBypassesLocalCredentialCommand(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertCLIRequestHeaders(t, r, "tools/call", "auth")
		writeCLIResult(t, w, r, `{"structuredContent":{"ok":true},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	stdout, stderr, code := runMain(t, "", []string{"--", "auth", "--json"}, map[string]string{
		"EMISAR_URL":     srv.URL,
		"EMISAR_API_KEY": "emk-explicit",
	})
	if code != 0 || stderr != "" || !jsonEqual([]byte(stdout), []byte(`{"ok":true}`)) {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestCLIRejectsUnsafeArgumentsBeforeHTTP(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		calls.Add(1)
	}))
	defer srv.Close()

	tests := []struct {
		name  string
		args  []string
		stdin string
		want  string
	}{
		{name: "malformed", args: []string{"future_tool", `{nope`}, want: "not strict JSON"},
		{name: "duplicate key", args: []string{"future_tool", `{"a":1,"a":2}`}, want: "duplicate object key"},
		{name: "array", args: []string{"future_tool", `[]`}, want: "one JSON object"},
		{name: "other tools stay JSON-only", args: []string{"future_tool", `postgres replication`}, want: "not strict JSON"},
		{name: "find_actions malformed object", args: []string{"find_actions", `{nope`}, want: "not strict JSON"},
		{name: "find_actions array", args: []string{"find_actions", `[]`}, want: "one JSON object"},
		{name: "find_actions invalid UTF-8", args: []string{"find_actions", "-"}, stdin: string([]byte{0xff}), want: "valid UTF-8"},
		{name: "find_actions unquoted text", args: []string{"find_actions", "postgres", "replication"}, want: "find_actions [TEXT | JSON | -]"},
		{name: "empty stdin", args: []string{"future_tool", "-"}, want: "one JSON object"},
		{name: "extra argument", args: []string{"future_tool", `{}`, `{}`}, want: "Usage:"},
		{name: "secret-shaped option", args: []string{"future_tool", "--api-key=review-secret"}, want: `--api-key=<value>`},
		{
			name:  "oversized stdin",
			args:  []string{"future_tool", "-"},
			stdin: `{"value":"` + strings.Repeat("x", maxFrameBytes) + `"}`,
			want:  "exceed",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, stderr, code := runCLITest(newTestBridge(srv), tc.args, tc.stdin)
			if code != 2 || !strings.Contains(stderr, tc.want) {
				t.Fatalf("exit=%d stderr=%q, want usage error containing %q", code, stderr, tc.want)
			}
			if strings.Contains(stderr, "review-secret") {
				t.Fatalf("diagnostic disclosed an option value: %q", stderr)
			}
		})
	}
	if got := calls.Load(); got != 0 {
		t.Fatalf("unsafe input made %d HTTP requests", got)
	}
}

func TestCLIRunActionUsesExistingOperationAndAttestationPath(t *testing.T) {
	signer, _ := testSigner(t)
	var gotAttestation, gotOperationID string
	var gotArgs json.RawMessage
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assertCLIRequestHeaders(t, r, "tools/call", "run_action")
		gotAttestation = r.Header.Get(attestationHeader)
		gotOperationID = r.Header.Get(operationIDHeader)
		var request struct {
			Params struct {
				Arguments struct {
					Args json.RawMessage `json:"args"`
				} `json:"arguments"`
			} `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		gotArgs = request.Params.Arguments.Args
		writeCLIResult(t, w, r, `{"structuredContent":{"ok":true},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	b.signer = signer
	arguments := fmt.Sprintf(
		`{"action_id":%q,"pack_ref":%q,"runner_refs":[%q],"args":{"job_id":9007199254740993},"reason":"planned maintenance","wait":"60s"}`,
		testActionID, testPackRef, testRunnerRefA,
	)
	stdout, stderr, code := runCLITest(b, []string{"run_action", arguments, "--json"}, "")
	if code != 0 || stderr != "" || !jsonEqual([]byte(stdout), []byte(`{"ok":true}`)) {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if gotAttestation == "" || gotOperationID == "" {
		t.Fatalf("private headers missing: attestation=%q operation=%q", gotAttestation, gotOperationID)
	}
	envelope, err := decodeAttestationHeader(gotAttestation)
	if err != nil {
		t.Fatal(err)
	}
	if envelope.OperationID != gotOperationID || envelope.PortalOrigin != srv.URL {
		t.Fatalf("attestation bindings = %q/%q, want %q/%q", envelope.OperationID, envelope.PortalOrigin, gotOperationID, srv.URL)
	}
	if string(gotArgs) != `{"job_id":9007199254740993}` {
		t.Fatalf("run_action args changed: %s", gotArgs)
	}
}

func TestCLIResponseFailuresDoNotLeakPortalBodyOrCredential(t *testing.T) {
	const portalSecret = "postgres://operator:password@internal/db"
	const apiKey = "emk-super-secret-DO-NOT-LEAK"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = io.WriteString(w, portalSecret)
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	b.apiKey = apiKey
	stdout, stderr, code := runCLITest(b, []string{"future_tool", "--json"}, "")
	if code != 1 ||
		!strings.Contains(stderr, "Error: The control plane request failed") ||
		!strings.Contains(stderr, "operation ID in stdout") {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	var failure struct {
		Code int `json:"code"`
		Data struct {
			OperationID string `json:"operation_id"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(stdout), &failure); err != nil {
		t.Fatalf("transport failure is not JSON: %v\n%s", err, stdout)
	}
	if failure.Code != -32603 || failure.Data.OperationID == "" {
		t.Fatalf("transport failure = %+v", failure)
	}
	for _, secret := range []string{portalSecret, "postgres://", "password", apiKey} {
		if strings.Contains(stdout, secret) || strings.Contains(stderr, secret) {
			t.Fatalf("secret %q leaked: stdout=%q stderr=%q", secret, stdout, stderr)
		}
	}
}

func TestCLIAmbiguousTransportFailureReturnsStableOperationID(t *testing.T) {
	var mu sync.Mutex
	var operationIDs []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		operationIDs = append(operationIDs, r.Header.Get(operationIDHeader))
		mu.Unlock()
		connection, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Errorf("hijack response: %v", err)
			return
		}
		_ = connection.Close()
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"future_mutation", `{}`, "--json"}, "")
	if code != 1 {
		t.Fatalf("exit=%d stdout=%s", code, stdout)
	}
	if !strings.Contains(stderr, "Error: Could not reach the control plane") ||
		!strings.Contains(stderr, "operation ID in stdout") ||
		strings.Contains(stderr, "emisar-mcp:") || strings.Contains(stderr, "\x1b[") {
		t.Fatalf("ambiguous transport diagnostic = %q", stderr)
	}
	var failure struct {
		Code int `json:"code"`
		Data struct {
			OperationID string `json:"operation_id"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(stdout), &failure); err != nil {
		t.Fatalf("transport failure is not JSON: %v\n%s", err, stdout)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(operationIDs) != 2 || operationIDs[0] == "" || operationIDs[0] != operationIDs[1] {
		t.Fatalf("retry operation IDs = %#v", operationIDs)
	}
	if failure.Code != -32603 || failure.Data.OperationID != operationIDs[0] {
		t.Fatalf("transport failure = %+v, request operation = %q", failure, operationIDs[0])
	}
}

func TestCLILocalPreSendFailureDoesNotAdvertiseOperationRecovery(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		calls.Add(1)
	}))
	defer srv.Close()

	wrapper := `{"value":""}`
	arguments := `{"value":"` + strings.Repeat("x", maxFrameBytes-len(wrapper)) + `"}`
	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"future_mutation", arguments, "--json"}, "")
	if code != 1 || !strings.Contains(stderr, "Error: The request is too large") ||
		!strings.Contains(stderr, "Reduce the JSON arguments") ||
		!strings.Contains(stderr, "request frame exceeds") {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	var failure map[string]any
	if err := json.Unmarshal([]byte(stdout), &failure); err != nil {
		t.Fatalf("local failure is not JSON: %v\n%s", err, stdout)
	}
	if failure["code"] != float64(-32603) || failure["message"] != "emisar bridge could not send this request" {
		t.Fatalf("local failure = %#v", failure)
	}
	if _, exists := failure["data"]; exists {
		t.Fatalf("unsent request advertised operation recovery: %#v", failure)
	}
	if got := calls.Load(); got != 0 {
		t.Fatalf("local failure made %d HTTP requests", got)
	}
}

func TestCLIPrintsJSONRPCDenialsAsStructuredJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"tool arguments were denied"}}`)
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"future_tool", `{}`, "--json"}, "")
	if code != 1 || stderr != "" {
		t.Fatalf("exit=%d stderr=%q", code, stderr)
	}
	if !jsonEqual([]byte(stdout), []byte(`{"code":-32602,"message":"tool arguments were denied"}`)) {
		t.Fatalf("output = %s", stdout)
	}
}

func TestCLIPrintsJSONRPCDenialsAsReadableTextByDefault(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"tool arguments were denied"}}`)
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"future_tool", `{}`}, "")
	if code != 1 || stderr != "" || stdout != "Code     -32602\nMessage  tool arguments were denied\n" {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestCLIValidatesCommandShapeBeforeConfiguration(t *testing.T) {
	for _, args := range [][]string{
		{"--"},
		{"--", "future_tool", `{}`, `{}`},
		{"list_tools", "--bogus"},
		{"help", "future_tool", "--bogus"},
		{"future_tool", "--json", `{}`},
		{"future_tool", `{}`, `{}`},
		{"future_tool", "--bogus"},
	} {
		stdout, stderr, code := runMain(t, "", args, nil)
		if code != 2 || stdout != "" || !strings.Contains(stderr, "Usage:") {
			t.Errorf("%v: exit=%d stdout=%q stderr=%q", args, code, stdout, stderr)
		}
		if strings.Contains(stderr, "EMISAR_URL") {
			t.Errorf("%v: configuration was checked before command syntax: %q", args, stderr)
		}
	}
}

func TestCLIHumanOutputCannotEmitDescriptorControlCharacters(t *testing.T) {
	descriptor := cliToolDescriptor{
		Name:        "future;\x1b touch /tmp/pwn\u202e",
		Title:       "Future\rtool",
		Description: "Inspect\nwithout terminal controls.",
		Annotations: cliAnnotations{
			ReadOnly:    true,
			Destructive: true,
		},
		InputSchema: json.RawMessage(`{
			"type":"object",
			"properties":{"target\u001b":{"type":"string","description":"Exact\ttarget.","default":"safe\u202evil"}}
		}`),
	}
	raw, err := json.Marshal(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	list, err := renderToolList([]json.RawMessage{raw})
	if err != nil {
		t.Fatal(err)
	}
	help, err := renderToolHelp(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	for label, output := range map[string]string{"list": list, "help": help} {
		for _, control := range []string{"\x1b", "\a", "\r", "\t", "\u202e"} {
			if strings.Contains(output, control) {
				t.Errorf("%s output retained control byte %q:\n%s", label, control, output)
			}
		}
	}
	if !strings.Contains(list, "[destructive]") || !strings.Contains(help, "destructive") {
		t.Fatalf("conflicting annotations did not fail safe:\n%s\n%s", list, help)
	}
	if !strings.Contains(help, `default "safe vil"`) {
		t.Fatalf("schema default was not safely rendered:\n%s", help)
	}
	if strings.Contains(help, "emisar-mcp future;") ||
		!strings.Contains(help, "emisar-mcp 'future;  touch /tmp/pwn '") {
		t.Fatalf("tool name is not safely shell-quoted:\n%s", help)
	}
}

func TestCLIToolHelpCallsOutCrossFieldRules(t *testing.T) {
	descriptor := cliToolDescriptor{
		Name:        "execute_future_runbook",
		Title:       "Execute future runbook",
		Description: "Execute either a published runbook or one exact draft.",
		InputSchema: json.RawMessage(`{
			"type":"object",
			"required":["reason"],
			"properties":{
				"runbook_ref":{"type":"string"},
				"slug":{"type":"string"},
				"allow_draft":{"type":"boolean","default":false},
				"reason":{"type":"string"}
			},
			"allOf":[{
				"if":{"properties":{"allow_draft":{"const":true}}},
				"then":{"required":["slug"],"not":{"required":["runbook_ref"]}},
				"else":{"required":["runbook_ref"],"not":{"required":["slug"]}}
			}]
		}`),
	}
	help, err := renderToolHelp(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"CROSS-FIELD RULES",
		"conditionally required or mutually exclusive",
		"complete input schema is authoritative; print it with the command below",
		"reason  string · required",
		"runbook_ref  string · optional",
		"Complete input schema: emisar-mcp help execute_future_runbook --json",
	} {
		if !strings.Contains(help, want) {
			t.Errorf("help missing %q:\n%s", want, help)
		}
	}
}

func TestCLIToolHelpBoundsRecursiveSchemasAndPreservesLargeNumbers(t *testing.T) {
	recursive := cliToolDescriptor{
		Name:        "recursive_tool",
		Title:       "Recursive tool",
		Description: "Exercise a hostile recursive schema.",
		InputSchema: json.RawMessage(`{
			"type":"object",
			"properties":{"nodes":{"$ref":"#/$defs/node"}},
			"$defs":{"node":{"type":"array","items":{"$ref":"#/$defs/node"}}}
		}`),
	}
	help, err := renderToolHelp(recursive)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(help, "Complex or recursive JSON object") {
		t.Fatalf("recursive schema did not fall back:\n%s", help)
	}

	largeNumber := cliToolDescriptor{
		Name:        "large_number_tool",
		Title:       "Large number tool",
		Description: "Exercise exact schema-number presentation.",
		InputSchema: json.RawMessage(`{
			"type":"object",
			"properties":{"job_id":{"type":"integer","maximum":9007199254740993}}
		}`),
	}
	help, err = renderToolHelp(largeNumber)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(help, "value at most 9007199254740993") {
		t.Fatalf("large schema number changed:\n%s", help)
	}
}

func TestCLIRejectsDuplicateToolDescriptors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeCLIResult(t, w, r, `{"tools":[`+cliTestDescriptor+`,`+cliTestDescriptor+`]}`)
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"list_tools"}, "")
	if code != 1 || stdout != "" || !strings.Contains(stderr, `duplicate name "future_tool"`) {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestCLIToolHelpUsesExactEscapeForReservedNames(t *testing.T) {
	for _, name := range []string{"accounts", "auth", "help", "list_tools"} {
		descriptor := cliToolDescriptor{
			Name:        name,
			Title:       "Server tool",
			Description: "A server-owned name that collides with a local command.",
			InputSchema: json.RawMessage(`{"type":"object"}`),
		}
		help, err := renderToolHelp(descriptor)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(help, "USAGE\n  emisar-mcp -- "+name+" [JSON | -] [--json]") {
			t.Fatalf("reserved tool usage is ambiguous:\n%s", help)
		}
	}
}

func TestCLIFindActionsHelpDocumentsTextAndJSONInput(t *testing.T) {
	descriptor := cliToolDescriptor{
		Name:        findActionsToolName,
		Title:       "Find actions",
		Description: "Search runnable actions.",
		InputSchema: json.RawMessage(`{"type":"object","properties":{"query":{"type":"string"}}}`),
	}
	help, err := renderToolHelp(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"USAGE\n  emisar-mcp find_actions [TEXT | JSON | -] [--json]",
		"TEXT INPUT",
		"Plain text is sent as the query argument",
		"Use JSON for filters or cursors",
	} {
		if !strings.Contains(help, want) {
			t.Errorf("find_actions help is missing %q:\n%s", want, help)
		}
	}
}

func TestMainCLIDefaultsClientAttributionWithoutChangingStdIO(t *testing.T) {
	var userAgent string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		userAgent = r.Header.Get("User-Agent")
		writeCLIResult(t, w, r, `{"structuredContent":{"ok":true},"content":[],"isError":false}`)
	}))
	defer srv.Close()

	_, stderr, code := runMain(t, "", []string{"future_tool"}, map[string]string{
		"EMISAR_URL":     srv.URL,
		"EMISAR_API_KEY": "emk-x",
	})
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stderr=%q", code, stderr)
	}
	if !strings.Contains(userAgent, "client=emisar-mcp-cli") {
		t.Fatalf("CLI User-Agent = %q", userAgent)
	}

	t.Setenv("EMISAR_CLIENT", "")
	if got := buildUserAgent(); !strings.Contains(got, "client=unknown") {
		t.Fatalf("stdio User-Agent default changed: %q", got)
	}
}

func TestMainCLIEndToEndAcrossDiscoveryHelpCallsAndErrors(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		var request struct {
			Method string `json:"method"`
			Params struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			} `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Errorf("decode request: %v", err)
			return
		}
		assertCLIRequestHeaders(t, r, request.Method, request.Params.Name)
		switch {
		case request.Method == "tools/list":
			writeCLIResult(t, w, r, `{"tools":[`+cliTestDescriptor+`]}`)
		case request.Params.Name == "denied_tool":
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":false,"error":{"code":"denied"}},"content":[],"isError":true}`)
		case request.Params.Name == "malformed_tool":
			writeCLIResult(t, w, r, `{"content":[],"isError":false}`)
		case request.Params.Name == "gateway_tool":
			w.WriteHeader(http.StatusBadGateway)
			_, _ = io.WriteString(w, "do-not-print-response-body")
		default:
			arguments := request.Params.Arguments
			if len(arguments) == 0 {
				arguments = json.RawMessage(`{}`)
			}
			writeCLIResult(t, w, r, `{"structuredContent":{"ok":true,"tool":`+
				fmt.Sprintf("%q", request.Params.Name)+`,"arguments":`+string(arguments)+`},"content":[],"isError":false}`)
		}
	}))
	defer srv.Close()

	env := map[string]string{"EMISAR_URL": srv.URL, "EMISAR_API_KEY": "e2e-token"}
	stdout, stderr, code := runMain(t, "", []string{"list_tools", "--json"}, env)
	if code != 0 || stderr != "" {
		t.Fatalf("list_tools: exit=%d stderr=%q", code, stderr)
	}
	var descriptors []map[string]any
	if err := json.Unmarshal([]byte(stdout), &descriptors); err != nil ||
		len(descriptors) != 1 || descriptors[0]["name"] != "future_tool" {
		t.Fatalf("list_tools output: err=%v value=%#v", err, descriptors)
	}

	stdout, stderr, code = runMain(t, "", []string{"help", "future_tool"}, env)
	if code != 0 || stderr != "" ||
		!strings.Contains(stdout, "target  string · required") ||
		!strings.Contains(stdout, "CROSS-FIELD RULES") {
		t.Fatalf("help: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, "", []string{"future_tool", `{"target":"db-human"}`}, env)
	wantHuman := "OK    Yes\nTool  future_tool\n\nArguments\n  Target  db-human\n"
	if code != 0 || stderr != "" || stdout != wantHuman {
		t.Fatalf("human call: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, "", []string{
		"future_tool", `{"target":"db-1","job_id":9007199254740993}`, "--json",
	}, env)
	if code != 0 || stderr != "" ||
		!jsonEqual([]byte(stdout), []byte(`{"ok":true,"tool":"future_tool","arguments":{"target":"db-1","job_id":9007199254740993}}`)) {
		t.Fatalf("inline call: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, `{"target":"db-2"}`, []string{"--", "help", "-", "--json"}, env)
	if code != 0 || stderr != "" ||
		!jsonEqual([]byte(stdout), []byte(`{"ok":true,"tool":"help","arguments":{"target":"db-2"}}`)) {
		t.Fatalf("stdin exact call: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, "", []string{"denied_tool", `{}`, "--json"}, env)
	if code != 1 || stderr != "" ||
		!jsonEqual([]byte(stdout), []byte(`{"ok":false,"error":{"code":"denied"}}`)) {
		t.Fatalf("denied call: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, "", []string{"gateway_tool", `{}`, "--json"}, env)
	if code != 1 ||
		!strings.Contains(stderr, "Error: The control plane request failed") ||
		!strings.Contains(stderr, "operation ID in stdout") ||
		strings.Contains(stderr, "do-not-print-response-body") {
		t.Fatalf("gateway call: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	var gatewayFailure struct {
		Code int `json:"code"`
		Data struct {
			OperationID string `json:"operation_id"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(stdout), &gatewayFailure); err != nil ||
		gatewayFailure.Code != -32603 || gatewayFailure.Data.OperationID == "" {
		t.Fatalf("gateway response: err=%v failure=%+v", err, gatewayFailure)
	}

	stdout, stderr, code = runMain(t, "", []string{"malformed_tool", `{}`, "--json"}, env)
	if code != 1 || !strings.Contains(stderr, "control plane returned no structuredContent object") ||
		!strings.Contains(stderr, "operation ID in stdout") ||
		strings.Index(stderr, "operation ID in stdout") > strings.Index(stderr, "Upgrade the Emisar server") {
		t.Fatalf("malformed response: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	var malformedFailure struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
		Data    struct {
			OperationID string `json:"operation_id"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(stdout), &malformedFailure); err != nil {
		t.Fatalf("malformed response failure is not JSON: %v\n%s", err, stdout)
	}
	if malformedFailure.Code != -32603 ||
		malformedFailure.Message != "invalid upstream tool response" ||
		malformedFailure.Data.OperationID == "" {
		t.Fatalf("malformed response failure = %+v", malformedFailure)
	}
	if got := calls.Load(); got != 9 {
		t.Fatalf("HTTP requests = %d, want 9", got)
	}
}

func TestCLIToolHelpFallsBackForUnresolvableSchema(t *testing.T) {
	descriptor := cliToolDescriptor{
		Name:        "future_tool",
		Title:       "Future tool",
		Description: "Future contract.",
		InputSchema: json.RawMessage(`{"$ref":"#/$defs/missing"}`),
	}
	help, err := renderToolHelp(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(help, "Complex or recursive JSON object. Use the complete input schema.") {
		t.Fatalf("fallback missing:\n%s", help)
	}
}

func runCLITest(b *bridge, args []string, stdin string) (stdout, stderr string, code int) {
	var out, errOut bytes.Buffer
	b.diagnostics = &errOut
	code = b.runCLI(args, strings.NewReader(stdin), &out, &errOut)
	return out.String(), errOut.String(), code
}

func assertCLIRequestHeaders(t *testing.T, r *http.Request, method, name string) {
	t.Helper()
	if got := r.Header.Get(protocolVersionHeader); got != cliProtocolVersion {
		t.Errorf("protocol header = %q, want %q", got, cliProtocolVersion)
	}
	if got := r.Header.Get(methodHeader); got != method {
		t.Errorf("method header = %q, want %q", got, method)
	}
	if got := r.Header.Get(nameHeader); got != name {
		t.Errorf("name header = %q, want %q", got, name)
	}
	if r.Header.Get(requestTokenHeader) == "" {
		t.Error("request token is missing")
	}
}

func writeCLIResult(t *testing.T, w http.ResponseWriter, r *http.Request, result string) {
	t.Helper()
	var request struct {
		ID json.RawMessage `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		// Some handlers decoded the body already. CLI requests always use id 1.
		request.ID = json.RawMessage("1")
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = fmt.Fprintf(w, `{"jsonrpc":"2.0","id":%s,"result":%s}`, request.ID, result)
}

func jsonEqual(a, b []byte) bool {
	var left, right any
	return json.Unmarshal(a, &left) == nil && json.Unmarshal(b, &right) == nil && fmt.Sprint(left) == fmt.Sprint(right)
}
