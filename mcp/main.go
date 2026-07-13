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
	"path/filepath"
	"runtime"
	"strings"
	"time"
	"unicode/utf8"
)

const bridgeName = "emisar-mcp"

// Includes the long-poll window the portal applies on tools/call
// (up to 90s, the portal's max_get_run_wait_ms) plus headroom. A
// timeout equal to the poll cap would race the portal's graceful
// "waiting" response at the boundary. Connections idle longer than
// this shouldn't happen; if they do, fail visibly.
const httpTimeout = 120 * time.Second

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
  Near the API key's expiry the portal hands the bridge a successor key in
  the initialize response. The bridge adopts it immediately and persists it
  to <user-config-dir>/emisar/credentials.json (0600), keyed by the original
  key's prefix — so the EMISAR_API_KEY in your client config keeps working
  across rotations without ever being edited.

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

	// Response-carried rotation: a successor persisted by an earlier session
	// takes precedence over the bootstrap key from the client's config, which
	// may have expired since.
	credsPath, credsErr := credentialsPath()
	if credsErr != nil {
		fmt.Fprintf(os.Stderr, "emisar-mcp: no user config dir (%v); key rotation won't persist\n", credsErr)
	}
	bootstrap := keyPrefix(apiKey)
	if stored, ok := loadStoredSuccessor(credsPath, bootstrap); ok {
		apiKey = stored
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
		bootstrapPrefix: bootstrap,
		credsPath:       credsPath,
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
	// sessionID identifies this bridge process. It doubles as the MCP
	// session id (sent as Mcp-Session-Id) and the namespace for
	// idempotency keys, so a session's runs correlate and resent frames
	// collapse to one run.
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
	// requires clients to echo it on subsequent requests, but not on initialize
	// itself. serve is single-goroutine until request scheduling is introduced.
	protocolVersion string
	// bootstrapPrefix identifies the ORIGINAL key from the client's config
	// ("emk-" + the portal's 12-char prefix — non-secret); it stays the
	// credentials-file lookup key across chained rotations. apiKey holds the
	// CURRENT secret and is swapped in place by adoptSuccessor — serve is
	// single-goroutine, so plain field mutation is safe.
	bootstrapPrefix string
	// credsPath is the bridge-owned credentials file; "" when no user config
	// dir exists (rotation then lasts only for the process).
	credsPath string
}

// serve reads JSON-RPC frames one per line from r, forwards valid envelopes to
// the portal, and writes validated correlated responses to w. Notifications are
// always silent, including when the HTTP request fails.
func (b *bridge) serve(r io.Reader, w io.Writer) error {
	br := bufio.NewReaderSize(r, 64*1024)

	for {
		raw, oversize, readErr := readFrameLine(br)
		line := bytes.TrimSpace(raw)

		switch {
		case oversize:
			// An over-long frame rejects THIS line but keeps the session alive —
			// the bridge is the LLM's only path to the cloud; one bad frame must
			// not tear it down (the old Scanner ErrTooLong → os.Exit did exactly
			// that). readFrameLine drains the over-long line without retaining it,
			// so a newline-free flood can't OOM the bridge before we reach here.
			fmt.Fprintf(os.Stderr, "emisar-mcp: dropping a request frame over %d bytes\n", maxFrameBytes)
			if err := writeFrame(w, rpcErrorFrame(requestMeta{}, -32600, "request frame too large")); err != nil {
				return err
			}

		case len(line) == 0:
			// blank line (or a bare EOF) — nothing to forward

		default:
			meta := parseRequestMeta(line)
			if !meta.valid {
				if err := writeFrame(w, rpcErrorFrame(meta, -32600, "invalid request")); err != nil {
					return err
				}
				break
			}
			resp, err := b.forwardRequest(line, meta)
			switch {
			case err != nil:
				// A notification never receives a response. Request failures are
				// correlated locally without exposing response bodies, network
				// details, or credentials to either protocol output or stderr.
				if !meta.notification() {
					if err := writeFrame(w, rpcErrorFrame(meta, -32603, "upstream transport error")); err != nil {
						return err
					}
				}

			case len(resp) == 0:
				// 202-no-body — notification; nothing to write.

			default:
				if err := writeFrame(w, resp); err != nil {
					return err
				}
			}
		}

		if readErr != nil {
			if readErr == io.EOF {
				return nil
			}
			return readErr
		}
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
	if !meta.valid {
		return nil, errors.New("invalid JSON-RPC request envelope")
	}

	// Sign a dispatch before it leaves the process (a no-op for non-tools/call
	// frames, and when no key is configured).
	if b.signer != nil {
		frame = b.signer.signFrame(frame)
	}

	req, err := http.NewRequest(http.MethodPost, b.endpoint, bytes.NewReader(frame))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+b.apiKey)
	// Streamable HTTP clients advertise both response transports. The Emisar
	// endpoint deliberately returns one buffered JSON response, never SSE.
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", b.userAgent)
	if meta.method != "initialize" && b.protocolVersion != "" {
		req.Header.Set("MCP-Protocol-Version", b.protocolVersion)
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

	// Idempotency key: stable per (process, request-id) so resends
	// of the same JSON-RPC frame collapse to a single run on the
	// portal. The portal honors `Idempotency-Key` against the
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
			b.protocolVersion = version
		}
	}

	// Rotation is adopted only after the response passed every transport and
	// protocol check. Durability and concurrent persistence are handled by the
	// dedicated rotation task.
	if s := resp.Header.Get(successorKeyHeader); s != "" && resp.StatusCode < 300 {
		b.adoptSuccessor(s)
	}

	return body, nil
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

// -- Response-carried key rotation ------------------------------------
//
// Near a key's expiry the portal answers `initialize` with a freshly minted
// successor in the X-Emisar-Successor-Key response HEADER — never the
// JSON-RPC body, which the bridge forwards verbatim into the LLM transcript.
// The bridge swaps the successor in for the rest of the process and persists
// it to a bridge-owned credentials file keyed by the BOOTSTRAP key's prefix:
// the client's config keeps its original key forever, and every launch
// resolves prefix → current secret, so chained rotations keep working.

const successorKeyHeader = "X-Emisar-Successor-Key"

// keyPrefix is the non-secret identifier for a key ("emk-" + the portal's
// 12-char random prefix) — the same prefix the portal's UI shows.
func keyPrefix(key string) string {
	if len(key) < 16 {
		return key
	}
	return key[:16]
}

// validSuccessor sanity-checks a successor before adopting it: portal keys
// are "emk-"-prefixed and bounded; anything else is a corrupt or hostile
// header and is ignored.
func validSuccessor(s string) bool {
	return strings.HasPrefix(s, "emk-") && len(s) >= 20 && len(s) <= 256
}

func credentialsPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "emisar", "credentials.json"), nil
}

// loadStoredSuccessor returns the persisted current secret for a bootstrap
// prefix, when the credentials file holds a valid one.
func loadStoredSuccessor(path, bootstrapPrefix string) (string, bool) {
	if path == "" {
		return "", false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	var creds map[string]string
	if err := json.Unmarshal(data, &creds); err != nil {
		fmt.Fprintf(os.Stderr, "emisar-mcp: ignoring corrupt credentials file %s: %v\n", path, err)
		return "", false
	}
	stored, ok := creds[bootstrapPrefix]
	if !ok || !validSuccessor(stored) {
		return "", false
	}
	return stored, true
}

// adoptSuccessor swaps the rotated key in for the rest of this process and
// persists it so the next launch resolves it from the bootstrap prefix. A
// failed persist degrades to a process-lifetime swap, never a dead session.
func (b *bridge) adoptSuccessor(s string) {
	if !validSuccessor(s) || s == b.apiKey {
		return
	}
	b.apiKey = s
	if b.credsPath == "" {
		fmt.Fprintln(os.Stderr, "emisar-mcp: adopted a rotated API key for this session (no config dir; not persisted)")
		return
	}
	if err := persistSuccessor(b.credsPath, b.bootstrapPrefix, s); err != nil {
		fmt.Fprintf(os.Stderr, "emisar-mcp: adopted a rotated API key for this session; persisting failed: %v\n", err)
		return
	}
	fmt.Fprintf(os.Stderr, "emisar-mcp: rotated API key persisted to %s\n", b.credsPath)
}

// persistSuccessor merges prefix → secret into the credentials file via an
// atomic same-directory rename; dir 0700, file 0600 — it stores live secrets.
func persistSuccessor(path, bootstrapPrefix, secret string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create %s: %w", dir, err)
	}

	creds := map[string]string{}
	if data, err := os.ReadFile(path); err == nil {
		// Corrupt existing content is replaced, not fatal — the file caches
		// successors; the bootstrap key in the client config is the fallback.
		_ = json.Unmarshal(data, &creds)
	}
	creds[bootstrapPrefix] = secret

	data, err := json.MarshalIndent(creds, "", "  ")
	if err != nil {
		return err
	}

	tmp, err := os.CreateTemp(dir, "credentials-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())

	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
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
