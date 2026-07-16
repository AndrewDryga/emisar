package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/iotest"
	"time"
)

// The bridge is a thin stdio↔HTTP shim. Its only jobs are:
//   1. POST each JSON-RPC frame to the portal's /api/mcp/rpc endpoint.
//   2. Forward the response back to stdout.
//   3. Mint one private request token so retries preserve transport identity.
//
// All MCP-protocol semantics (renderRunBlocks, wait_for_run,
// pending-approval messages) now live in the portal, so the tests here
// only pin the proxy contract, not any tool-output formatting.

func (b *bridge) forward(frame []byte) ([]byte, error) {
	meta := parseRequestMeta(frame)
	headers := requestHeaders{}
	if !meta.notification() {
		requestToken := b.requestToken(1)
		headers.requestToken = requestToken
		headers.operationID = toolCallOperationID(meta, requestToken)
	}
	return b.forwardRequestContext(
		context.Background(),
		frame,
		meta,
		headers,
	)
}

func TestOperationIDForTokenIsStableAndBounded(t *testing.T) {
	first := operationIDForToken("request-token-1")
	if first != "op_1P6W2Q2PWTYR9XGMHYJH7CA4R0" {
		t.Fatalf("operation ID vector drifted: %q", first)
	}
	if got, want := len(first), len("op_")+26; got != want {
		t.Fatalf("operation ID length = %d, want %d: %q", got, want, first)
	}
	if !strings.HasPrefix(first, "op_") || !strings.Contains("01234567", first[3:4]) {
		t.Fatalf("operation ID is not a 128-bit Crockford token: %q", first)
	}
	for _, value := range first[3:] {
		if !strings.ContainsRune("0123456789ABCDEFGHJKMNPQRSTVWXYZ", value) {
			t.Fatalf("operation ID contains non-Crockford character %q: %q", value, first)
		}
	}
	if again := operationIDForToken("request-token-1"); again != first {
		t.Errorf("same request token changed operation ID: %q vs %q", first, again)
	}
	if other := operationIDForToken("request-token-2"); other == first {
		t.Fatalf("different request tokens share operation ID %q", first)
	}
	if got := operationIDForToken(""); got != "" {
		t.Fatalf("empty request token produced operation ID %q", got)
	}
}

func TestToolCallOperationIDIsIndependentOfPortalToolNames(t *testing.T) {
	tests := []struct {
		name string
		body string
		want bool
	}{
		{"action", `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_action","arguments":{"args":{}}}}`, true},
		{"read", `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_packs","arguments":{}}}`, true},
		{"future tool", `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"future_tool","arguments":{}}}`, true},
		{"missing params", `{"jsonrpc":"2.0","id":1,"method":"tools/call"}`, true},
		{"ping", `{"jsonrpc":"2.0","id":1,"method":"ping"}`, false},
		{"notification", `{"jsonrpc":"2.0","method":"tools/call","params":{"name":"execute_runbook","arguments":{}}}`, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			frame := []byte(tc.body)
			got := toolCallOperationID(parseRequestMeta(frame), "request-token")
			if (got != "") != tc.want {
				t.Fatalf("toolCallOperationID() = %q, want present=%v", got, tc.want)
			}
		})
	}
}

func TestEncodeCrockford128Boundaries(t *testing.T) {
	if got, want := encodeCrockford128([16]byte{}), strings.Repeat("0", 26); got != want {
		t.Errorf("zero encoding = %q, want %q", got, want)
	}
	maximum := [16]byte{}
	for i := range maximum {
		maximum[i] = 0xff
	}
	if got, want := encodeCrockford128(maximum), "7"+strings.Repeat("Z", 25); got != want {
		t.Errorf("maximum encoding = %q, want %q", got, want)
	}
}

func TestParseRequestMeta_ClassifiesMCPIDsAndNotifications(t *testing.T) {
	tests := []struct {
		name         string
		frame        string
		valid        bool
		notification bool
	}{
		{"integer id", `{"jsonrpc":"2.0","id":9007199254740993,"method":"ping"}`, true, false},
		{"exponent id", `{"jsonrpc":"2.0","id":1e3,"method":"ping"}`, false, false},
		{"string id", `{"jsonrpc":"2.0","id":"7","method":"ping"}`, true, false},
		{"notification", `{"jsonrpc":"2.0","method":"notifications/initialized"}`, true, true},
		{"null id", `{"jsonrpc":"2.0","id":null,"method":"ping"}`, false, false},
		{"fractional id", `{"jsonrpc":"2.0","id":1.5,"method":"ping"}`, false, false},
		{"object id", `{"jsonrpc":"2.0","id":{},"method":"ping"}`, false, false},
		{"missing jsonrpc", `{"id":1,"method":"ping"}`, false, false},
		{"wrong jsonrpc", `{"jsonrpc":"1.0","id":1,"method":"ping"}`, false, false},
		{"missing method", `{"jsonrpc":"2.0","id":1}`, false, false},
		{"null method", `{"jsonrpc":"2.0","id":1,"method":null}`, false, false},
		{"non-string method", `{"jsonrpc":"2.0","id":1,"method":7}`, false, false},
		{
			"oversized string id",
			fmt.Sprintf(`{"jsonrpc":"2.0","id":"%s","method":"ping"}`, strings.Repeat("i", maxRequestIDBytes+1)),
			false,
			false,
		},
		{
			"oversized integer id",
			fmt.Sprintf(`{"jsonrpc":"2.0","id":%s,"method":"ping"}`, strings.Repeat("9", maxRequestIDBytes+1)),
			false,
			false,
		},
		{"malformed frame", `{not json`, false, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			meta := parseRequestMeta([]byte(tc.frame))
			if meta.valid != tc.valid || meta.notification() != tc.notification {
				t.Errorf("meta = %+v, want valid=%v notification=%v", meta, tc.valid, tc.notification)
			}
		})
	}
}

func TestMatchingJSONRPCID_PreservesTypeAndNumericValue(t *testing.T) {
	if !matchingJSONRPCID(json.RawMessage(`1000`), json.RawMessage(`1000`)) {
		t.Error("equal integer ids should match")
	}
	if matchingJSONRPCID(json.RawMessage(`1e3`), json.RawMessage(`1000`)) {
		t.Error("exponent-form ids are outside the supported integer grammar")
	}
	if !matchingJSONRPCID(json.RawMessage(`"\u0037"`), json.RawMessage(`"7"`)) {
		t.Error("equivalent string ids should match across JSON escaping")
	}
	if matchingJSONRPCID(json.RawMessage(`7`), json.RawMessage(`"7"`)) {
		t.Error("numeric and string ids are distinct")
	}
}

func TestParseEndpoint(t *testing.T) {
	cases := []struct {
		base          string
		allowInsecure bool
		want          string
	}{
		{"https://emisar.dev", false, "https://emisar.dev"},
		{"https://emisar.dev/", false, "https://emisar.dev"},
		{"HTTPS://EMISAR.DEV:443", false, "https://emisar.dev"},
		{"HTTPS://example.com:8443", false, "https://example.com:8443"},
		{"http://LOCALHOST:80", false, "http://localhost"},
		{"http://localhost:4000/", false, "http://localhost:4000"},
		{"http://127.0.0.1:4000", false, "http://127.0.0.1:4000"},
		{"http://[::1]:4000", false, "http://[::1]:4000"},
		{"http://emisar.dev", false, ""},
		{"http://192.168.1.10", false, ""},
		{"http://emisar.dev", true, "http://emisar.dev"},
		{"ws://emisar.dev", false, ""},
		{"ftp://emisar.dev", false, ""},
		{"://bad", false, ""},
		{"https://", false, ""},
		{"https:///api", false, ""},
		{"//emisar.dev", false, ""},
		{"https://user:secret@emisar.dev", false, ""},
		{"https://emisar.dev/api", false, ""},
		{"https://emisar.dev//", false, ""},
		{"https://emisar.dev/%2F", false, ""},
		{"https://emisar.dev?region=us", false, ""},
		{"https://emisar.dev?", false, ""},
		{"https://emisar.dev/#setup", false, ""},
		{"https://emisar.dev:", false, ""},
		{"https://emisar.dev:0", false, ""},
		{"https://emisar.dev:65535", false, "https://emisar.dev:65535"},
		{"https://emisar.dev:65536", false, ""},
		{"https://emisar.dev:99999", false, ""},
	}
	for _, c := range cases {
		got, err := parseEndpoint(c.base, c.allowInsecure)
		if c.want != "" && err != nil {
			t.Errorf("%q (allowInsecure=%v): want %q, got %v", c.base, c.allowInsecure, c.want, err)
		}
		if c.want == "" && err == nil {
			t.Errorf("%q (allowInsecure=%v): want error, got nil", c.base, c.allowInsecure)
		}
		if got != c.want {
			t.Errorf("%q (allowInsecure=%v): got %q, want %q", c.base, c.allowInsecure, got, c.want)
		}
	}
}

func TestNewProcessNonce_UniquePerProcess(t *testing.T) {
	// Bind to vars so the comparison is two distinct evaluations, not a
	// syntactically-identical `f() == f()` (which static analysis flags as
	// a tautology even though the nonce makes the values differ).
	first, err := newProcessNonce(rand.Reader)
	if err != nil {
		t.Fatalf("newProcessNonce: %v", err)
	}
	second, err := newProcessNonce(rand.Reader)
	if err != nil {
		t.Fatalf("newProcessNonce: %v", err)
	}
	if first == second {
		t.Error("two process nonces collided")
	}
	if len(first) != 32 || len(second) != 32 {
		t.Fatalf("process nonces must carry 128 bits: %q / %q", first, second)
	}
}

// A rand read failure must fail closed (error), never fall back to a
// shared constant that would alias two processes' request tokens.
func TestNewProcessNonce_FailsClosedOnRandError(t *testing.T) {
	if _, err := newProcessNonce(iotest.ErrReader(errors.New("rand unavailable"))); err == nil {
		t.Error("newProcessNonce returned nil error on a failing reader — must fail closed")
	}
}

// -- forward: HTTP plumbing -----------------------------------------

func TestForward_SetsAuthUserAgentRequestAndOperationHeaders(t *testing.T) {
	var gotAuth, gotUA, gotRequestToken, gotOperationID string
	var hadOperationID bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotUA = r.Header.Get("User-Agent")
		gotRequestToken = r.Header.Get(requestTokenHeader)
		gotOperationID = r.Header.Get(operationIDHeader)
		_, hadOperationID = r.Header[operationIDHeader]
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)

	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"execute_runbook","arguments":{}}}`)
	if _, err := b.forward(frame); err != nil {
		t.Fatalf("forward: %v", err)
	}

	if gotAuth != "Bearer k" {
		t.Errorf("Authorization = %q, want %q", gotAuth, "Bearer k")
	}
	if gotUA != "ua" {
		t.Errorf("User-Agent = %q, want %q", gotUA, "ua")
	}
	if gotRequestToken != b.requestToken(1) {
		t.Errorf("%s = %q, want %q", requestTokenHeader, gotRequestToken, b.requestToken(1))
	}
	if gotOperationID != operationIDForToken(gotRequestToken) {
		t.Errorf("%s = %q, want token-derived operation", operationIDHeader, gotOperationID)
	}
	if !hadOperationID {
		t.Errorf("frame with id should set the %s header", operationIDHeader)
	}
}

func TestForward_OmitsOperationHeaderForNonToolCalls(t *testing.T) {
	var hadOperationID bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, hadOperationID = r.Header[operationIDHeader]
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`)
	if _, err := b.forward(frame); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if hadOperationID {
		t.Errorf("non-tool request must not set the %s header", operationIDHeader)
	}
}

func TestForward_NeverSendsMcpSessionIDHeader(t *testing.T) {
	var hadSession bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, hadSession = r.Header["Mcp-Session-Id"]
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)

	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if hadSession {
		t.Fatal("stateless bridge must not invent an MCP session id")
	}
}

func TestForward_OmitsRequestIdentityHeadersForNotifications(t *testing.T) {
	var hadRequestToken, hadOperationID bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hadRequestToken = r.Header.Get(requestTokenHeader) != ""
		hadOperationID = r.Header.Get(operationIDHeader) != ""
		// Notifications get 202 + empty body per JSON-RPC over HTTP.
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	b := newTestBridge(srv)

	// Notification: no id field.
	frame := []byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	body, err := b.forward(frame)
	if err != nil {
		t.Fatalf("forward: %v", err)
	}
	if body != nil {
		t.Errorf("202 should yield nil body, got %q", body)
	}
	if hadRequestToken {
		t.Errorf("notifications must NOT set the %s header", requestTokenHeader)
	}
	if hadOperationID {
		t.Errorf("notifications must NOT set the %s header", operationIDHeader)
	}
}

func TestForward_5xxBecomesError(t *testing.T) {
	const secret = "upstream down with secret=do-not-log"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte(secret))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	_, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	if err == nil {
		t.Fatal("expected error on 5xx")
	}
	if !strings.Contains(err.Error(), "502") {
		t.Errorf("error should name the status, got %v", err)
	}
	if strings.Contains(err.Error(), secret) {
		t.Errorf("untrusted response body leaked through the error: %v", err)
	}
}

func TestForward_MutationRetriesOnceAfterPreAdmissionTransportFailure(t *testing.T) {
	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_runbook_draft","arguments":{"name":"maintenance"}}}`)
	var attempts int
	var requestTokens, operationIDs, authorizations []string
	b := &bridge{
		endpoint:     "https://example.test/api/mcp/rpc",
		apiKey:       "key",
		userAgent:    "ua",
		processNonce: "session",
		client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			attempts++
			requestTokens = append(requestTokens, req.Header.Get(requestTokenHeader))
			operationIDs = append(operationIDs, req.Header.Get(operationIDHeader))
			authorizations = append(authorizations, req.Header.Get("Authorization"))
			if attempts == 1 {
				return nil, errors.New("connect failed before admission")
			}
			body, err := io.ReadAll(req.Body)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(body, frame) {
				t.Fatalf("retry body = %s, want %s", body, frame)
			}
			return jsonRPCResponse(""), nil
		})},
	}

	if _, err := b.forward(frame); err != nil {
		t.Fatalf("bounded mutation retry: %v", err)
	}
	if attempts != 2 {
		t.Fatalf("attempts = %d, want exactly 2", attempts)
	}
	if len(requestTokens) != 2 || requestTokens[0] == "" || requestTokens[0] != requestTokens[1] {
		t.Fatalf("request identity changed across retry: %#v", requestTokens)
	}
	if len(operationIDs) != 2 || operationIDs[0] == "" || operationIDs[0] != operationIDs[1] {
		t.Fatalf("operation identity changed across retry: %#v", operationIDs)
	}
	if len(authorizations) != 2 || authorizations[0] != "Bearer key" || authorizations[0] != authorizations[1] {
		t.Fatalf("credential generation changed across retry: %#v", authorizations)
	}
}

func TestForward_MutationRetriesOnceAfterAmbiguousResponseLoss(t *testing.T) {
	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"execute_runbook","arguments":{"runbook_id":"rb_1"}}}`)
	type observed struct {
		body          string
		requestToken  string
		operationID   string
		authorization string
	}
	var attempts []observed
	b := &bridge{
		endpoint:     "https://example.test/api/mcp/rpc",
		apiKey:       "key",
		userAgent:    "ua",
		processNonce: "session",
		client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			body, err := io.ReadAll(req.Body)
			if err != nil {
				t.Fatal(err)
			}
			attempts = append(attempts, observed{
				body: string(body), requestToken: req.Header.Get(requestTokenHeader),
				operationID: req.Header.Get(operationIDHeader), authorization: req.Header.Get("Authorization"),
			})
			if len(attempts) == 1 {
				return &http.Response{
					StatusCode: http.StatusOK,
					Header:     http.Header{"Content-Type": []string{"application/json"}},
					Body:       io.NopCloser(iotest.ErrReader(errors.New("response connection lost"))),
				}, nil
			}
			return jsonRPCResponse(""), nil
		})},
	}

	if _, err := b.forward(frame); err != nil {
		t.Fatalf("ambiguous mutation retry: %v", err)
	}
	if len(attempts) != 2 {
		t.Fatalf("attempts = %d, want exactly 2", len(attempts))
	}
	if attempts[0] != attempts[1] || attempts[0].body != string(frame) || attempts[0].requestToken == "" || attempts[0].operationID == "" {
		t.Fatalf("retry changed authenticated mutation request: %#v", attempts)
	}
}

func TestForward_DoesNotRetryReadsOrRetryMutationsMoreThanOnce(t *testing.T) {
	for _, test := range []struct {
		name         string
		frame        []byte
		wantAttempts int
	}{
		{"read", []byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`), 1},
		{"mutation", []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_runbook_draft","arguments":{}}}`), 2},
	} {
		t.Run(test.name, func(t *testing.T) {
			attempts := 0
			b := &bridge{
				endpoint: "https://example.test/api/mcp/rpc", apiKey: "key", userAgent: "ua", processNonce: "session",
				client: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
					attempts++
					return nil, errors.New("transport unavailable")
				})},
			}
			if _, err := b.forward(test.frame); err == nil {
				t.Fatal("persistent transport failure unexpectedly succeeded")
			}
			if attempts != test.wantAttempts {
				t.Fatalf("attempts = %d, want %d", attempts, test.wantAttempts)
			}
		})
	}
}

func TestForward_4xxIsReturnedVerbatim(t *testing.T) {
	// 4xx responses are JSON-RPC error frames shaped by the portal —
	// forward them as-is so the client sees the structured error.
	body := []byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"unauthorized"}}`)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	got, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	if err != nil {
		t.Fatalf("4xx should not become an error: %v", err)
	}
	if !bytes.Equal(got, body) {
		t.Errorf("body = %q, want %q", got, body)
	}
}

func TestForward_RejectsUnsafePortalResponses(t *testing.T) {
	tests := []struct {
		name        string
		status      int
		contentType string
		body        []byte
	}{
		{"HTML content type", 200, "text/html", []byte(`{"jsonrpc":"2.0","id":1,"result":{}}`)},
		{"malformed JSON", 200, "application/json", []byte(`{"jsonrpc":`)},
		{"plain JSON error object", 400, "application/json", []byte(`{"error":"not JSON-RPC"}`)},
		{"multiple JSON values", 200, "application/json", []byte(`{"jsonrpc":"2.0","id":1,"result":{}} {}`)},
		{"mismatched id", 200, "application/json", []byte(`{"jsonrpc":"2.0","id":2,"result":{}}`)},
		{"wrong id type", 200, "application/json", []byte(`{"jsonrpc":"2.0","id":"1","result":{}}`)},
		{"wrong protocol version", 200, "application/json", []byte(`{"jsonrpc":"1.0","id":1,"result":{}}`)},
		{"result and error", 200, "application/json", []byte(`{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-1,"message":"x"}}`)},
		{"neither result nor error", 200, "application/json", []byte(`{"jsonrpc":"2.0","id":1}`)},
		{"fractional error code", 400, "application/json", []byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-1.5,"message":"x"}}`)},
		{"missing error message", 400, "application/json", []byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-1}}`)},
		{"result on error status", 400, "application/json", []byte(`{"jsonrpc":"2.0","id":1,"result":{}}`)},
		{"invalid UTF-8", 200, "application/json", []byte{'{', '"', 'x', '"', ':', '"', 0xff, '"', '}'}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", tc.contentType)
				w.WriteHeader(tc.status)
				_, _ = w.Write(tc.body)
			}))
			defer srv.Close()

			if _, err := newTestBridge(srv).forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`)); err == nil {
				t.Fatal("unsafe portal response must be rejected")
			}
		})
	}
}

func TestForward_AcceptsJSONContentTypeParameters(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{}}`))
	}))
	defer srv.Close()
	if _, err := newTestBridge(srv).forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`)); err != nil {
		t.Fatalf("valid JSON media type parameters must be accepted: %v", err)
	}
}

func TestServe_UnsafeResponseProducesOriginalTypedID(t *testing.T) {
	for _, id := range []string{`7`, `"7"`} {
		t.Run(id, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "text/html")
				_, _ = w.Write([]byte("<html>not MCP</html>"))
			}))
			defer srv.Close()

			var out bytes.Buffer
			frame := `{"jsonrpc":"2.0","id":` + id + `,"method":"ping"}`
			if err := newTestBridge(srv).serve(strings.NewReader(frame+"\n"), &out); err != nil {
				t.Fatalf("serve: %v", err)
			}
			var response struct {
				ID    json.RawMessage `json:"id"`
				Error struct {
					Code int `json:"code"`
				} `json:"error"`
			}
			if err := json.Unmarshal(out.Bytes(), &response); err != nil {
				t.Fatalf("synthetic response is invalid JSON: %v (%q)", err, out.String())
			}
			if string(response.ID) != id || response.Error.Code != -32603 {
				t.Errorf("synthetic response = %s, want exact id %s and -32603", out.String(), id)
			}
		})
	}
}

func TestServe_NotificationFailureProducesNoOutput(t *testing.T) {
	for _, tc := range []struct {
		status      int
		contentType string
		body        string
	}{
		{502, "text/plain", "secret upstream failure"},
		{400, "application/json", `{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"bad notification"}}`},
		{200, "application/json", `{"jsonrpc":"2.0","id":null,"result":{}}`},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", tc.contentType)
			w.WriteHeader(tc.status)
			_, _ = w.Write([]byte(tc.body))
		}))

		var out bytes.Buffer
		frame := `{"jsonrpc":"2.0","method":"notifications/initialized"}` + "\n"
		if err := newTestBridge(srv).serve(strings.NewReader(frame), &out); err != nil {
			srv.Close()
			t.Fatalf("serve: %v", err)
		}
		srv.Close()
		if out.Len() != 0 {
			t.Errorf("notification failure must stay silent, got %q", out.String())
		}
	}
}

// -- readCappedBody: bound the untrusted portal response ------------

func TestReadCappedBody(t *testing.T) {
	const limit = 8
	for _, tc := range []struct {
		name    string
		body    string
		wantErr bool
	}{
		{"under the limit", "1234567", false},
		{"exactly the limit", "12345678", false},
		{"over the limit", "123456789", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := readCappedBody(strings.NewReader(tc.body), limit)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("%d bytes over limit %d: want an error", len(tc.body), limit)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if string(got) != tc.body {
				t.Errorf("got %q, want the full body %q", got, tc.body)
			}
		})
	}
}

func TestForward_RefusesRedirect(t *testing.T) {
	// A redirect must NOT be followed — doing so replays the Authorization
	// Bearer to the 3xx target. The RPC endpoint never legitimately redirects.
	var targetHit bool
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		targetHit = true
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"leaked"}`))
	}))
	defer target.Close()

	redirector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Location", target.URL)
		w.WriteHeader(http.StatusFound)
	}))
	defer redirector.Close()

	b := newTestBridge(redirector)
	_, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	if err == nil {
		t.Fatal("a redirect response must become a correlated transport error")
	}
	if targetHit {
		t.Fatal("redirect was followed — the Bearer API key would leak to the redirect target")
	}
}

// -- serve: stdin/stdout framing -----------------------------------

func TestServe_NewlineDelimitsResponses(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		// No trailing newline — serve must add one so the client's
		// line reader frames.
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)

	in := strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}` + "\n")
	var out bytes.Buffer

	if err := b.serve(in, &out); err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("serve: %v", err)
	}

	if !strings.HasSuffix(out.String(), "\n") {
		t.Errorf("response not newline-delimited: %q", out.String())
	}
	if !strings.Contains(out.String(), `"result":"ok"`) {
		t.Errorf("response body missing: %q", out.String())
	}
}

func TestServe_NotificationsProduceNoOutput(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusAccepted) // notification acknowledged
	}))
	defer srv.Close()

	b := newTestBridge(srv)

	in := strings.NewReader(`{"jsonrpc":"2.0","method":"notifications/initialized"}` + "\n")
	var out bytes.Buffer

	if err := b.serve(in, &out); err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("serve: %v", err)
	}

	if out.Len() != 0 {
		t.Errorf("notifications should produce no output, got %q", out.String())
	}
}

func TestServe_NetworkErrorEmitsJSONRPCError(t *testing.T) {
	// Server immediately closes — exercises the network-error path
	// where serve must synthesize a JSON-RPC error frame so the
	// client doesn't just see a dropped pipe.
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	srv.Start()
	srv.Close() // make subsequent connects fail

	b := newTestBridge(srv)

	in := strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}` + "\n")
	var out bytes.Buffer

	_ = b.serve(in, &out)

	body := out.String()
	if !strings.Contains(body, `"error"`) || !strings.Contains(body, `-32603`) {
		t.Errorf("expected synthetic JSON-RPC -32603 error, got %q", body)
	}
	if !strings.Contains(body, `"id":1`) {
		t.Errorf("synthetic error must retain the request id, got %q", body)
	}
}

func TestServe_OversizedFrameKeepsServing(t *testing.T) {
	// An over-long frame must be rejected for that line alone; the stdio stream
	// (the LLM's only path to the cloud) keeps serving the next frame. The old
	// bufio.Scanner returned ErrTooLong → serve error → os.Exit(1), killing it.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":2,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)

	oversized := strings.Repeat("x", maxFrameBytes+1)
	normal := `{"jsonrpc":"2.0","id":2,"method":"ping"}`
	in := strings.NewReader(oversized + "\n" + normal + "\n")
	var out bytes.Buffer

	if err := b.serve(in, &out); err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("serve: %v", err)
	}

	body := out.String()
	if !strings.Contains(body, "-32600") {
		t.Errorf("oversized frame should yield a -32600 error frame, got %q", body)
	}
	if !strings.Contains(body, `"result":"ok"`) {
		t.Error("the frame after an oversized one was not served")
	}
}

func TestReadFrameLine_OversizedRetainsNothingAndRealigns(t *testing.T) {
	// The OOM guard: an over-long frame must be drained WITHOUT being retained —
	// bufio.ReadString would buffer the whole newline-free stream first. So the
	// helper returns oversize=true with zero retained bytes, and advances the
	// reader past the terminating newline so the NEXT frame still parses. (A
	// regression that grows the line unbounded shows up as len(line) != 0 here.)
	oversized := strings.Repeat("x", maxFrameBytes+1)
	next := `{"jsonrpc":"2.0","id":1,"method":"ping"}`
	br := bufio.NewReaderSize(strings.NewReader(oversized+"\n"+next+"\n"), 64*1024)

	line, oversize, err := readFrameLine(br)
	if err != nil {
		t.Fatalf("oversized frame: unexpected err %v", err)
	}
	if !oversize {
		t.Fatal("a frame past maxFrameBytes must report oversize=true")
	}
	if len(line) != 0 {
		t.Errorf("an oversized frame must retain no bytes, got %d", len(line))
	}

	line, oversize, err = readFrameLine(br)
	if err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("next frame: unexpected err %v", err)
	}
	if oversize {
		t.Error("the frame after an oversized one must not be flagged oversize")
	}
	if got := string(bytes.TrimSpace(line)); got != next {
		t.Errorf("next frame = %q, want %q (drain failed to realign on the newline)", got, next)
	}
}

func TestReadFrameLine_BudgetsJSONBodyWithoutLineDelimiter(t *testing.T) {
	exact := strings.Repeat("x", maxFrameBytes)
	for _, delimiter := range []string{"\n", "\r\n"} {
		line, oversize, err := readFrameLine(bufio.NewReader(strings.NewReader(exact + delimiter)))
		if err != nil {
			t.Fatalf("delimiter %q: %v", delimiter, err)
		}
		if oversize || string(line) != exact {
			t.Fatalf("delimiter %q: body len=%d oversize=%v, want exact accepted body", delimiter, len(line), oversize)
		}
	}

	line, oversize, err := readFrameLine(bufio.NewReader(strings.NewReader(exact + "x\n")))
	if err != nil {
		t.Fatal(err)
	}
	if !oversize || len(line) != 0 {
		t.Fatalf("over-limit body len=%d oversize=%v, want drained rejection", len(line), oversize)
	}
}

// -- buildUserAgent: stamps client + host ---------------------------

func TestBuildUserAgent_ContainsBridgeAndClient(t *testing.T) {
	t.Setenv("EMISAR_CLIENT", "claude-desktop")
	ua := buildUserAgent()
	if !strings.HasPrefix(ua, bridgeName+"/") {
		t.Errorf("UA should start with %q, got %q", bridgeName+"/", ua)
	}
	if !strings.Contains(ua, "client=claude-desktop") {
		t.Errorf("UA should include client=claude-desktop, got %q", ua)
	}
	if !strings.Contains(ua, "host=") {
		t.Errorf("UA should include host=…, got %q", ua)
	}
	if !strings.Contains(ua, "os="+runtime.GOOS) {
		t.Errorf("UA should include os=%s, got %q", runtime.GOOS, ua)
	}
}

func TestBuildUserAgent_DefaultsClientWhenEnvUnset(t *testing.T) {
	t.Setenv("EMISAR_CLIENT", "")
	ua := buildUserAgent()
	if !strings.Contains(ua, "client=unknown") {
		t.Errorf("blank EMISAR_CLIENT should map to client=unknown, got %q", ua)
	}
}

// -- parseEndpoint: case-insensitive loopback -----------------------

// the loopback allowance for cleartext http is case-insensitive on
// the host: http://LOCALHOST is accepted exactly like http://localhost
// (isLoopbackHost uses strings.EqualFold), so casing can't accidentally trip the
// cleartext refusal for a legit local dev endpoint.
func TestParseEndpoint_LoopbackCaseInsensitive(t *testing.T) {
	for _, base := range []string{"http://LOCALHOST:4000", "http://LocalHost:4000", "http://localhost:4000"} {
		if _, err := parseEndpoint(base, false); err != nil {
			t.Errorf("%q should be allowed (case-insensitive loopback), got %v", base, err)
		}
	}
}

// -- forward: method / content-type / body handling ----------------

// every forwarded frame is a POST with Content-Type:
// application/json (the portal's RPC endpoint only accepts POSTed JSON).
func TestForward_UsesPostAndJSONContentType(t *testing.T) {
	var gotMethod, gotCT string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotCT = r.Header.Get("Content-Type")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if gotMethod != http.MethodPost {
		t.Errorf("method = %q, want POST", gotMethod)
	}
	if gotCT != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", gotCT)
	}
}

func TestForward_NegotiatesAndSendsProtocolHeaders(t *testing.T) {
	type observed struct {
		accept   string
		protocol string
	}
	var requests []observed
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, observed{
			accept:   r.Header.Get("Accept"),
			protocol: r.Header.Get("MCP-Protocol-Version"),
		})
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		result := `{}`
		if request.Method == "initialize" {
			result = `{"protocolVersion":"2025-06-18"}`
		}
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(request.ID) + `,"result":` + result + `}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":2,"method":"ping"}`)); err != nil {
		t.Fatalf("ping: %v", err)
	}
	if len(requests) != 2 {
		t.Fatalf("requests = %d, want 2", len(requests))
	}
	for i, request := range requests {
		if request.accept != "application/json, text/event-stream" {
			t.Errorf("request %d Accept = %q", i, request.accept)
		}
	}
	if requests[0].protocol != "" {
		t.Errorf("initialize must omit MCP-Protocol-Version, got %q", requests[0].protocol)
	}
	if requests[1].protocol != "2025-06-18" {
		t.Errorf("subsequent request protocol = %q, want negotiated version", requests[1].protocol)
	}
}

func TestForward_RejectsInitializeResultWithoutValidProtocolVersion(t *testing.T) {
	for _, result := range []string{`{}`, `{"protocolVersion":"not-a-version"}`, `{"protocolVersion":"2025-6-18"}`, `{"PROTOCOLVERSION":"2025-06-18"}`} {
		t.Run(result, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":` + result + `}`))
			}))
			defer srv.Close()
			if _, err := newTestBridge(srv).forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)); err == nil {
				t.Fatal("initialize result without a valid protocol version must be rejected")
			}
		})
	}
}

func TestForwardRejectsAmbiguousPortalJSON(t *testing.T) {
	tests := []struct {
		name     string
		status   int
		response string
	}{
		{name: "duplicate id", response: `{"jsonrpc":"2.0","id":2,"id":1,"result":{}}`},
		{name: "duplicate result", response: `{"jsonrpc":"2.0","id":1,"result":{},"result":{}}`},
		{name: "unpaired surrogate", response: `{"jsonrpc":"2.0","id":1,"result":"\uD800"}`},
		{name: "case alias error message", status: http.StatusBadRequest, response: `{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"MESSAGE":"bad"}}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if test.status != 0 {
					w.WriteHeader(test.status)
				}
				_, _ = io.WriteString(w, test.response)
			}))
			defer srv.Close()

			if _, err := newTestBridge(srv).forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`)); err == nil {
				t.Fatalf("ambiguous portal response was accepted: %s", test.response)
			}
		})
	}
}

func TestForward_202ForRequestIsRejected(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"should be dropped"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err == nil {
		t.Fatal("202 is only valid for a notification")
	}
}

// a stale/expired token produces a portal 4xx JSON-RPC error frame,
// which is relayed VERBATIM (not masked as a generic -32603). The bridge does no
// auth logic; the portal shapes the structured error and the client sees it whole.
func TestForward_ExpiredToken4xxRelayedVerbatim(t *testing.T) {
	errFrame := []byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"api key expired"}}`)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write(errFrame)
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	b.apiKey = "emk-stale-expired"
	got, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`))
	if err != nil {
		t.Fatalf("a portal 4xx error frame must not become a Go error: %v", err)
	}
	if !bytes.Equal(got, errFrame) {
		t.Errorf("4xx error frame not relayed verbatim:\n got %s\nwant %s", got, errFrame)
	}
}

// a request-build failure (http.NewRequest) is surfaced to the
// caller (serve then maps it to -32603). An endpoint with an embedded control
// character fails url.Parse inside http.NewRequest. (forward is exercised in
// isolation here; the startup parseEndpoint would normally reject such a
// URL first.)
func TestForward_RequestBuildErrorSurfaced(t *testing.T) {
	b := &bridge{
		endpoint:     "http://example.com/\x7f", // invalid control char → NewRequest fails
		apiKey:       "k",
		userAgent:    "ua",
		client:       newHTTPClient(),
		processNonce: "sess",
	}
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err == nil {
		t.Fatal("a malformed endpoint should surface a request-build error")
	}
}

// On a 5xx, stdout receives a generic correlated transport error and never the
// untrusted body or API key. The process-level test also proves stderr is clean.
func TestServe_5xxBodyAndKeyNeverReachClientFrame(t *testing.T) {
	const secretBody = "stacktrace: postgres://user:hunter2@db/internal panic at 0xdead"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte(secretBody))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	b.apiKey = "emk-super-secret-key"

	in := strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}` + "\n")
	var out bytes.Buffer
	_ = b.serve(in, &out)

	got := out.String()
	if !strings.Contains(got, "-32603") || !strings.Contains(got, "upstream transport error") {
		t.Errorf("client frame should be the generic -32603, got %q", got)
	}
	if strings.Contains(got, "hunter2") || strings.Contains(got, "postgres://") || strings.Contains(got, "0xdead") {
		t.Errorf("the 5xx body leaked into the client frame: %q", got)
	}
	if strings.Contains(got, b.apiKey) {
		t.Errorf("the API key leaked into the client frame: %q", got)
	}
}

func TestServe_TransportErrorCarriesOnlyRequestOperationID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer srv.Close()

	frames := map[string][]byte{
		"mutation": []byte(`{"jsonrpc":"2.0","id":"mutate-1","method":"tools/call","params":{"name":"execute_runbook","arguments":{}}}`),
		"read":     []byte(`{"jsonrpc":"2.0","id":"read-1","method":"tools/call","params":{"name":"list_packs","arguments":{}}}`),
	}
	for name, frame := range frames {
		t.Run(name, func(t *testing.T) {
			b := newTestBridge(srv)
			var out bytes.Buffer
			if err := b.serve(bytes.NewReader(append(frame, '\n')), &out); err != nil {
				t.Fatalf("serve: %v", err)
			}

			var response struct {
				Error struct {
					Data map[string]any `json:"data"`
				} `json:"error"`
			}
			if err := json.Unmarshal(bytes.TrimSpace(out.Bytes()), &response); err != nil {
				t.Fatalf("decode synthetic response: %v (%s)", err, out.Bytes())
			}
			want := operationIDForToken(b.requestToken(1))
			if got := response.Error.Data["operation_id"]; got != want {
				t.Fatalf("operation_id = %v, want %q", got, want)
			}
			if len(response.Error.Data) != 1 {
				t.Fatalf("transport data = %+v, want only operation_id", response.Error.Data)
			}
		})
	}
}

// An OAuth `emo-*` bearer bypasses local API-key rotation state but is carried
// by the transport identically: `Authorization: Bearer <token>` verbatim.
func TestForward_OAuthBearerCarriedVerbatim(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	b.apiKey = "emo-0a1b2c3d4e5f-oauth-access-token"
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if gotAuth != "Bearer emo-0a1b2c3d4e5f-oauth-access-token" {
		t.Errorf("Authorization = %q, want the emo- token carried verbatim", gotAuth)
	}
}

func TestForward_NonJSONResponseIsRejected(t *testing.T) {
	raw := []byte("this is not json at all <<>>")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(raw)
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err == nil {
		t.Fatal("non-JSON portal content must not reach MCP stdout")
	}
}

func TestForward_Empty200BodyIsRejectedAndCorrelated(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK) // zero-length body
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err == nil {
		t.Fatal("an empty 200 cannot be a JSON-RPC response")
	}

	// And serve writes nothing for an empty 200 (len(resp)==0 branch).
	srv2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv2.Close()
	b2 := newTestBridge(srv2)
	var out bytes.Buffer
	_ = b2.serve(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`+"\n"), &out)
	if !strings.Contains(out.String(), `"id":1`) || !strings.Contains(out.String(), "-32603") {
		t.Errorf("an empty 200 must produce a correlated transport error, got %q", out.String())
	}
}

// / — the relay is buffered, not streamed: forward reads
// the COMPLETE (capped) body before returning one slice, even when the portal
// writes it in chunks with flushes between them. (No partial/streamed frame is
// emitted.)
func TestForward_BuffersChunkedBodyBeforeReturning(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Skip("response writer is not a Flusher")
		}
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":["`))
		flusher.Flush()
		_, _ = w.Write([]byte(`chunk-a`))
		flusher.Flush()
		_, _ = w.Write([]byte(`","chunk-b"]}`))
		flusher.Flush()
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	got, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`))
	if err != nil {
		t.Fatalf("forward: %v", err)
	}
	want := `{"jsonrpc":"2.0","id":1,"result":["chunk-a","chunk-b"]}`
	if string(got) != want {
		t.Errorf("chunked body not fully buffered before return:\n got %q\nwant %q", got, want)
	}
}

// -- serve: framing, ordering, write errors ------------------------

// a portal body that already ends in "\n" is not double-terminated:
// serve appends a newline only when the body lacks one, so the client never sees
// "\n\n".
func TestServe_BodyAlreadyNewlineTerminatedNotDoubled(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}` + "\n"))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	var out bytes.Buffer
	if err := b.serve(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`+"\n"), &out); err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("serve: %v", err)
	}
	if strings.HasSuffix(out.String(), "\n\n") {
		t.Errorf("body already ending in \\n was double-terminated: %q", out.String())
	}
	if !strings.HasSuffix(out.String(), "}\n") {
		t.Errorf("expected exactly one trailing newline, got %q", out.String())
	}
}

// Concurrent requests may complete out of order, but every response remains one
// complete newline-delimited frame with its original id.
func TestServe_MultipleFramesRemainWhole(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var env struct {
			ID json.RawMessage `json:"id"`
		}
		_ = json.Unmarshal(body, &env)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(env.ID) + `,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	in := strings.NewReader(
		`{"jsonrpc":"2.0","id":1,"method":"ping"}` + "\n" +
			`{"jsonrpc":"2.0","id":2,"method":"ping"}` + "\n" +
			`{"jsonrpc":"2.0","id":3,"method":"ping"}` + "\n")
	var out bytes.Buffer
	if err := b.serve(in, &out); err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("serve: %v", err)
	}

	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("want 3 newline-delimited responses, got %d: %q", len(lines), out.String())
	}
	joined := strings.Join(lines, "\n")
	for _, want := range []string{`"id":1`, `"id":2`, `"id":3`} {
		if strings.Count(joined, want) != 1 {
			t.Errorf("responses = %q, want exactly one %s", joined, want)
		}
	}
}

func TestServe_RequestMethodsSentAsNotificationsNeverReachPortal(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	input := strings.NewReader(
		`{"jsonrpc":"2.0","method":"tools/call","params":{"name":"run_action"}}` + "\n" +
			`{"jsonrpc":"2.0","method":"ping"}` + "\n",
	)
	var output bytes.Buffer
	if err := newTestBridge(srv).serve(input, &output); err != nil {
		t.Fatalf("serve: %v", err)
	}
	if got := hits.Load(); got != 0 {
		t.Errorf("portal requests = %d, want none", got)
	}
	if output.Len() != 0 {
		t.Errorf("request notifications produced stdout %q", output.String())
	}
}

func TestServe_PingCompletesWhileAnotherRequestIsHeld(t *testing.T) {
	heldStarted := make(chan struct{})
	releaseHeld := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			ID json.RawMessage `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		if string(request.ID) == "1" {
			close(heldStarted)
			<-releaseHeld
		}
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(request.ID) + `,"result":{}}`))
	}))
	defer srv.Close()

	input := strings.NewReader(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call"}` + "\n" +
			`{"jsonrpc":"2.0","id":2,"method":"ping"}` + "\n",
	)
	output := newFrameWriter()
	done := make(chan error, 1)
	go func() { done <- newTestBridge(srv).serve(input, output) }()

	<-heldStarted
	if frame := string(receiveFrame(t, output.writes)); !strings.Contains(frame, `"id":2`) {
		t.Fatalf("first completed response = %q, want prompt ping id 2", frame)
	}
	select {
	case err := <-done:
		t.Fatalf("serve returned before held work completed: %v", err)
	default:
	}

	close(releaseHeld)
	if frame := string(receiveFrame(t, output.writes)); !strings.Contains(frame, `"id":1`) {
		t.Fatalf("held response = %q, want id 1", frame)
	}
	if err := <-done; err != nil {
		t.Fatalf("serve: %v", err)
	}
}

func TestServe_ConcurrencyCapRejectsOverflowWithoutBufferingWork(t *testing.T) {
	started := make(chan struct{}, maxConcurrentRequests+1)
	release := make(chan struct{})
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		started <- struct{}{}
		<-release
		var request struct {
			ID json.RawMessage `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(request.ID) + `,"result":{}}`))
	}))
	defer srv.Close()

	var input strings.Builder
	for id := 1; id <= maxConcurrentRequests+1; id++ {
		fmt.Fprintf(&input, `{"jsonrpc":"2.0","id":%d,"method":"tools/call"}`+"\n", id)
	}
	output := newFrameWriter()
	done := make(chan error, 1)
	go func() { done <- newTestBridge(srv).serve(strings.NewReader(input.String()), output) }()

	for range maxConcurrentRequests {
		<-started
	}
	overload := string(receiveFrame(t, output.writes))
	if !strings.Contains(overload, fmt.Sprintf(`"id":%d`, maxConcurrentRequests+1)) ||
		!strings.Contains(overload, "too many in-flight requests") {
		t.Fatalf("overflow response = %q", overload)
	}
	select {
	case <-started:
		t.Fatal("overflow request reached the portal")
	default:
	}

	close(release)
	if err := <-done; err != nil {
		t.Fatalf("serve: %v", err)
	}
	if got := hits.Load(); got != maxConcurrentRequests {
		t.Errorf("portal requests = %d, want cap %d", got, maxConcurrentRequests)
	}
}

func TestServe_CancellationStopsExactRequestAndStaysSilent(t *testing.T) {
	targetStarted := make(chan string, 1)
	targetCancelled := make(chan struct{}, 1)
	cancelForwarded := make(chan string, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Method string `json:"method"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		if request.Method == "notifications/cancelled" {
			cancelForwarded <- r.Header.Get(cancelTokenHeader)
			w.WriteHeader(http.StatusAccepted)
			return
		}

		targetStarted <- r.Header.Get(requestTokenHeader)
		<-r.Context().Done()
		targetCancelled <- struct{}{}
	}))
	defer srv.Close()

	reader, writer := io.Pipe()
	output := newFrameWriter()
	done := make(chan error, 1)
	go func() { done <- newTestBridge(srv).serve(reader, output) }()

	_, _ = io.WriteString(writer, `{"jsonrpc":"2.0","id":"job-7","method":"tools/call"}`+"\n")
	requestToken := <-targetStarted
	if len(requestToken) != 2*sha256.Size || strings.Contains(requestToken, "sess") {
		t.Fatalf("request token must be a fixed digest that keeps the process nonce private: %q", requestToken)
	}
	_, _ = io.WriteString(writer, `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"job-7"}}`+"\n")
	_, _ = io.WriteString(writer, `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"job-7"}}`+"\n")
	_ = writer.Close()

	<-targetCancelled
	if cancelToken := <-cancelForwarded; cancelToken != requestToken || cancelToken == "" {
		t.Errorf("cancel token = %q, request token = %q", cancelToken, requestToken)
	}
	if err := <-done; err != nil {
		t.Fatalf("serve: %v", err)
	}
	if len(cancelForwarded) != 0 {
		t.Errorf("duplicate cancellation was forwarded %d extra time(s)", len(cancelForwarded))
	}
	if got := output.String(); got != "" {
		t.Errorf("cancelled request and cancellation notification must be silent, got %q", got)
	}
}

func TestServe_CancellationRefreshesPeerPromotedCredential(t *testing.T) {
	targetStarted := make(chan string, 1)
	targetCancelled := make(chan struct{}, 1)
	cancelForwarded := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Method string `json:"method"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		if request.Method == "notifications/cancelled" {
			cancelForwarded <- r.Header.Get("Authorization")
			w.WriteHeader(http.StatusAccepted)
			return
		}

		targetStarted <- r.Header.Get("Authorization")
		<-r.Context().Done()
		targetCancelled <- struct{}{}
	}))
	defer srv.Close()

	current := testAPIKey(23)
	configDir := t.TempDir()
	storeA := newCredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(current))
	storeB := newCredentialStoreAt(configDir, testEndpointOrigin, keyPrefix(current))
	b := newRotationTestBridge(storeB, current)
	b.endpoint = srv.URL
	originalAuthorization := "Bearer " + b.apiKey
	reader, writer := io.Pipe()
	done := make(chan error, 1)
	go func() { done <- b.serve(reader, io.Discard) }()

	_, _ = io.WriteString(writer, `{"jsonrpc":"2.0","id":1,"method":"tools/call"}`+"\n")
	if authorization := <-targetStarted; authorization != originalAuthorization {
		t.Fatalf("target authorization = %q, want %q", authorization, originalAuthorization)
	}
	peer := newRotationTestBridge(storeA, current)
	_, acknowledgement := peer.rotationProposal()
	peer.acknowledgeRotation(acknowledgement)
	rotatedAuthorization := "Bearer " + peer.apiKey

	_, _ = io.WriteString(writer, `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}`+"\n")
	_ = writer.Close()
	<-targetCancelled
	if authorization := <-cancelForwarded; authorization != rotatedAuthorization {
		t.Errorf("cancellation authorization = %q, want peer-promoted credential %q", authorization, rotatedAuthorization)
	}
	if err := <-done; err != nil {
		t.Fatalf("serve: %v", err)
	}
}

func TestServe_CancellationBypassesFullConcurrencyCap(t *testing.T) {
	started := make(chan string, maxConcurrentRequests)
	targetCancelled := make(chan struct{}, 1)
	cancelForwarded := make(chan struct{}, 1)
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		if request.Method == "notifications/cancelled" {
			cancelForwarded <- struct{}{}
			w.WriteHeader(http.StatusAccepted)
			return
		}

		started <- string(request.ID)
		if string(request.ID) == "1" {
			<-r.Context().Done()
			targetCancelled <- struct{}{}
			return
		}
		<-release
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(request.ID) + `,"result":{}}`))
	}))
	defer srv.Close()

	reader, writer := io.Pipe()
	output := newFrameWriter()
	done := make(chan error, 1)
	go func() { done <- newTestBridge(srv).serve(reader, output) }()

	for id := 1; id <= maxConcurrentRequests; id++ {
		_, _ = fmt.Fprintf(writer, `{"jsonrpc":"2.0","id":%d,"method":"tools/call"}`+"\n", id)
	}
	for range maxConcurrentRequests {
		<-started
	}

	_, _ = io.WriteString(writer, `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}`+"\n")
	<-targetCancelled
	<-cancelForwarded
	close(release)
	_ = writer.Close()

	if err := <-done; err != nil {
		t.Fatalf("serve: %v", err)
	}
	if got := strings.Count(output.String(), `"result"`); got != maxConcurrentRequests-1 {
		t.Errorf("result frames = %d, want %d uncancelled requests", got, maxConcurrentRequests-1)
	}
}

func TestServe_LateCancellationDoesNotReachPortalAndSequentialIDReuseIsDistinct(t *testing.T) {
	var hits atomic.Int32
	var operationIDs []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		operationIDs = append(operationIDs, r.Header.Get(operationIDHeader))
		var request struct {
			ID json.RawMessage `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(request.ID) + `,"result":{}}`))
	}))
	defer srv.Close()

	reader, writer := io.Pipe()
	output := newFrameWriter()
	done := make(chan error, 1)
	go func() { done <- newTestBridge(srv).serve(reader, output) }()

	request := `{"jsonrpc":"2.0","id":"reused","method":"tools/call","params":{"name":"list_packs","arguments":{}}}` + "\n"
	_, _ = io.WriteString(writer, request)
	_ = receiveFrame(t, output.writes)
	_, _ = io.WriteString(writer, `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"reused"}}`+"\n")
	_, _ = io.WriteString(writer, request)
	_ = writer.Close()

	if frame := string(receiveFrame(t, output.writes)); !strings.Contains(frame, `"id":"reused"`) || !strings.Contains(frame, `"result"`) {
		t.Fatalf("reused-id response = %q", frame)
	}
	if err := <-done; err != nil {
		t.Fatalf("serve: %v", err)
	}
	if got := hits.Load(); got != 2 {
		t.Errorf("portal requests = %d, want two sequential calls and no late cancellation", got)
	}
	if len(operationIDs) != 2 || operationIDs[0] == "" || operationIDs[0] == operationIDs[1] {
		t.Errorf("sequential operation identities = %#v, want two distinct values", operationIDs)
	}
}

func TestServe_ConcurrentDuplicateIDIsRejected(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		close(started)
		<-release
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":"duplicate","result":{}}`))
	}))
	defer srv.Close()

	reader, writer := io.Pipe()
	output := newFrameWriter()
	done := make(chan error, 1)
	go func() { done <- newTestBridge(srv).serve(reader, output) }()

	request := `{"jsonrpc":"2.0","id":"duplicate","method":"ping"}` + "\n"
	_, _ = io.WriteString(writer, request)
	<-started
	_, _ = io.WriteString(writer, request)

	if frame := string(receiveFrame(t, output.writes)); !strings.Contains(frame, `"id":"duplicate"`) ||
		!strings.Contains(frame, "request id is already in flight") {
		t.Fatalf("duplicate-id response = %q", frame)
	}

	close(release)
	_ = writer.Close()
	if frame := string(receiveFrame(t, output.writes)); !strings.Contains(frame, `"result"`) {
		t.Fatalf("original response = %q", frame)
	}
	if err := <-done; err != nil {
		t.Fatalf("serve: %v", err)
	}
}

func TestServe_InitializeCannotBeCancelled(t *testing.T) {
	started := make(chan struct{}, 2)
	release := make(chan struct{})
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		started <- struct{}{}
		<-release
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}`))
	}))
	defer srv.Close()

	reader, writer := io.Pipe()
	output := newFrameWriter()
	done := make(chan error, 1)
	go func() { done <- newTestBridge(srv).serve(reader, output) }()

	_, _ = io.WriteString(writer, `{"jsonrpc":"2.0","id":1,"method":"initialize"}`+"\n")
	<-started
	_, _ = io.WriteString(writer, `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}`+"\n")
	close(release)
	_ = writer.Close()

	if frame := string(receiveFrame(t, output.writes)); !strings.Contains(frame, `"id":1`) {
		t.Fatalf("initialize response = %q", frame)
	}
	if err := <-done; err != nil {
		t.Fatalf("serve: %v", err)
	}
	if got := hits.Load(); got != 1 {
		t.Errorf("portal requests = %d, want initialize only", got)
	}
}

func TestServe_ExponentIDIsRejectedWithoutPortalAdmission(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1000,"result":{}}`))
	}))
	defer srv.Close()

	input := strings.NewReader(
		`{"jsonrpc":"2.0","id":1e3,"method":"tools/call"}` + "\n" +
			`{"jsonrpc":"2.0","id":1000,"method":"ping"}` + "\n",
	)
	var output bytes.Buffer
	if err := newTestBridge(srv).serve(input, &output); err != nil {
		t.Fatalf("serve: %v", err)
	}
	if got := hits.Load(); got != 1 {
		t.Errorf("portal requests = %d, want only the lexical integer request", got)
	}
	if got := output.String(); !strings.Contains(got, `"id":null`) ||
		!strings.Contains(got, `"code":-32600`) || !strings.Contains(got, `"id":1000`) {
		t.Errorf("output = %q, want invalid exponent error and integer response", got)
	}
}

func TestRequestIDKey_DistinguishesTypesAndRejectsExponentIDs(t *testing.T) {
	numericExponent := requestIDKey(parseRequestMeta([]byte(
		`{"jsonrpc":"2.0","id":1e3,"method":"ping"}`,
	)))
	numericDecimal := requestIDKey(parseRequestMeta([]byte(
		`{"jsonrpc":"2.0","id":1000,"method":"ping"}`,
	)))
	stringID := requestIDKey(parseRequestMeta([]byte(
		`{"jsonrpc":"2.0","id":"1000","method":"ping"}`,
	)))
	if numericExponent != "" {
		t.Errorf("exponent id digest = %q, want empty", numericExponent)
	}
	if numericDecimal == stringID {
		t.Errorf("numeric and string ids collide at %q", numericDecimal)
	}
	if len(numericDecimal) != sha256.Size || len(stringID) != sha256.Size {
		t.Errorf("request id digests must stay fixed at %d bytes", sha256.Size)
	}
}

func TestHandleFrame_AggregateRequestBudgetFailsClosed(t *testing.T) {
	state := serveState{
		inflight:      make(map[string]*inflightRequest),
		inflightBytes: maxInflightRequestBytes,
		requestTokens: make(map[string]string),
	}
	var output bytes.Buffer
	err := (&bridge{}).handleFrame(
		frameRead{line: []byte(`{"jsonrpc":"2.0","id":"over-budget","method":"ping"}`)},
		&output,
		&state,
		nil,
		nil,
	)
	if err != nil {
		t.Fatalf("handleFrame: %v", err)
	}
	if got := output.String(); !strings.Contains(got, `"id":"over-budget"`) ||
		!strings.Contains(got, "in-flight request byte limit reached") {
		t.Fatalf("budget response = %q", got)
	}
	if len(state.inflight) != 0 || state.inflightBytes != maxInflightRequestBytes {
		t.Fatal("over-budget request changed admission state")
	}

	output.Reset()
	err = (&bridge{}).handleFrame(
		frameRead{line: []byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)},
		&output,
		&state,
		nil,
		nil,
	)
	if err != nil {
		t.Fatalf("handle notification: %v", err)
	}
	if output.Len() != 0 {
		t.Errorf("over-budget notification must remain silent, got %q", output.String())
	}
}

func TestHandleFrame_CancellationBypassesAggregateRequestBudget(t *testing.T) {
	requestFrame := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)
	requestMeta := parseRequestMeta(requestFrame)
	idKey := requestIDKey(requestMeta)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	state := serveState{
		inflight: map[string]*inflightRequest{
			"request-token": {
				meta:       requestMeta,
				idKey:      idKey,
				frameBytes: maxInflightRequestBytes,
				cancel:     cancel,
			},
		},
		inflightBytes: maxInflightRequestBytes,
		requestTokens: map[string]string{idKey: "request-token"},
	}
	cancelResults := make(chan struct{}, 1)
	b := &bridge{
		endpoint:     "https://example.test/api/mcp/rpc",
		apiKey:       "key",
		userAgent:    "test",
		processNonce: "session",
		client: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusAccepted,
				Header:     make(http.Header),
				Body:       io.NopCloser(strings.NewReader("")),
			}, nil
		})},
	}
	cancellation := []byte(
		`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}`,
	)
	var output bytes.Buffer
	if err := b.handleFrame(
		frameRead{line: cancellation},
		&output,
		&state,
		nil,
		cancelResults,
	); err != nil {
		t.Fatalf("handleFrame: %v", err)
	}
	select {
	case <-cancelResults:
	case <-time.After(time.Second):
		t.Fatal("cancellation was blocked by the aggregate byte budget")
	}
	if output.Len() != 0 {
		t.Errorf("cancellation must remain silent, got %q", output.String())
	}
	request := state.inflight["request-token"]
	if !request.cancelled || !request.cancellationForwarded {
		t.Fatal("target request was not cancelled and forwarded")
	}
	select {
	case <-ctx.Done():
	default:
		t.Fatal("target request context was not cancelled")
	}
}

func TestHandleFrame_AggregateRequestBytesAreReleasedOnCompletion(t *testing.T) {
	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}`)
	initialBytes := maxInflightRequestBytes - len(frame)
	state := serveState{
		inflight:      make(map[string]*inflightRequest),
		inflightBytes: initialBytes,
		requestTokens: make(map[string]string),
	}
	results := make(chan forwardResult, 1)
	b := &bridge{
		endpoint:     "https://example.test/api/mcp/rpc",
		apiKey:       "key",
		userAgent:    "test",
		processNonce: "session",
		client: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":1,"result":{}}`)),
			}, nil
		})},
	}
	if err := b.handleFrame(frameRead{line: frame}, io.Discard, &state, results, nil); err != nil {
		t.Fatalf("handleFrame: %v", err)
	}
	if state.inflightBytes != maxInflightRequestBytes {
		t.Fatalf("admitted bytes = %d, want exact budget %d", state.inflightBytes, maxInflightRequestBytes)
	}

	result := <-results
	if request := state.completeRequest(result.token); request == nil {
		t.Fatal("completed request was not tracked")
	}
	if state.inflightBytes != initialBytes {
		t.Errorf("bytes after completion = %d, want %d", state.inflightBytes, initialBytes)
	}
}

func TestCancellationTargetKey_DistinguishesTypedIDs(t *testing.T) {
	numeric := cancellationTargetKey([]byte(`{"params":{"requestId":7}}`))
	stringID := cancellationTargetKey([]byte(`{"params":{"requestId":"7"}}`))
	if numeric == "" || stringID == "" {
		t.Fatalf("cancellation keys must be present: numeric=%q string=%q", numeric, stringID)
	}
	if numeric == stringID {
		t.Errorf("numeric and string cancellation ids collide at %q", numeric)
	}
	if got := cancellationTargetKey([]byte(`{"params":{"requestId":null}}`)); got != "" {
		t.Errorf("null cancellation id key = %q, want empty", got)
	}
}

func TestCancellationTargetKeyUsesExactUnambiguousFields(t *testing.T) {
	numeric := cancellationTargetKey([]byte(`{"params":{"requestId":7}}`))
	if got := cancellationTargetKey([]byte(`{"params":{"requestId":7,"REQUESTID":"other"}}`)); got != numeric {
		t.Errorf("case alias changed cancellation target: got %q want %q", got, numeric)
	}
	for _, frame := range []string{
		`{"PARAMS":{"requestId":7}}`,
		`{"params":{"REQUESTID":7}}`,
		`{"params":{"requestId":7,"requestId":8}}`,
	} {
		if got := cancellationTargetKey([]byte(frame)); got != "" {
			t.Errorf("ambiguous/alias-only cancellation %s produced key %q", frame, got)
		}
	}
}

// a write failure to stdout is fatal: serve returns the write
// error (main then surfaces it and the process exits non-zero). A torn pipe to
// the client must not be silently swallowed.
func TestServe_WriteErrorIsFatal(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	err := b.serve(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`+"\n"), errWriter{})
	if err == nil {
		t.Fatal("a stdout write failure must be returned from serve, not swallowed")
	}
	if !errors.Is(err, errWrite) {
		t.Errorf("serve should return the underlying write error, got %v", err)
	}
}

func TestServe_WriteErrorCancelsOtherInflightRequests(t *testing.T) {
	blockedStarted := make(chan struct{})
	blockedCancelled := make(chan struct{})
	b := &bridge{
		endpoint:     "https://example.test/api/mcp/rpc",
		apiKey:       "key",
		userAgent:    "ua",
		processNonce: "session",
		client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			body, _ := io.ReadAll(req.Body)
			var request struct {
				ID int `json:"id"`
			}
			_ = json.Unmarshal(body, &request)
			if request.ID == 1 {
				close(blockedStarted)
				<-req.Context().Done()
				close(blockedCancelled)
				return nil, req.Context().Err()
			}
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body:       io.NopCloser(strings.NewReader(`{"jsonrpc":"2.0","id":2,"result":{}}`)),
			}, nil
		})},
	}

	input := strings.NewReader(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call"}` + "\n" +
			`{"jsonrpc":"2.0","id":2,"method":"ping"}` + "\n",
	)
	err := b.serve(input, errWriter{})
	if !errors.Is(err, errWrite) {
		t.Fatalf("serve error = %v, want write failure", err)
	}
	<-blockedStarted
	<-blockedCancelled
}

func TestServe_ReadErrorCancelsInflightRequestsWithoutDraining(t *testing.T) {
	readFailure := errors.New("stdin failed")
	requestStarted := make(chan struct{})
	requestCancelled := make(chan struct{})
	b := &bridge{
		endpoint:     "https://example.test/api/mcp/rpc",
		apiKey:       "key",
		userAgent:    "ua",
		processNonce: "session",
		client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			close(requestStarted)
			<-req.Context().Done()
			close(requestCancelled)
			return nil, req.Context().Err()
		})},
	}
	input := io.MultiReader(
		strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`+"\n"),
		iotest.ErrReader(readFailure),
	)

	if err := b.serve(input, io.Discard); !errors.Is(err, readFailure) {
		t.Fatalf("serve error = %v, want stdin failure", err)
	}
	<-requestStarted
	<-requestCancelled
}

func TestWriteFrame_RejectsShortWriteAndNormalizesDelimiter(t *testing.T) {
	if err := writeFrame(shortWriter{}, []byte(`{"jsonrpc":"2.0"}`)); !errors.Is(err, io.ErrShortWrite) {
		t.Fatalf("short write error = %v, want io.ErrShortWrite", err)
	}

	var out bytes.Buffer
	if err := writeFrame(&out, []byte("{}\r\n\n")); err != nil {
		t.Fatalf("writeFrame: %v", err)
	}
	if got := out.String(); got != "{}\n" {
		t.Errorf("writeFrame output = %q, want exactly one newline", got)
	}
}

// EOF on stdin is a clean exit: serve returns nil (io.EOF mapped to
// a graceful return) when input ends without a terminating newline.
func TestServe_EOFWithoutNewlineExitsClean(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	var out bytes.Buffer
	// No trailing newline — the final frame still forwards, then EOF → nil.
	if err := b.serve(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`), &out); err != nil {
		t.Fatalf("EOF should be a clean (nil) exit, got %v", err)
	}
	if !strings.Contains(out.String(), `"result":"ok"`) {
		t.Errorf("the last unterminated frame should still be forwarded, got %q", out.String())
	}
}

// bare blank / whitespace-only lines forward nothing; a real frame
// after them is still relayed. (serve trims each line and skips empties.)
func TestServe_BlankAndWhitespaceLinesAreNoOps(t *testing.T) {
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	in := strings.NewReader("\n" + "   \n" + "\t \n" + `{"jsonrpc":"2.0","id":1,"method":"ping"}` + "\n")
	var out bytes.Buffer
	if err := b.serve(in, &out); err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("serve: %v", err)
	}
	if hits != 1 {
		t.Errorf("only the real frame should be forwarded, got %d POSTs", hits)
	}
	if !strings.Contains(out.String(), `"result":"ok"`) {
		t.Errorf("the real frame after blank lines was not relayed: %q", out.String())
	}
}

// An unknown tool is still portal-owned semantics: the bridge forwards the
// valid envelope verbatim and relays the portal's response.
func TestServe_RelaysFramesVerbatimWithoutProtocolLogic(t *testing.T) {
	frame := " \t" + `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"totally_made_up_tool","arguments":{}}}` + "  "
	var gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		gotBody = string(body)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"portal-decides"}`))
	}))
	defer srv.Close()

	var out bytes.Buffer
	if err := newTestBridge(srv).serve(strings.NewReader(frame+"\n"), &out); err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("serve: %v", err)
	}
	if gotBody != frame {
		t.Errorf("frame not forwarded verbatim:\n sent %q\n  got %q", frame, gotBody)
	}
	if !strings.Contains(out.String(), "portal-decides") {
		t.Errorf("bridge should relay the portal response untouched, got %q", out.String())
	}
}

func TestServe_MalformedEnvelopeIsRejectedLocally(t *testing.T) {
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		hits++
	}))
	defer srv.Close()

	tests := []struct {
		name     string
		frame    string
		wantID   string
		wantCode int
	}{
		{"malformed JSON", `{not json`, `"id":null`, -32700},
		{"duplicate root key", `{"jsonrpc":"2.0","id":7,"id":8,"method":"ping"}`, `"id":null`, -32700},
		{"duplicate nested key", `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_action","arguments":{"args":{"x":1,"x":2}}}}`, `"id":null`, -32700},
		{"invalid UTF-8", "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"\xff\"}", `"id":null`, -32700},
		{"leading vertical tab", "\v" + `{"jsonrpc":"2.0","id":7,"method":"ping"}`, `"id":null`, -32700},
		{"trailing form feed", `{"jsonrpc":"2.0","id":7,"method":"ping"}` + "\f", `"id":null`, -32700},
		{"leading nonbreaking space", "\u00a0" + `{"jsonrpc":"2.0","id":7,"method":"ping"}`, `"id":null`, -32700},
		{"trailing JSON value", `{"jsonrpc":"2.0","id":7,"method":"ping"} {}`, `"id":null`, -32700},
		{"null id", `{"jsonrpc":"2.0","id":null,"method":"ping"}`, `"id":null`, -32600},
		{"fractional id", `{"jsonrpc":"2.0","id":1.5,"method":"ping"}`, `"id":null`, -32600},
		{"missing method", `{"jsonrpc":"2.0","id":7}`, `"id":7`, -32600},
		{"null method", `{"jsonrpc":"2.0","id":8,"method":null}`, `"id":8`, -32600},
		{"non-string method", `{"jsonrpc":"2.0","id":"method","method":7}`, `"id":"method"`, -32600},
		{"wrong version", `{"jsonrpc":"1.0","id":9,"method":"ping"}`, `"id":9`, -32600},
		{
			"oversized string id",
			fmt.Sprintf(`{"jsonrpc":"2.0","id":"%s","method":"ping"}`, strings.Repeat("i", maxRequestIDBytes+1)),
			`"id":null`,
			-32600,
		},
		{
			"oversized integer id",
			fmt.Sprintf(`{"jsonrpc":"2.0","id":%s,"method":"ping"}`, strings.Repeat("9", maxRequestIDBytes+1)),
			`"id":null`,
			-32600,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			if err := newTestBridge(srv).serve(strings.NewReader(tc.frame+"\n"), &out); err != nil {
				t.Fatalf("serve: %v", err)
			}
			if !strings.Contains(out.String(), tc.wantID) ||
				!strings.Contains(out.String(), fmt.Sprintf(`"code":%d`, tc.wantCode)) {
				t.Errorf("invalid envelope response = %q", out.String())
			}
			if out.Len() > maxResponseBytes {
				t.Errorf("invalid envelope response is %d bytes, limit is %d", out.Len(), maxResponseBytes)
			}
		})
	}
	if hits != 0 {
		t.Errorf("invalid envelopes must not reach the portal, got %d POSTs", hits)
	}
}

// -- readFrameLine / readCappedBody: bounds at the real constants --

// a long newline-free chunk that is UNDER the frame cap but spans
// several of bufio.Reader's internal buffer fills (ErrBufferFull) is accumulated
// in full and forwarded — the drain loop keeps appending, it does not stop early
// or spuriously flag oversize.
func TestReadFrameLine_BufferFullKeepsAccumulating(t *testing.T) {
	// Reader buffer is 4 KiB here; the line is ~50 KiB → many ErrBufferFull cycles,
	// still well under maxFrameBytes.
	const n = 50 * 1024
	line := strings.Repeat("a", n)
	br := bufio.NewReaderSize(strings.NewReader(line+"\n"), 4*1024)

	got, oversize, err := readFrameLine(br)
	if err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("unexpected err: %v", err)
	}
	if oversize {
		t.Fatal("a sub-cap line must not be flagged oversize despite spanning buffer fills")
	}
	if len(bytes.TrimRight(got, "\n")) != n {
		t.Errorf("accumulated %d bytes, want %d (drain stopped early)", len(bytes.TrimRight(got, "\n")), n)
	}
}

// readCappedBody at the REAL maxResponseBytes: a body of exactly
// the limit is returned in full; one byte over is an error. (TestReadCappedBody
// pins the logic with a small limit; this pins it at the production constant.)
func TestReadCappedBody_AtMaxResponseBytesBoundary(t *testing.T) {
	exact := bytes.Repeat([]byte("z"), maxResponseBytes)
	if got, err := readCappedBody(bytes.NewReader(exact), maxResponseBytes); err != nil {
		t.Fatalf("a body of exactly maxResponseBytes should be allowed: %v", err)
	} else if len(got) != maxResponseBytes {
		t.Errorf("got %d bytes, want %d", len(got), maxResponseBytes)
	}

	over := bytes.Repeat([]byte("z"), maxResponseBytes+1)
	if _, err := readCappedBody(bytes.NewReader(over), maxResponseBytes); err == nil {
		t.Fatal("a body one byte over maxResponseBytes must error")
	}
}

// an unbounded hostile response stream is bounded by readCappedBody
// (io.LimitReader): forward errors out (→ -32603 in serve) instead of consuming
// memory without limit. We model the infinite stream with an endless reader and
// assert forward returns the capped-body error rather than reading forever.
func TestForward_UnboundedResponseStreamIsBounded(t *testing.T) {
	// A handler that writes far more than maxResponseBytes. We don't write a true
	// infinite stream (the httptest server would block on the closed client side
	// once forward gives up); maxResponseBytes+4 KiB is enough to trip the cap.
	over := bytes.Repeat([]byte("z"), maxResponseBytes+4096)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(over)
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	_, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`))
	if err == nil {
		t.Fatal("an over-cap response stream must error (bounded), not be relayed")
	}
	if !strings.Contains(err.Error(), "exceeds") {
		t.Errorf("expected a capped-body error, got %v", err)
	}
}

// the transport bounds are fixed in code, not operator-tunable:
// there is intentionally NO env override for the request timeout, the response
// cap, or the inbound-frame cap (a hostile launcher config can't widen them to
// hang the bridge or lift the OOM guard). Pin the exact values so a change is a
// deliberate, reviewed edit to the constants.
func TestTransportConstantsAreFixed(t *testing.T) {
	if httpTimeout != 90*time.Second {
		t.Errorf("httpTimeout = %v, want 90s", httpTimeout)
	}
	if maxResponseBytes != 512<<10 {
		t.Errorf("maxResponseBytes = %d, want 512 KiB", maxResponseBytes)
	}
	if maxFrameBytes != 128<<10 {
		t.Errorf("maxFrameBytes = %d, want 128 KiB", maxFrameBytes)
	}
	if maxInflightRequestBytes != maxConcurrentRequests*maxFrameBytes {
		t.Errorf("maxInflightRequestBytes = %d, want %d", maxInflightRequestBytes, maxConcurrentRequests*maxFrameBytes)
	}
}

func TestForward_ContextCancellationStopsTransport(t *testing.T) {
	started := make(chan struct{})
	var attempts atomic.Int32
	b := &bridge{
		endpoint:  "https://example.test/api/mcp/rpc",
		apiKey:    "k",
		userAgent: "ua",
		client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			attempts.Add(1)
			close(started)
			<-req.Context().Done()
			return nil, req.Context().Err()
		})},
		processNonce: "sess",
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := b.forwardRequestContext(
			ctx,
			[]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`),
			parseRequestMeta([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)),
			requestHeaders{},
		)
		done <- err
	}()
	<-started
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("forward error = %v, want context.Canceled", err)
	}
	if attempts.Load() != 1 {
		t.Fatalf("cancelled mutation was retried %d times", attempts.Load())
	}
}

// -- helpers --------------------------------------------------------

var errWrite = errors.New("write failed")

// errWriter fails every Write — models a torn stdout pipe to the client.
type errWriter struct{}

func (errWriter) Write([]byte) (int, error) { return 0, errWrite }

type shortWriter struct{}

func (shortWriter) Write(p []byte) (int, error) { return len(p) - 1, nil }

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

type frameWriter struct {
	mu     sync.Mutex
	frames [][]byte
	writes chan []byte
}

func newFrameWriter() *frameWriter {
	return &frameWriter{writes: make(chan []byte, maxConcurrentRequests*4)}
}

func (w *frameWriter) Write(p []byte) (int, error) {
	frame := append([]byte(nil), p...)
	w.mu.Lock()
	w.frames = append(w.frames, frame)
	w.mu.Unlock()
	w.writes <- frame
	return len(p), nil
}

func (w *frameWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return string(bytes.Join(w.frames, nil))
}

func receiveFrame(t *testing.T, writes <-chan []byte) []byte {
	t.Helper()
	select {
	case frame := <-writes:
		return frame
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for bridge output")
		return nil
	}
}

func newTestBridge(srv *httptest.Server) *bridge {
	client := newHTTPClient()
	client.Transport = jsonPortalTransport{base: http.DefaultTransport}
	return &bridge{
		endpoint:     srv.URL,
		portalOrigin: srv.URL,
		apiKey:       "k",
		userAgent:    "ua",
		client:       client,
		processNonce: "sess",
	}
}

// net/http test servers infer text/plain for raw JSON writes, while the portal
// contract always declares application/json. Normalize that fixture default;
// dedicated content-type tests set an explicit non-default media type.
type jsonPortalTransport struct {
	base http.RoundTripper
}

func (t jsonPortalTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.base.RoundTrip(req)
	if err == nil && (resp.Header.Get("Content-Type") == "" || resp.Header.Get("Content-Type") == "text/plain; charset=utf-8") {
		resp.Header.Set("Content-Type", "application/json")
	}
	return resp, err
}

// -- parseClientMetadata: validated, canonical, fail-closed ---------

func TestParseClientMetadata_AcceptsAndCanonicalizes(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"unset", "", ""},
		{"whitespace only", "  \n ", ""},
		{"empty object", "{}", ""},
		{"single string value", `{"asset_tag":"LT-4417"}`, `{"asset_tag":"LT-4417"}`},
		{"keys canonicalized (sorted)", `{"b":"2","a":"1"}`, `{"a":"1","b":"2"}`},
		{"integer value preserved", `{"port":8080}`, `{"port":8080}`},
		{"finite float accepted", `{"ratio":1e308}`, `{"ratio":1e308}`},
		{"float underflow matches portal", `{"ratio":1e-400}`, `{"ratio":1e-400}`},
		{"reformatted to canonical", "{\n  \"asset_tag\" : \"x\"\n}", `{"asset_tag":"x"}`},
		{"max keys allowed", tenKeyObject(), tenKeyObject()},
		{"arbitrary key names allowed", `{"role":"admin","password":"x"}`, `{"password":"x","role":"admin"}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseClientMetadata(c.in)
			if err != nil {
				t.Fatalf("parseClientMetadata(%q) error: %v", c.in, err)
			}
			if got != c.want {
				t.Errorf("parseClientMetadata(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

func TestParseClientMetadata_FailsClosed(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"not json", "not json", "must be a JSON object"},
		{"top-level array", `["a"]`, "must be a JSON object"},
		{"top-level string", `"x"`, "must be a JSON object"},
		{"top-level number", `5`, "must be a JSON object"},
		{"top-level null", `null`, "must be a non-null JSON object"},
		{"trailing data", `{"a":"1"} {"b":"2"}`, "single JSON object"},
		{"trailing array", `{"a":"1"} []`, "single JSON object"},
		{"trailing scalar", `{"a":"1"} true`, "single JSON object"},
		{"trailing garbage", `{"a":"1"} nope`, "single JSON object"},
		{"too many keys", elevenKeyObject(), "the maximum is 10"},
		{"key too long", `{"` + strings.Repeat("k", 129) + `":"v"}`, "exceeds 128 characters"},
		{"string value too long", `{"a":"` + strings.Repeat("v", 513) + `"}`, "exceeds 512 characters"},
		{"array value", `{"a":["x"]}`, "must be a string or number"},
		{"object value", `{"a":{"b":"c"}}`, "must be a string or number"},
		{"bool value", `{"a":true}`, "must be a string or number"},
		{"null value", `{"a":null}`, "must be a string or number"},
		{"float overflow", `{"a":1e309}`, "numeric range"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseClientMetadata(c.in)
			if err == nil {
				t.Fatalf("parseClientMetadata(%q) = %q, want an error", c.in, got)
			}
			if got != "" {
				t.Errorf("a failed parse must return no metadata, got %q", got)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("error = %q, want it to contain %q", err.Error(), c.want)
			}
		})
	}
}

// A number rendered to exactly 512 chars is accepted; one longer is rejected —
// the limit is measured on the string representation, matching the portal.
func TestParseClientMetadata_ValueLengthBoundary(t *testing.T) {
	ok := `{"a":"` + strings.Repeat("v", 512) + `"}`
	if _, err := parseClientMetadata(ok); err != nil {
		t.Errorf("a 512-char value should be accepted, got %v", err)
	}
	tooLong := `{"a":"` + strings.Repeat("v", 513) + `"}`
	if _, err := parseClientMetadata(tooLong); err == nil {
		t.Error("a 513-char value should be rejected")
	}
}

func TestForward_SetsClientMetadataHeaderWhenConfigured(t *testing.T) {
	var got string
	var present bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get(clientMetadataHeader)
		_, present = r.Header[clientMetadataHeader]
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	b.clientMetadata = `{"asset_tag":"LT-4417"}`
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if !present {
		t.Fatal("configured metadata should set the header")
	}
	if got != `{"asset_tag":"LT-4417"}` {
		t.Errorf("%s = %q, want the canonical metadata", clientMetadataHeader, got)
	}
}

func TestForward_OmitsClientMetadataHeaderWhenUnset(t *testing.T) {
	var present bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, present = r.Header[clientMetadataHeader]
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv) // clientMetadata is ""
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if present {
		t.Error("unconfigured metadata must not set the header")
	}
}

func tenKeyObject() string {
	pairs := make([]string, 10)
	for i := range pairs {
		pairs[i] = `"k` + string(rune('0'+i)) + `":"v"`
	}
	return "{" + strings.Join(pairs, ",") + "}"
}

func elevenKeyObject() string {
	pairs := make([]string, 11)
	for i := range pairs {
		pairs[i] = `"k` + string(rune('a'+i)) + `":"v"`
	}
	return "{" + strings.Join(pairs, ",") + "}"
}
