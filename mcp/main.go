// Command emisar-mcp is a thin stdio↔HTTP shim for MCP-aware clients
// (Claude Desktop, Cursor, Claude Code, Gemini CLI, Codex CLI, …) that
// only speak stdio JSON-RPC.
//
// The bridge does NOTHING that the portal couldn't do — it just
// forwards every JSON-RPC frame to POST /api/mcp/rpc on the portal
// and writes the response to stdout. All tool descriptors, content
// blocks, and the synthetic `wait_for_run` tool are produced by the
// portal; the bridge has no MCP-protocol-specific logic of its own.
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
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
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
  tools/list, tools/call, ping, notifications/…) is forwarded verbatim;
  no MCP semantics live in this binary.

Environment:
  EMISAR_URL        Base URL of the control plane (required)
                    e.g. https://emisar.dev
  EMISAR_API_KEY    Operator API key (required), e.g. emk-...
  EMISAR_CLIENT     Optional label that shows up in the audit log
                    (claude-desktop, cursor, codex, …). Defaults to
                    "unknown".
  EMISAR_SIGNING_KEY     Optional Ed25519 private key (64-hex seed). When set
                         (with EMISAR_SIGNING_CERT), the bridge signs each
                         tools/call so runners that enforce signatures will run
                         it. Get the key+cert pair from 'emisar cert new' (or
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

// serve reads JSON-RPC frames one per line from r, forwards them
// verbatim to the portal, and writes the response to w. Notifications
// (POST returns 202 with empty body) are silently dropped, per spec.
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
			_, _ = fmt.Fprint(w, `{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"request frame too large"}}`+"\n")

		case len(line) == 0:
			// blank line (or a bare EOF) — nothing to forward

		default:
			resp, err := b.forward(line)
			switch {
			case err != nil:
				// Network-level error: a synthetic JSON-RPC error so the client
				// sees something actionable. Keep the detail on stderr — don't
				// leak the resolved host/IP into the LLM transcript.
				fmt.Fprintf(os.Stderr, "emisar-mcp: forward error: %v\n", err)
				_, _ = fmt.Fprint(w, `{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"upstream transport error"}}`+"\n")

			case len(resp) == 0:
				// 202-no-body — notification; nothing to write.

			default:
				// Ensure newline-delimited so the client's line reader frames.
				if _, werr := w.Write(resp); werr != nil {
					return werr
				}
				if !bytes.HasSuffix(resp, []byte("\n")) {
					_, _ = w.Write([]byte("\n"))
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

// forward POSTs the JSON-RPC frame to the portal and returns the
// response body. A 202 status is treated as "notification accepted,
// no response" — we return an empty body in that case.
func (b *bridge) forward(frame []byte) ([]byte, error) {
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
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", b.userAgent)

	// MCP session id. One bridge process = one client session, so the
	// per-process id is the session boundary. The portal reuses it at
	// `initialize` and records it on each run + audit event, so a session's
	// actions can be correlated (stdio clients can't echo a server-issued
	// Mcp-Session-Id, so we supply our own).
	req.Header.Set("Mcp-Session-Id", b.sessionID)

	// Idempotency key: stable per (process, request-id) so resends
	// of the same JSON-RPC frame collapse to a single run on the
	// portal. The portal honors `Idempotency-Key` against the
	// `(api_key_id, idempotency_key)` unique index.
	if k := b.idempotencyKey(frame); k != "" {
		req.Header.Set("Idempotency-Key", k)
	}

	resp, err := b.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := readCappedBody(resp.Body, maxResponseBytes)
	if err != nil {
		return nil, err
	}

	// Response-carried rotation: the portal offers a successor key in a
	// header (only ever on a successful initialize; checking every response
	// keeps the bridge free of MCP semantics).
	if s := resp.Header.Get(successorKeyHeader); s != "" && resp.StatusCode < 300 {
		b.adoptSuccessor(s)
	}

	if resp.StatusCode == http.StatusAccepted {
		// Notification — no response body expected.
		return nil, nil
	}

	if resp.StatusCode >= 500 {
		return nil, fmt.Errorf("portal %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	// 200 (normal result) or 4xx (auth / shape errors are already
	// shaped as JSON-RPC error frames by the portal) — forward as-is.
	return body, nil
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

// idempotencyKey derives a stable per-frame token from the JSON-RPC
// envelope `id`. Re-sends of the same id (e.g. a client retry within the
// same process) collapse to one run at the portal. Notifications (no id)
// and explicit null ids get no key.
//
// We decode ONLY the top-level `id` (as a raw token) — not the rest of
// the payload, which the bridge still relays verbatim. An earlier
// byte-scan for the first `"id"` could latch onto a nested
// `params.…id` that serialized before the envelope id and mint an empty
// or wrong key; a real decode keys off the right field regardless of key
// order or nesting.
func (b *bridge) idempotencyKey(frame []byte) string {
	var envelope struct {
		ID json.RawMessage `json:"id"`
	}
	if err := json.Unmarshal(frame, &envelope); err != nil {
		return ""
	}
	id := bytes.TrimSpace(envelope.ID)
	if len(id) == 0 || bytes.Equal(id, []byte("null")) {
		return ""
	}
	// A JSON-RPC id is a string or a number. Strip the quotes from a
	// string id so `"7"` and `7` map to the same key.
	return b.sessionID + ":" + strings.Trim(string(id), `"`)
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
