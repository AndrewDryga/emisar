package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
	"testing/iotest"
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

func TestIdempotencyKey_KeysOffEnvelopeIDNotNested(t *testing.T) {
	b := &bridge{sessionID: "s"}

	// params (carrying its own "id"-ish content) serialized BEFORE the
	// envelope id. A naive first-"id" byte-scan would latch onto the nested
	// occurrence; the envelope id is the only correct key.
	frame := []byte(`{"method":"tools/call","params":{"arguments":{"id":"nested"}},"id":42}`)
	if got := b.idempotencyKey(frame); got != "s:42" {
		t.Errorf("must key off the envelope id: got %q, want %q", got, "s:42")
	}

	// A param value that is literally the string "id" must not be mistaken
	// for the (absent) envelope id of a notification.
	notif := []byte(`{"method":"tools/call","params":{"name":"id"}}`)
	if got := b.idempotencyKey(notif); got != "" {
		t.Errorf("notification with an \"id\" param value should yield no key, got %q", got)
	}

	// Malformed JSON yields no key (forwarded verbatim, just not deduped).
	if got := b.idempotencyKey([]byte(`{not json`)); got != "" {
		t.Errorf("malformed frame should yield no key, got %q", got)
	}
}

func TestCheckEndpointScheme(t *testing.T) {
	cases := []struct {
		base          string
		allowInsecure bool
		ok            bool
	}{
		{"https://emisar.dev", false, true},
		{"https://example.com:8443", false, true},
		{"http://localhost:4000", false, true},
		{"http://127.0.0.1:4000", false, true},
		{"http://[::1]:4000", false, true},
		{"http://emisar.dev", false, false},   // cleartext to public host → reject
		{"http://192.168.1.10", false, false}, // private LAN is still non-loopback
		{"http://emisar.dev", true, true},     // explicit override
		{"ws://emisar.dev", false, false},     // wrong scheme for an HTTP POST
		{"ftp://emisar.dev", false, false},    // nonsense scheme
		{"://bad", false, false},              // unparseable
	}
	for _, c := range cases {
		err := checkEndpointScheme(c.base, c.allowInsecure)
		if c.ok && err != nil {
			t.Errorf("%q (allowInsecure=%v): want ok, got %v", c.base, c.allowInsecure, err)
		}
		if !c.ok && err == nil {
			t.Errorf("%q (allowInsecure=%v): want error, got nil", c.base, c.allowInsecure)
		}
	}
}

func TestNewSessionID_UniquePerProcess(t *testing.T) {
	// Bind to vars so the comparison is two distinct evaluations, not a
	// syntactically-identical `f() == f()` (which static analysis flags as
	// a tautology even though the nonce makes the values differ).
	first, err := newSessionID(rand.Reader)
	if err != nil {
		t.Fatalf("newSessionID: %v", err)
	}
	second, err := newSessionID(rand.Reader)
	if err != nil {
		t.Fatalf("newSessionID: %v", err)
	}
	if first == second {
		t.Error("two session ids collided — nonce isn't random")
	}
}

// A rand read failure must fail closed (error), never fall back to a
// shared constant that would alias two processes' idempotency keys.
func TestNewSessionID_FailsClosedOnRandError(t *testing.T) {
	if _, err := newSessionID(iotest.ErrReader(errors.New("rand unavailable"))); err == nil {
		t.Error("newSessionID returned nil error on a failing reader — must fail closed")
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
	got, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1}`))
	if err != nil {
		t.Fatalf("forward: %v", err)
	}
	if targetHit {
		t.Fatal("redirect was followed — the Bearer API key would leak to the redirect target")
	}
	if strings.Contains(string(got), "leaked") {
		t.Errorf("got the redirect target's body, want the 3xx response: %q", got)
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

func TestServe_OversizedFrameKeepsServing(t *testing.T) {
	// An over-long frame must be rejected for that line ALONE — the session
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
		t.Error("the frame after an oversized one was not served — the session died")
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

// -- idempotencyKey: cross-process + odd ids ------------------------

// the session prefix namespaces idempotency keys across processes:
// two bridges with different session ids derive different keys for the same
// JSON-RPC id, so one process's id:1 never aliases another's run at the portal.
func TestIdempotencyKey_SessionPrefixNamespacesAcrossProcesses(t *testing.T) {
	a := (&bridge{sessionID: "aaaa"}).idempotencyKey([]byte(`{"jsonrpc":"2.0","id":1}`))
	b := (&bridge{sessionID: "bbbb"}).idempotencyKey([]byte(`{"jsonrpc":"2.0","id":1}`))
	if a == b {
		t.Fatalf("different sessions must not alias the same id: both %q", a)
	}
	if a != "aaaa:1" || b != "bbbb:1" {
		t.Fatalf("keys = %q, %q; want aaaa:1, bbbb:1", a, b)
	}
}

// large / odd-shaped ids decode safely. The envelope id is read as
// a RawMessage and only surrounding quotes are trimmed: a spaced id, a big int
// past 2^53, and a hyphen/underscore string id all produce a deterministic key
// with no panic and no precision loss (a float-parse of the big int would mangle
// it; RawMessage keeps the literal).
func TestIdempotencyKey_LargeAndOddIDs(t *testing.T) {
	b := &bridge{sessionID: "s"}
	cases := []struct {
		frame string
		want  string
	}{
		{`{"id": 1,"method":"tools/call"}`, "s:1"},                        // leading space before the value
		{`{"jsonrpc":"2.0","id":9007199254740993}`, "s:9007199254740993"}, // > 2^53, kept exact
		{`{"jsonrpc":"2.0","id":"a-b_c"}`, "s:a-b_c"},                     // string id, quotes stripped
		{`{"jsonrpc":"2.0","id":12.5}`, "s:12.5"},                         // float-ish literal, kept verbatim
	}
	for _, c := range cases {
		if got := b.idempotencyKey([]byte(c.frame)); got != c.want {
			t.Errorf("idempotencyKey(%s) = %q, want %q", c.frame, got, c.want)
		}
	}
}

// -- checkEndpointScheme: case-insensitive loopback -----------------

// the loopback allowance for cleartext http is case-insensitive on
// the host: http://LOCALHOST is accepted exactly like http://localhost
// (isLoopbackHost uses strings.EqualFold), so casing can't accidentally trip the
// cleartext refusal for a legit local dev endpoint.
func TestCheckEndpointScheme_LoopbackCaseInsensitive(t *testing.T) {
	for _, base := range []string{"http://LOCALHOST:4000", "http://LocalHost:4000", "http://localhost:4000"} {
		if err := checkEndpointScheme(base, false); err != nil {
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

// a 202 with a non-empty body still yields a nil body: the body is
// read (and capped) then dropped, because 202 means "notification accepted, no
// response" regardless of what the portal wrote.
func TestForward_202WithBodyStillDiscarded(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"should be dropped"}`))
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	body, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`))
	if err != nil {
		t.Fatalf("forward: %v", err)
	}
	if body != nil {
		t.Errorf("202 must yield a nil body even with content, got %q", body)
	}
}

// a stale/expired token produces a portal 4xx JSON-RPC error frame,
// which is relayed VERBATIM (not masked as a generic -32603). The bridge does no
// auth logic; the portal shapes the structured error and the client sees it whole.
func TestForward_ExpiredToken4xxRelayedVerbatim(t *testing.T) {
	errFrame := []byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"api key expired"}}`)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
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
// isolation here; the startup checkEndpointScheme would normally reject such a
// URL first.)
func TestForward_RequestBuildErrorSurfaced(t *testing.T) {
	b := &bridge{
		endpoint:  "http://example.com/\x7f", // invalid control char → NewRequest fails
		apiKey:    "k",
		userAgent: "ua",
		client:    newHTTPClient(),
		sessionID: "sess",
	}
	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err == nil {
		t.Fatal("a malformed endpoint should surface a request-build error")
	}
}

// / — on a 5xx, the client-facing JSON-RPC frame written
// to stdout is the GENERIC `upstream transport error` and never carries the
// secret-ish 5xx body or the API key. The detailed portal body goes to stderr
// only (not the LLM transcript). We assert the security-critical half: the
// stdout frame leaks neither the body nor the key.
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

// an OAuth `emo-*` bearer is carried identically to any other key:
// the bridge does no token-type logic, it just attaches `Authorization: Bearer
// <key>` verbatim.
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

// a non-JSON 200 body is relayed without validation: the bridge
// never asserts the response is well-formed JSON (all semantics are portal-side).
func TestForward_NonJSONResponseRelayedVerbatim(t *testing.T) {
	raw := []byte("this is not json at all <<>>")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(raw)
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	got, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`))
	if err != nil {
		t.Fatalf("forward should not validate the body: %v", err)
	}
	if !bytes.Equal(got, raw) {
		t.Errorf("non-JSON body not relayed verbatim:\n got %q\nwant %q", got, raw)
	}
}

// an empty 200 body is returned as an empty (non-nil-distinct)
// body; serve then writes nothing spurious for it.
func TestForward_Empty200BodyReturnedEmpty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK) // zero-length body
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	got, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`))
	if err != nil {
		t.Fatalf("forward: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("empty 200 should yield an empty body, got %q", got)
	}

	// And serve writes nothing for an empty 200 (len(resp)==0 branch).
	srv2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv2.Close()
	b2 := newTestBridge(srv2)
	var out bytes.Buffer
	_ = b2.serve(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`+"\n"), &out)
	if out.Len() != 0 {
		t.Errorf("an empty 200 body should produce no stdout, got %q", out.String())
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

// multiple frames over one session are relayed in input order, each
// newline-delimited. The portal echoes each request's id so we can assert order.
func TestServe_MultipleFramesRelayedInOrder(t *testing.T) {
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
	for i, want := range []string{`"id":1`, `"id":2`, `"id":3`} {
		if !strings.Contains(lines[i], want) {
			t.Errorf("response %d out of order: %q (want %s)", i, lines[i], want)
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

// / — a malformed (non-JSON) frame, and a frame naming an
// unknown/synthetic tool, are both POSTed VERBATIM. The bridge does no JSON-RPC
// validation and synthesizes no tool descriptors/content — every semantic is
// portal-side; it relays exactly the bytes it received (within the size cap).
func TestServe_RelaysFramesVerbatimWithoutProtocolLogic(t *testing.T) {
	for _, frame := range []string{
		`{not json but under the cap`,
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"totally_made_up_tool","arguments":{}}}`,
	} {
		var gotBody string
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			b, _ := io.ReadAll(r.Body)
			gotBody = string(b)
			_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"portal-decides"}`))
		}))

		b := newTestBridge(srv)
		var out bytes.Buffer
		if err := b.serve(strings.NewReader(frame+"\n"), &out); err != nil && !errors.Is(err, io.EOF) {
			srv.Close()
			t.Fatalf("serve: %v", err)
		}
		srv.Close()

		if gotBody != frame {
			t.Errorf("frame not forwarded verbatim:\n sent %q\n  got %q", frame, gotBody)
		}
		// The bridge synthesized nothing of its own — the response is purely what
		// the portal returned.
		if !strings.Contains(out.String(), "portal-decides") {
			t.Errorf("bridge should relay the portal response untouched, got %q", out.String())
		}
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
	if httpTimeout != 120*time.Second {
		t.Errorf("httpTimeout = %v, want 120s", httpTimeout)
	}
	if maxResponseBytes != 32*1024*1024 {
		t.Errorf("maxResponseBytes = %d, want 32 MiB", maxResponseBytes)
	}
	if maxFrameBytes != 16*1024*1024 {
		t.Errorf("maxFrameBytes = %d, want 16 MiB", maxFrameBytes)
	}
}

// a stalled portal that never responds is bounded by the client
// timeout: client.Do returns a timeout error, forward surfaces it, and serve
// maps it to a synthetic -32603 rather than hanging forever. We exercise the
// MECHANISM with a short-timeout client against a handler that blocks until the
// client gives up (the production cap is 120s, asserted separately by
// TestTransportConstantsAreFixed — we don't wait two minutes here).
func TestForward_ClientTimeoutBecomesError(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		// Block until the client disconnects (its timeout fires) or the test
		// tears the server down — never write a response.
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer srv.Close()
	defer close(release)

	b := newTestBridge(srv)
	b.client = &http.Client{
		Timeout:       50 * time.Millisecond,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}

	if _, err := b.forward([]byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`)); err == nil {
		t.Fatal("a stalled portal past the client timeout must surface an error")
	}

	// And serve maps that transport timeout to a -32603 frame (loop survives).
	var out bytes.Buffer
	_ = b.serve(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/call"}`+"\n"), &out)
	if !strings.Contains(out.String(), "-32603") || !strings.Contains(out.String(), "upstream transport error") {
		t.Errorf("a timed-out forward should yield a generic -32603 frame, got %q", out.String())
	}
}

// -- helpers --------------------------------------------------------

var errWrite = errors.New("write failed")

// errWriter fails every Write — models a torn stdout pipe to the client.
type errWriter struct{}

func (errWriter) Write([]byte) (int, error) { return 0, errWrite }

func newTestBridge(srv *httptest.Server) *bridge {
	return &bridge{
		endpoint:  srv.URL,
		apiKey:    "k",
		userAgent: "ua",
		client:    newHTTPClient(),
		sessionID: "sess",
	}
}
