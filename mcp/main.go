// Command emisar-mcp is a thin stdio↔HTTP shim for MCP-aware clients
// (Claude Desktop, Cursor, Claude Code, Gemini CLI, Codex CLI, …) that
// only speak stdio JSON-RPC.
//
// The bridge owns transport correctness: bounded newline framing, request-id
// correlation, Streamable HTTP headers, and validation that stdout contains
// only valid MCP messages. All tool descriptors, content blocks, and synthetic
// tools are produced by the portal. The one semantic exception is client-attested
// dispatch (sign.go): the bridge reads `tools/call` frames to attach an
// Ed25519 signature, because the signing key must stay client-side and
// never reach the control plane.
//
// Configure your client to launch:
//
//	{
//	  "mcpServers": {
//	    "emisar": {
//	      "command": "/usr/local/bin/emisar-mcp",
//	      "env": {
//	        "EMISAR_URL":     "https://emisar.dev",
//	        "EMISAR_API_KEY": "emk-..."
//	      }
//	    }
//	  }
//	}
//
// If your client speaks MCP-over-HTTP natively (Claude / ChatGPT
// cloud connectors, recent Cursor / Continue / Zed), skip the bridge
// entirely and point them straight at `${EMISAR_URL}/api/mcp/rpc`
// with the same Bearer token.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const bridgeName = "emisar-mcp"

// The portal permits wait_for_run to hold a request for five minutes. Keep 30
// seconds of bounded transport headroom so its graceful "still waiting"
// response wins the boundary race without allowing an indefinite connection.
const httpTimeout = 330 * time.Second

const (
	maxConcurrentRequests      = 8
	maxSessionRequestIDs       = 65_536
	cancellationForwardTimeout = 5 * time.Second
	requestTokenHeader         = "X-Emisar-MCP-Request-Token"
	cancelTokenHeader          = "X-Emisar-MCP-Cancel-Token"
)

// maxResponseBytes caps the portal response we'll buffer. The network is
// untrusted and http.Client.Timeout bounds time, not bytes — without a cap a
// hostile/MITM'd endpoint could stream gigabytes and OOM the bridge. Generous
// vs the largest legit MCP frame (a full tools/list catalog).
const maxResponseBytes = 32 * 1024 * 1024

// maxFrameBytes caps a single inbound JSON-RPC line. An over-long frame is
// rejected (the session kept alive), never allowed to kill the bridge.
const maxFrameBytes = 16 * 1024 * 1024

// Self-reported MCP client metadata: an operator-configured key/value map
// (EMISAR_CLIENT_METADATA, a JSON object) the bridge validates once at startup
// and forwards on every request so the portal can snapshot it onto MCP action
// runs for audit/SIEM correlation with the operator's own MDM/EDR/inventory. It
// is UNTRUSTED, self-reported enrichment — never an authorization, posture, or
// approval input — so the portal independently re-validates these same limits at
// its boundary (a direct HTTP caller or a modified bridge can send anything).
const (
	clientMetadataHeader   = "Emisar-Client-Metadata"
	maxClientMetadataKeys  = 10
	maxClientMetadataKey   = 128
	maxClientMetadataValue = 512
)

// newHTTPClient builds the bridge's HTTP client: a hard request timeout plus a
// redirect refusal — the RPC endpoint never legitimately redirects, and
// following a 3xx would chase the Bearer API key to an attacker-chosen host.
func newHTTPClient() *http.Client {
	return &http.Client{
		Timeout:       httpTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

// Version is the build version, stamped by `-ldflags "-X main.Version=..."`
// from the release pipeline; "dev" when built locally.
var Version = "dev"

const helpText = `emisar-mcp — MCP stdio↔HTTP shim for emisar

  Proxies MCP JSON-RPC requests from a local LLM client (Claude Desktop,
  Claude Code, Cursor, Gemini CLI, Codex CLI, …) into the emisar control
  plane's HTTP endpoint at POST /api/mcp/rpc. Every method (initialize,
  tools/list, tools/call, ping, notifications/…) is forwarded to the portal.
  The only protocol-aware exception is optional client-attested dispatch:
  tools/call arguments are signed locally because the private key must stay on
  the operator's machine.

Environment:
  EMISAR_URL        Base URL of the control plane (required)
                    e.g. https://emisar.dev
  EMISAR_API_KEY    Operator API key (required), e.g. emk-...
  EMISAR_CLIENT     Optional label that shows up in the audit log
                    (claude-desktop, cursor, codex, …). Defaults to
                    "unknown".
  EMISAR_CLIENT_METADATA
                    Optional self-reported client metadata as a JSON object of
                    string keys to string or number values, e.g.
                    {"asset_tag":"LT-4417","device_id":"…"}. Snapshotted onto
                    each MCP action run so you can correlate Emisar activity with
                    your own MDM/EDR/inventory in the audit log and SIEM export.
                    Limits: at most 10 keys, keys ≤128 and values ≤512
                    characters. It is UNTRUSTED, self-reported enrichment —
                    never used for authorization, posture, or approval. Invalid
                    metadata is a startup error.
  EMISAR_ALLOW_INSECURE
                    Set to 1 only to allow cleartext HTTP to a non-loopback
                    development endpoint. Loopback HTTP works without it;
                    production should use HTTPS.
  EMISAR_SIGNING_KEY     Optional Ed25519 private key (64-hex seed). When set
                         (with EMISAR_SIGNING_CERT), the bridge signs each
                         tools/call so runners that enforce signatures will run
                         it. Get the key+cert pair from 'emisar signing new-cert' (or
                         'emisar signing init') on the operator host. Keep this
                         secret — never put it on the control plane.
  EMISAR_SIGNING_CERT    The CA-signed certificate JSON that vouches for the
                         signing key (and its scope/validity). The bridge carries
                         it verbatim alongside the signature; the runner verifies
                         it against the trusted CA.

Key rotation:
  Before asking the portal to rotate an expiring API key, the bridge generates
  and durably stores a pending successor. The initialize request carries only
  its lookup prefix and SHA-256 digest. The bridge activates the successor only
  after the portal acknowledges that exact digest, and only after the promoted
  state is durable. State lives in one owner-only file per bootstrap prefix
  under <user-config-dir>/emisar/credentials/. Keep that directory persistent;
  without durable storage the bridge continues with the configured key but
  does not offer automatic rotation.

Flags:
  -h, --help        Print this help and exit
  -v, --version     Print version and exit

The bridge speaks JSON-RPC 2.0, line-delimited, on stdin/stdout.
Run it under an MCP-aware client, not directly in a terminal.
`

func main() {
	for _, a := range os.Args[1:] {
		switch a {
		case "-h", "--help":
			fmt.Fprint(os.Stdout, helpText)
			return
		case "-v", "--version":
			fmt.Fprintf(os.Stdout, "%s %s\n", bridgeName, Version)
			return
		default:
			fmt.Fprintf(os.Stderr, "unknown argument %q (try --help)\n", a)
			os.Exit(2)
		}
	}

	base := strings.TrimRight(os.Getenv("EMISAR_URL"), "/")
	apiKey := os.Getenv("EMISAR_API_KEY")

	if base == "" || apiKey == "" {
		fatalln("EMISAR_URL and EMISAR_API_KEY must both be set (try --help)")
	}

	// Fail closed on a cleartext URL to a non-loopback host: an http:// base
	// ships the Bearer API key (and every request) in plaintext, inviting
	// credential theft and MITM. Mirror the runner's cloud.allow_insecure
	// opt-in so a localhost dev endpoint still works.
	if err := checkEndpointScheme(base, os.Getenv("EMISAR_ALLOW_INSECURE") == "1"); err != nil {
		fatalln(err)
	}

	// Optional client-attested dispatch: when a signing key is configured, the
	// bridge signs each tools/call so an enforcing runner will run it. The
	// private key never leaves this process.
	sign, err := newSigner(os.Getenv("EMISAR_SIGNING_KEY"), os.Getenv("EMISAR_SIGNING_CERT"))
	if err != nil {
		fatalln(err)
	}

	// A durably promoted successor takes precedence over the bootstrap key in
	// the client's config, which may have expired since. A pending successor is
	// retried unchanged after a lost request, response, or process restart.
	bootstrap := keyPrefix(apiKey)
	var pendingKey string
	credentialStore, credsErr := newCredentialStore(bootstrap)
	if credsErr != nil {
		fmt.Fprintf(os.Stderr, "emisar-mcp: no user config dir (%v); automatic key rotation disabled\n", credsErr)
	} else {
		state, err := credentialStore.load(apiKey)
		if err != nil {
			fatalln("credential state:", err)
		}
		apiKey = state.Current
		pendingKey = state.Pending
	}

	// Self-reported client metadata: validated once at startup so a bad map is a
	// clear local error, never a partial snapshot on the control plane.
	clientMetadata, err := parseClientMetadata(os.Getenv("EMISAR_CLIENT_METADATA"))
	if err != nil {
		fatalln(err)
	}

	sessionID, err := newSessionID(rand.Reader)
	if err != nil {
		fatalln(err)
	}

	b := &bridge{
		endpoint:        base + "/api/mcp/rpc",
		apiKey:          apiKey,
		userAgent:       buildUserAgent(),
		client:          newHTTPClient(),
		sessionID:       sessionID,
		signer:          sign,
		clientMetadata:  clientMetadata,
		credentialStore: credentialStore,
		pendingKey:      pendingKey,
	}

	if err := b.serve(os.Stdin, os.Stdout); err != nil && !errors.Is(err, io.EOF) {
		fatalln("serve:", err)
	}
}

type bridge struct {
	endpoint  string
	apiKey    string
	userAgent string
	client    *http.Client
	stateMu   sync.RWMutex
	// sessionID identifies this bridge process. It doubles as the MCP
	// session id (sent as Mcp-Session-Id) and the namespace for
	// idempotency keys, so a session's runs correlate and any downstream
	// transport replay collapses to one run.
	sessionID string
	// signer, when set, attaches a client attestation to each tools/call so an
	// enforcing runner will run it. Nil = signing disabled.
	signer *signer
	// clientMetadata is the operator's self-reported client metadata as canonical
	// JSON, validated once at startup and forwarded verbatim in every request's
	// clientMetadataHeader; "" when unset. It is untrusted correlation enrichment
	// the portal re-validates and snapshots onto MCP action runs — never an authz
	// input.
	clientMetadata string
	// protocolVersion is the version negotiated by initialize. Streamable HTTP
	// requires clients to echo it on subsequent requests, but not on initialize.
	protocolVersion string
	credentialStore *credentialStore
	pendingKey      string
}

// serve has one scheduling goroutine and one stdout owner. HTTP work may finish
// out of order, while frames and goroutines remain bounded. Cancellation is
// handled before ordinary admission so a saturated session can still release a
// long-running request.
func (b *bridge) serve(r io.Reader, w io.Writer) error {
	frames := make(chan frameRead, 1)
	results := make(chan forwardResult, maxConcurrentRequests)
	cancelResults := make(chan struct{}, maxConcurrentRequests)
	readerDone := make(chan struct{})
	defer close(readerDone)

	go readFrames(r, frames, readerDone)

	state := serveState{
		inflight:      make(map[string]*inflightRequest, maxConcurrentRequests),
		requestTokens: make(map[string]string, maxConcurrentRequests),
		seenIDs:       make(map[string]struct{}),
	}

	for frames != nil || len(state.inflight) > 0 || state.cancelForwards > 0 {
		select {
		case frame := <-frames:
			if err := b.handleFrame(frame, w, &state, results, cancelResults); err != nil {
				cancelInflight(state.inflight)
				return err
			}
			if frame.err != nil {
				if !errors.Is(frame.err, io.EOF) {
					cancelInflight(state.inflight)
					return frame.err
				}
				frames = nil
			}

		case result := <-results:
			request := state.inflight[result.token]
			if request == nil {
				continue
			}
			delete(state.inflight, result.token)
			if request.idKey != "" && state.requestTokens[request.idKey] == result.token {
				delete(state.requestTokens, request.idKey)
			}
			if request.cancelled {
				continue
			}
			if err := writeForwardResult(w, request.meta, result.response, result.err); err != nil {
				cancelInflight(state.inflight)
				return err
			}

		case <-cancelResults:
			state.cancelForwards--
		}
	}

	return nil
}

type frameRead struct {
	line     []byte
	oversize bool
	err      error
}

type inflightRequest struct {
	meta                  requestMeta
	idKey                 string
	apiKey                string
	protocolVersion       string
	cancel                context.CancelFunc
	cancelled             bool
	cancellationForwarded bool
}

type forwardResult struct {
	token    string
	response []byte
	err      error
}

type requestHeaders struct {
	apiKey          string
	protocolVersion string
	requestToken    string
	cancelToken     string
}

type serveState struct {
	inflight       map[string]*inflightRequest
	requestTokens  map[string]string
	seenIDs        map[string]struct{}
	sequence       uint64
	cancelForwards int
}

func readFrames(r io.Reader, frames chan<- frameRead, done <-chan struct{}) {
	reader := bufio.NewReaderSize(r, 64*1024)
	for {
		raw, oversize, err := readFrameLine(reader)
		frame := frameRead{line: bytes.TrimSpace(raw), oversize: oversize, err: err}
		select {
		case frames <- frame:
		case <-done:
			return
		}
		if err != nil {
			return
		}
	}
}

func (b *bridge) handleFrame(
	frame frameRead,
	w io.Writer,
	state *serveState,
	results chan<- forwardResult,
	cancelResults chan<- struct{},
) error {
	if frame.oversize {
		fmt.Fprintf(os.Stderr, "emisar-mcp: dropping a request frame over %d bytes\n", maxFrameBytes)
		return writeFrame(w, rpcErrorFrame(requestMeta{}, -32600, "request frame too large"))
	}
	if len(frame.line) == 0 {
		return nil
	}

	meta := parseRequestMeta(frame.line)
	if !meta.valid {
		return writeFrame(w, rpcErrorFrame(meta, -32600, "invalid request"))
	}
	if meta.notification() && meta.method == "notifications/cancelled" {
		b.handleCancellation(frame.line, meta, state, cancelResults)
		return nil
	}

	idKey := requestIDKey(meta)
	if idKey != "" {
		if _, used := state.seenIDs[idKey]; used {
			return writeFrame(w, rpcErrorFrame(meta, -32600, "request id was already used in this session"))
		}
		if len(state.seenIDs) >= maxSessionRequestIDs {
			return writeFrame(w, rpcErrorFrame(meta, -32000, "session request id limit reached"))
		}
	}
	if len(state.inflight) >= maxConcurrentRequests {
		if meta.notification() {
			return nil
		}
		return writeFrame(w, rpcErrorFrame(meta, -32000, "too many in-flight requests"))
	}

	state.sequence++
	token := fmt.Sprintf("%s-%x", b.sessionID, state.sequence)
	ctx, cancel := context.WithCancel(context.Background())
	apiKey, protocolVersion := b.transportState()
	state.inflight[token] = &inflightRequest{
		meta:            meta,
		idKey:           idKey,
		apiKey:          apiKey,
		protocolVersion: protocolVersion,
		cancel:          cancel,
	}
	if idKey != "" {
		state.requestTokens[idKey] = token
		state.seenIDs[idKey] = struct{}{}
	}

	headers := requestHeaders{apiKey: apiKey, protocolVersion: protocolVersion}
	if idKey != "" {
		headers.requestToken = token
	}
	go func() {
		response, err := b.forwardRequestContext(ctx, frame.line, meta, headers)
		cancel()
		results <- forwardResult{token: token, response: response, err: err}
	}()
	return nil
}

func (b *bridge) handleCancellation(
	frame []byte,
	meta requestMeta,
	state *serveState,
	cancelResults chan<- struct{},
) {
	idKey := cancellationTargetKey(frame)
	token := state.requestTokens[idKey]
	request := state.inflight[token]
	if request == nil || request.meta.method == "initialize" {
		return
	}

	request.cancelled = true
	request.cancel()
	if request.cancellationForwarded {
		return
	}
	request.cancellationForwarded = true
	state.cancelForwards++

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), cancellationForwardTimeout)
		defer cancel()
		_, _ = b.forwardRequestContext(ctx, frame, meta, requestHeaders{
			apiKey:          request.apiKey,
			protocolVersion: request.protocolVersion,
			cancelToken:     token,
		})
		cancelResults <- struct{}{}
	}()
}

func requestIDKey(meta requestMeta) string {
	if !meta.valid || !meta.hasID {
		return ""
	}
	if meta.idKind == 's' {
		var id string
		if json.Unmarshal(meta.id, &id) == nil {
			return digestRequestID("s:" + id)
		}
		return ""
	}
	if meta.idKind == 'n' {
		id, ok := new(big.Rat).SetString(string(meta.id))
		if ok {
			return digestRequestID("n:" + id.RatString())
		}
	}
	return ""
}

func digestRequestID(canonical string) string {
	digest := sha256.Sum256([]byte(canonical))
	return string(digest[:])
}

func cancellationTargetKey(frame []byte) string {
	var notification struct {
		Params struct {
			RequestID json.RawMessage `json:"requestId"`
		} `json:"params"`
	}
	if json.Unmarshal(frame, &notification) != nil {
		return ""
	}
	id := bytes.TrimSpace(notification.Params.RequestID)
	return requestIDKey(requestMeta{id: id, idKind: jsonRPCIDKind(id), hasID: true, valid: true})
}

func writeForwardResult(w io.Writer, meta requestMeta, response []byte, err error) error {
	if err != nil {
		if meta.notification() {
			return nil
		}
		return writeFrame(w, rpcErrorFrame(meta, -32603, "upstream transport error"))
	}
	if len(response) == 0 {
		return nil
	}
	return writeFrame(w, response)
}

func cancelInflight(inflight map[string]*inflightRequest) {
	for _, request := range inflight {
		request.cancel()
	}
}

type requestMeta struct {
	id     json.RawMessage
	idKind byte
	hasID  bool
	valid  bool
	method string
}

// parseRequestMeta reads only the transport metadata the bridge must own. The
// portal remains responsible for method and parameter validation.
func parseRequestMeta(frame []byte) requestMeta {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(frame, &envelope); err != nil || envelope == nil {
		return requestMeta{}
	}

	meta := requestMeta{valid: true}
	if rawMethod, ok := envelope["method"]; ok {
		_ = json.Unmarshal(rawMethod, &meta.method)
	}

	rawID, ok := envelope["id"]
	if !ok {
		return meta
	}
	meta.hasID = true
	meta.id = bytes.TrimSpace(rawID)
	meta.idKind = jsonRPCIDKind(meta.id)
	if meta.idKind == 0 || meta.idKind == '0' {
		meta.valid = false
	}
	return meta
}

func jsonRPCIDKind(id []byte) byte {
	if bytes.Equal(id, []byte("null")) {
		return '0'
	}
	var value any
	decoder := json.NewDecoder(bytes.NewReader(id))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return 0
	}
	switch value := value.(type) {
	case string:
		return 's'
	case json.Number:
		number, ok := new(big.Rat).SetString(value.String())
		if ok && number.IsInt() {
			return 'n'
		}
		return 0
	default:
		return 0
	}
}

func (m requestMeta) notification() bool {
	return m.valid && !m.hasID
}

func (m requestMeta) responseID() json.RawMessage {
	if m.valid && m.hasID {
		return m.id
	}
	return json.RawMessage("null")
}

func rpcErrorFrame(meta requestMeta, code int, message string) []byte {
	frame, err := json.Marshal(struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Error   struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}{
		JSONRPC: "2.0",
		ID:      meta.responseID(),
		Error: struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		}{Code: code, Message: message},
	})
	if err != nil {
		panic("marshal fixed JSON-RPC error: " + err.Error())
	}
	return frame
}

func writeFrame(w io.Writer, frame []byte) error {
	line := make([]byte, 0, len(frame)+1)
	line = append(line, bytes.TrimRight(frame, "\r\n")...)
	line = append(line, '\n')
	n, err := w.Write(line)
	if err != nil {
		return err
	}
	if n != len(line) {
		return io.ErrShortWrite
	}
	return nil
}

// readFrameLine reads one newline-delimited frame from br, bounding the bytes it
// retains to maxFrameBytes. bufio.Reader.ReadString would accumulate an entire
// newline-free stream into one slice before any length check — a hostile or
// malfunctioning client could OOM the bridge that way (the symmetric hole the
// response cap closes on the HTTP side). Instead we read in buffer-sized chunks;
// once a line crosses the cap we drop what we've accumulated and keep draining
// the rest of the (over-long) line to its terminating newline so the next frame
// still aligns, returning oversize=true. Peak retained bytes stay ≤ maxFrameBytes.
func readFrameLine(br *bufio.Reader) (line []byte, oversize bool, err error) {
	for {
		chunk, e := br.ReadSlice('\n')
		if !oversize {
			if len(line)+len(chunk) > maxFrameBytes {
				oversize = true
				line = nil // reject the frame; release what we'd buffered
			} else {
				line = append(line, chunk...)
			}
		}
		if e == bufio.ErrBufferFull {
			continue // line longer than br's buffer — keep draining it
		}
		return line, oversize, e
	}
}

// forward POSTs one JSON-RPC frame to the portal. It exists as a small test and
// call-site convenience; serve parses metadata once and calls forwardRequest.
func (b *bridge) forward(frame []byte) ([]byte, error) {
	return b.forwardRequest(frame, parseRequestMeta(frame))
}

func (b *bridge) forwardRequest(frame []byte, meta requestMeta) ([]byte, error) {
	return b.forwardRequestContext(context.Background(), frame, meta, requestHeaders{})
}

func (b *bridge) forwardRequestContext(
	ctx context.Context,
	frame []byte,
	meta requestMeta,
	headers requestHeaders,
) ([]byte, error) {
	if !meta.valid {
		return nil, errors.New("invalid JSON-RPC request envelope")
	}

	// Sign a dispatch before it leaves the process (a no-op for non-tools/call
	// frames, and when no key is configured).
	if b.signer != nil {
		frame = b.signer.signFrame(frame)
	}
	rotationPrefix, rotationHash := b.rotationProposal(meta.method)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.endpoint, bytes.NewReader(frame))
	if err != nil {
		return nil, err
	}
	apiKey, protocolVersion := headers.apiKey, headers.protocolVersion
	if apiKey == "" || meta.method == "initialize" {
		apiKey, protocolVersion = b.transportState()
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	// Streamable HTTP clients advertise both response transports. The Emisar
	// endpoint deliberately returns one buffered JSON response, never SSE.
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", b.userAgent)
	if meta.method != "initialize" && protocolVersion != "" {
		req.Header.Set("MCP-Protocol-Version", protocolVersion)
	}
	if headers.requestToken != "" {
		req.Header.Set(requestTokenHeader, headers.requestToken)
	}
	if headers.cancelToken != "" {
		req.Header.Set(cancelTokenHeader, headers.cancelToken)
	}
	if rotationPrefix != "" {
		req.Header.Set(rotationPrefixHeader, rotationPrefix)
		req.Header.Set(rotationHashHeader, rotationHash)
	}

	// MCP session id. One bridge process = one client session, so the
	// per-process id is the session boundary. The portal reuses it at
	// `initialize` and records it on each run + audit event, so a session's
	// actions can be correlated (stdio clients can't echo a server-issued
	// Mcp-Session-Id, so we supply our own).
	req.Header.Set("Mcp-Session-Id", b.sessionID)

	// Self-reported client metadata (untrusted correlation enrichment). Forwarded
	// verbatim on every request; the portal re-validates it and snapshots it onto
	// MCP action runs. Omitted entirely when unconfigured.
	if b.clientMetadata != "" {
		req.Header.Set(clientMetadataHeader, b.clientMetadata)
	}

	// Idempotency key: stable per (process, request-id) so a duplicated
	// downstream delivery collapses to a single run on the portal. MCP request
	// ids themselves are single-use within the bridge session. The portal honors
	// `Idempotency-Key` against the
	// `(api_key_id, idempotency_key)` unique index.
	if k := b.idempotencyKeyFor(meta); k != "" {
		req.Header.Set("Idempotency-Key", k)
	}

	resp, err := b.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if meta.notification() {
		if resp.StatusCode != http.StatusAccepted {
			return nil, fmt.Errorf("portal returned status %d for a notification", resp.StatusCode)
		}
		body, err := readCappedBody(resp.Body, maxResponseBytes)
		if err != nil {
			return nil, err
		}
		if len(bytes.TrimSpace(body)) != 0 {
			return nil, errors.New("portal returned a body for a notification")
		}
		return nil, nil
	}
	if resp.StatusCode == http.StatusAccepted {
		return nil, errors.New("portal returned notification status for a request")
	}

	if resp.StatusCode != http.StatusOK && (resp.StatusCode < 400 || resp.StatusCode >= 500) {
		return nil, fmt.Errorf("unsupported portal response status %d", resp.StatusCode)
	}
	mediaType, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if err != nil || !strings.EqualFold(mediaType, "application/json") {
		return nil, errors.New("portal response is not application/json")
	}
	body, err := readCappedBody(resp.Body, maxResponseBytes)
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(body) {
		return nil, errors.New("portal response is not valid UTF-8")
	}
	if err := validateRPCResponse(meta, resp.StatusCode, body); err != nil {
		return nil, err
	}

	if meta.method == "initialize" {
		version, hasResult, valid := responseProtocolVersion(body)
		if hasResult && !valid {
			return nil, errors.New("initialize response has an invalid protocol version")
		}
		if hasResult {
			b.setProtocolVersion(version)
		}
	}

	if meta.method == "initialize" && resp.StatusCode == http.StatusOK {
		b.acknowledgeRotation(resp.Header.Get(rotationAckHeader))
	}

	return body, nil
}

func (b *bridge) transportState() (apiKey, protocolVersion string) {
	b.stateMu.RLock()
	defer b.stateMu.RUnlock()
	return b.apiKey, b.protocolVersion
}

func (b *bridge) setProtocolVersion(version string) {
	b.stateMu.Lock()
	b.protocolVersion = version
	b.stateMu.Unlock()
}

func validateRPCResponse(meta requestMeta, status int, body []byte) error {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(body, &envelope); err != nil || envelope == nil {
		return errors.New("portal response is not a JSON-RPC object")
	}

	var version string
	if err := json.Unmarshal(envelope["jsonrpc"], &version); err != nil || version != "2.0" {
		return errors.New("portal response has an invalid jsonrpc version")
	}
	responseID, ok := envelope["id"]
	if !ok || !matchingJSONRPCID(meta.responseID(), responseID) {
		return errors.New("portal response id does not match request")
	}
	_, hasResult := envelope["result"]
	rawError, hasError := envelope["error"]
	if hasResult == hasError {
		return errors.New("portal response must contain exactly one of result or error")
	}
	if status >= 400 && !hasError {
		return errors.New("portal error status did not contain a JSON-RPC error")
	}
	if hasError && !validRPCError(rawError) {
		return errors.New("portal response has an invalid JSON-RPC error")
	}
	return nil
}

func matchingJSONRPCID(want, got json.RawMessage) bool {
	want = bytes.TrimSpace(want)
	got = bytes.TrimSpace(got)
	wantKind := jsonRPCIDKind(want)
	if wantKind == 0 || wantKind != jsonRPCIDKind(got) {
		return false
	}
	if wantKind == 's' {
		var wantString, gotString string
		return json.Unmarshal(want, &wantString) == nil &&
			json.Unmarshal(got, &gotString) == nil &&
			wantString == gotString
	}
	if wantKind == 'n' {
		wantNumber, wantOK := new(big.Rat).SetString(string(want))
		gotNumber, gotOK := new(big.Rat).SetString(string(got))
		return wantOK && gotOK && wantNumber.Cmp(gotNumber) == 0
	}
	return bytes.Equal(want, got)
}

func validRPCError(raw json.RawMessage) bool {
	var rpcError struct {
		Code    json.RawMessage `json:"code"`
		Message *string         `json:"message"`
	}
	if err := json.Unmarshal(raw, &rpcError); err != nil || rpcError.Message == nil {
		return false
	}
	var code json.Number
	decoder := json.NewDecoder(bytes.NewReader(rpcError.Code))
	decoder.UseNumber()
	if err := decoder.Decode(&code); err != nil {
		return false
	}
	_, err := code.Int64()
	return err == nil
}

func responseProtocolVersion(body []byte) (version string, hasResult, valid bool) {
	var response struct {
		Result json.RawMessage `json:"result"`
	}
	if json.Unmarshal(body, &response) != nil {
		return "", false, false
	}
	if len(response.Result) == 0 {
		return "", false, true
	}
	var result struct {
		ProtocolVersion string `json:"protocolVersion"`
	}
	if json.Unmarshal(response.Result, &result) != nil || result.ProtocolVersion == "" {
		return "", true, false
	}
	if parsed, err := time.Parse("2006-01-02", result.ProtocolVersion); err != nil || parsed.Format("2006-01-02") != result.ProtocolVersion {
		return "", true, false
	}
	return result.ProtocolVersion, true, true
}

// readCappedBody reads at most limit bytes from r, returning an error if the
// source has more — the portal response is untrusted (a hostile or MITM'd
// endpoint could stream unbounded bytes), and http.Client.Timeout bounds time,
// not size. Reading limit+1 lets a body of exactly limit through.
func readCappedBody(r io.Reader, limit int) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(r, int64(limit)+1))
	if err != nil {
		return nil, err
	}
	if len(body) > limit {
		return nil, fmt.Errorf("portal response exceeds %d bytes", limit)
	}
	return body, nil
}

// idempotencyKey derives a bounded, stable token from the session plus the raw,
// type-tagged JSON-RPC id. Re-sends collapse to one run, while numeric 7 and
// string "7" remain distinct requests. Notifications and null ids get no key.
//
// Hashing also keeps arbitrarily long legal string ids below the portal's
// Idempotency-Key limit. We decode only the top-level id; tool payloads remain
// opaque to this transport layer.
func (b *bridge) idempotencyKey(frame []byte) string {
	return b.idempotencyKeyFor(parseRequestMeta(frame))
}

func (b *bridge) idempotencyKeyFor(meta requestMeta) string {
	if !meta.valid || !meta.hasID || meta.idKind == '0' {
		return ""
	}
	hash := sha256.New()
	_, _ = hash.Write([]byte(b.sessionID))
	_, _ = hash.Write([]byte{0, meta.idKind, 0})
	_, _ = hash.Write(meta.id)
	return "mcp-" + hex.EncodeToString(hash.Sum(nil))
}

// parseClientMetadata validates the operator's EMISAR_CLIENT_METADATA (a JSON
// object of string keys to string-or-number values) and returns the canonical
// JSON to forward in the clientMetadataHeader. It FAILS CLOSED: any malformed
// input, disallowed value type (array/object/bool/null), or exceeded limit is a
// startup error, never a partially-applied map. An empty/unset value — or an
// empty object — yields "" (no header). The limits mirror the portal's boundary
// check; both sides enforce them independently because the header is untrusted
// (a direct HTTP caller or a modified bridge can send anything).
func parseClientMetadata(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}

	dec := json.NewDecoder(strings.NewReader(raw))
	dec.UseNumber() // keep numbers exact — no float rounding of an asset id
	var m map[string]any
	if err := dec.Decode(&m); err != nil {
		return "", fmt.Errorf("EMISAR_CLIENT_METADATA must be a JSON object: %w", err)
	}
	if dec.More() {
		return "", fmt.Errorf("EMISAR_CLIENT_METADATA must be a single JSON object")
	}
	if len(m) > maxClientMetadataKeys {
		return "", fmt.Errorf("EMISAR_CLIENT_METADATA has %d keys, the maximum is %d", len(m), maxClientMetadataKeys)
	}

	clean := make(map[string]any, len(m))
	for key, val := range m {
		if utf8.RuneCountInString(key) > maxClientMetadataKey {
			return "", fmt.Errorf("EMISAR_CLIENT_METADATA key %q exceeds %d characters", key, maxClientMetadataKey)
		}
		switch v := val.(type) {
		case string:
			if utf8.RuneCountInString(v) > maxClientMetadataValue {
				return "", fmt.Errorf("EMISAR_CLIENT_METADATA value for key %q exceeds %d characters", key, maxClientMetadataValue)
			}
		case json.Number:
			if utf8.RuneCountInString(v.String()) > maxClientMetadataValue {
				return "", fmt.Errorf("EMISAR_CLIENT_METADATA value for key %q exceeds %d characters", key, maxClientMetadataValue)
			}
		default:
			return "", fmt.Errorf("EMISAR_CLIENT_METADATA value for key %q must be a string or number", key)
		}
		clean[key] = val
	}

	if len(clean) == 0 {
		return "", nil
	}

	// Re-marshal so the header is canonical (json.Marshal sorts object keys),
	// dropping any formatting the operator's raw value carried.
	canonical, err := json.Marshal(clean)
	if err != nil {
		return "", fmt.Errorf("EMISAR_CLIENT_METADATA could not be encoded: %w", err)
	}
	return string(canonical), nil
}

// buildUserAgent stamps every cloud request with structured client +
// host + os posture. The portal's audit pipeline extracts these from the
// User-Agent header so each audit row carries "client=claude-desktop;
// host=…; os=darwin" instead of "some MCP call from <IP>".
func buildUserAgent() string {
	client := os.Getenv("EMISAR_CLIENT")
	if client == "" {
		client = "unknown"
	}
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "unknown"
	}
	return fmt.Sprintf("%s/%s (client=%s; host=%s; os=%s)", bridgeName, Version, client, host, runtime.GOOS)
}

// newSessionID returns an 8-byte hex nonce identifying this bridge
// process. It serves as the MCP session id (Mcp-Session-Id) and
// namespaces idempotency keys: two unrelated bridge processes never
// alias each other's request ids, and the same process's resend of a
// frame collapses to one run. It fails closed on a rand read error
// (like newNonce) rather than returning a shared constant — a bridge
// that can't mint a unique session id can't namespace idempotency or
// correlate audit, so main() aborts instead.
func newSessionID(r io.Reader) (string, error) {
	var b [8]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return "", fmt.Errorf("session id: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}

// checkEndpointScheme refuses a cleartext (http) EMISAR_URL to a non-loopback
// host, where the Bearer key would travel in plaintext — credential theft +
// MITM. https is always fine; http is allowed only to localhost/127.0.0.1/::1,
// or when EMISAR_ALLOW_INSECURE=1 opts in (mirrors the runner's
// cloud.allow_insecure). Anything other than http/https is rejected — the
// bridge POSTs over HTTP, not a websocket.
func checkEndpointScheme(base string, allowInsecure bool) error {
	u, err := url.Parse(base)
	if err != nil {
		return fmt.Errorf("EMISAR_URL %q is not a valid URL: %w", base, err)
	}
	switch u.Scheme {
	case "https":
		return nil
	case "http":
		if allowInsecure || isLoopbackHost(u.Hostname()) {
			return nil
		}
		return fmt.Errorf("EMISAR_URL %q uses cleartext http to a non-loopback host, "+
			"which sends the API key in plaintext; use https, or set "+
			"EMISAR_ALLOW_INSECURE=1 to override", base)
	default:
		return fmt.Errorf("EMISAR_URL %q must be http or https, got scheme %q", base, u.Scheme)
	}
}

// isLoopbackHost reports whether host is localhost or a loopback IP.
func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func fatalln(args ...any) {
	fmt.Fprintln(os.Stderr, append([]any{"emisar-mcp:"}, args...)...)
	os.Exit(1)
}
