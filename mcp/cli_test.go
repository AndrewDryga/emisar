package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
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
    "allOf":[{"$ref":"#/$defs/future_arguments"}],
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
				"future_tool  [read-only]",
				"future server-owned capability",
				"emisar-mcp help <tool>",
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
			"Exact descriptor: emisar-mcp help future_tool --json",
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
	if code != 2 || !strings.Contains(stderr, `unknown MCP tool "missing"`) {
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
			args:       []string{"future_tool"},
			wantArgs:   `{}`,
			result:     `{"structuredContent":{"ok":true,"source":"empty"},"content":[],"isError":false}`,
			wantOutput: `{"ok":true,"source":"empty"}`,
		},
		{
			name:       "inline preserves a large integer",
			args:       []string{"future_tool", `{"job_id":9007199254740993}`},
			wantArgs:   `{"job_id":9007199254740993}`,
			result:     `{"structuredContent":{"ok":true,"job_id":9007199254740993},"content":[],"isError":false}`,
			wantOutput: `{"ok":true,"job_id":9007199254740993}`,
		},
		{
			name:       "stdin object",
			args:       []string{"future_tool", "-"},
			stdin:      "  {\n  \"query\": \"disk full\"\n}\n",
			wantArgs:   "{\n  \"query\": \"disk full\"\n}",
			result:     `{"structuredContent":{"ok":true,"source":"stdin"},"content":[],"isError":false}`,
			wantOutput: `{"ok":true,"source":"stdin"}`,
		},
		{
			name:       "tool-domain error stays JSON",
			args:       []string{"future_tool", `{}`},
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
		{name: "empty stdin", args: []string{"future_tool", "-"}, want: "one JSON object"},
		{name: "extra argument", args: []string{"future_tool", `{}`, `{}`}, want: "usage:"},
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
	stdout, stderr, code := runCLITest(b, []string{"run_action", arguments}, "")
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
	stdout, stderr, code := runCLITest(b, []string{"future_tool"}, "")
	if code != 1 || stdout != "" {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	for _, secret := range []string{portalSecret, "postgres://", "password", apiKey} {
		if strings.Contains(stdout, secret) || strings.Contains(stderr, secret) {
			t.Fatalf("secret %q leaked: stdout=%q stderr=%q", secret, stdout, stderr)
		}
	}
}

func TestCLIPrintsJSONRPCDenialsAsStructuredJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"tool arguments were denied"}}`)
	}))
	defer srv.Close()

	stdout, stderr, code := runCLITest(newTestBridge(srv), []string{"future_tool", `{}`}, "")
	if code != 1 || stderr != "" {
		t.Fatalf("exit=%d stderr=%q", code, stderr)
	}
	if !jsonEqual([]byte(stdout), []byte(`{"code":-32602,"message":"tool arguments were denied"}`)) {
		t.Fatalf("output = %s", stdout)
	}
}

func TestCLIValidatesCommandShapeBeforeConfiguration(t *testing.T) {
	for _, args := range [][]string{
		{"list_tools", "--bogus"},
		{"help", "future_tool", "--bogus"},
		{"future_tool", `{}`, `{}`},
		{"future_tool", "--bogus"},
	} {
		stdout, stderr, code := runMain(t, "", args, nil)
		if code != 2 || stdout != "" || !strings.Contains(stderr, "usage:") {
			t.Errorf("%v: exit=%d stdout=%q stderr=%q", args, code, stdout, stderr)
		}
		if strings.Contains(stderr, "EMISAR_URL") {
			t.Errorf("%v: configuration was checked before command syntax: %q", args, stderr)
		}
	}
}

func TestCLIHumanOutputCannotEmitDescriptorControlCharacters(t *testing.T) {
	descriptor := cliToolDescriptor{
		Name:        "future\x1b]0;renamed\a_tool",
		Title:       "Future\rtool",
		Description: "Inspect\nwithout terminal controls.",
		Annotations: cliAnnotations{
			ReadOnly:    true,
			Destructive: true,
		},
		InputSchema: json.RawMessage(`{
			"type":"object",
			"properties":{"target\u001b":{"type":"string","description":"Exact\ttarget."}}
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
		for _, control := range []string{"\x1b", "\a", "\r", "\t"} {
			if strings.Contains(output, control) {
				t.Errorf("%s output retained control byte %q:\n%s", label, control, output)
			}
		}
	}
	if !strings.Contains(list, "[destructive]") || !strings.Contains(help, "destructive") {
		t.Fatalf("conflicting annotations did not fail safe:\n%s\n%s", list, help)
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
	if !strings.Contains(help, "Complex JSON object. Use --json for the exact input schema.") {
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
