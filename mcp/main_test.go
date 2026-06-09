package main

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
	"time"
)

// The bridge is a thin stdio↔HTTP shim. Its only jobs are:
//   1. POST each JSON-RPC frame to the portal's /api/mcp/rpc endpoint.
//   2. Forward the response back to stdout.
//   3. Mint a stable per-(session, JSON-RPC-id) idempotency key so a
//      transport retry collapses to one run at the cloud.
//
// All MCP-protocol semantics (renderRunBlocks, wait_for_run,
// pending-approval messages) now live in the portal, so the tests here
// only pin the proxy contract, not any tool-output formatting.

// -- idempotencyKey: parses `id` out of a raw JSON-RPC frame ---------

func TestIdempotencyKey_StableForSameID(t *testing.T) {
	b := &bridge{sessionID: "deadbeef"}
	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)
	want := "deadbeef:1"
	if got := b.idempotencyKey(frame); got != want {
		t.Fatalf("key = %q, want %q", got, want)
	}
	if a, c := b.idempotencyKey(frame), b.idempotencyKey(frame); a != c {
		t.Errorf("same frame should yield same key: %q vs %q", a, c)
	}
}

func TestIdempotencyKey_DiffersByID(t *testing.T) {
	b := &bridge{sessionID: "deadbeef"}
	a := b.idempotencyKey([]byte(`{"jsonrpc":"2.0","id":1}`))
	c := b.idempotencyKey([]byte(`{"jsonrpc":"2.0","id":2}`))
	if a == c {
		t.Errorf("distinct ids must not collide: both %q", a)
	}
}

func TestIdempotencyKey_EmptyForNotification(t *testing.T) {
	b := &bridge{sessionID: "deadbeef"}
	// Notification (no id field) — must yield empty key so the cloud
	// treats it as fire-and-forget instead of a dedupable run.
	if got := b.idempotencyKey([]byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)); got != "" {
		t.Errorf("missing id should yield empty key, got %q", got)
	}
	if got := b.idempotencyKey([]byte(`{"jsonrpc":"2.0","id":null}`)); got != "" {
		t.Errorf("null id should yield empty key, got %q", got)
	}
}

func TestIdempotencyKey_NormalizesStringID(t *testing.T) {
	b := &bridge{sessionID: "s"}
	if got := b.idempotencyKey([]byte(`{"jsonrpc":"2.0","id":"7"}`)); got != "s:7" {
		t.Errorf("string id should strip quotes: got %q, want %q", got, "s:7")
	}
}

func TestNewSessionID_UniquePerProcess(t *testing.T) {
	if newSessionID() == newSessionID() {
		t.Error("two session ids collided — nonce isn't random")
	}
}

// -- forward: HTTP plumbing -----------------------------------------

func TestForward_SetsAuthAndUserAgentAndIdempotencyHeaders(t *testing.T) {
	var gotAuth, gotUA, gotIdem string
	var hadIdem bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotUA = r.Header.Get("User-Agent")
		gotIdem = r.Header.Get("Idempotency-Key")
		_, hadIdem = r.Header["Idempotency-Key"]
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)

	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)
	if _, err := b.forward(frame); err != nil {
		t.Fatalf("forward: %v", err)
	}

	if gotAuth != "Bearer k" {
		t.Errorf("Authorization = %q, want %q", gotAuth, "Bearer k")
	}
	if gotUA != "ua" {
		t.Errorf("User-Agent = %q, want %q", gotUA, "ua")
	}
	if gotIdem != "sess:1" {
		t.Errorf("Idempotency-Key = %q, want %q", gotIdem, "sess:1")
	}
	if !hadIdem {
		t.Error("frame with id should set the Idempotency-Key header")
	}
}

func TestForward_SetsMcpSessionIDHeader(t *testing.T) {
	var gotSession string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotSession = r.Header.Get("Mcp-Session-Id")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"ok"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)

	// Every forwarded frame carries the per-process session id so the
	// portal can stamp it on the run + audit event. stdio clients can't
	// echo a server-issued Mcp-Session-Id, so the bridge supplies its own.
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if gotSession != "sess" {
		t.Errorf("Mcp-Session-Id = %q, want %q", gotSession, "sess")
	}
}

func TestForward_OmitsIdempotencyHeaderForNotifications(t *testing.T) {
	var hadIdem bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, hadIdem = r.Header["Idempotency-Key"]
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
	if hadIdem {
		t.Error("notifications must NOT set the Idempotency-Key header")
	}
}

func TestForward_5xxBecomesError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte("upstream down"))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	_, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1}`))
	if err == nil {
		t.Fatal("expected error on 5xx")
	}
	if !strings.Contains(err.Error(), "502") || !strings.Contains(err.Error(), "upstream down") {
		t.Errorf("error should name status + body, got %v", err)
	}
}

func TestForward_4xxIsReturnedVerbatim(t *testing.T) {
	// 4xx responses are JSON-RPC error frames shaped by the portal —
	// forward them as-is so the client sees the structured error.
	body := []byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"unauthorized"}}`)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	got, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1}`))
	if err != nil {
		t.Fatalf("4xx should not become an error: %v", err)
	}
	if !bytes.Equal(got, body) {
		t.Errorf("body = %q, want %q", got, body)
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

// -- helpers --------------------------------------------------------

func newTestBridge(srv *httptest.Server) *bridge {
	return &bridge{
		endpoint:  srv.URL,
		apiKey:    "k",
		userAgent: "ua",
		client:    &http.Client{Timeout: 5 * time.Second},
		sessionID: "sess",
	}
}
