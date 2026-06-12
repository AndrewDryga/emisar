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
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
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

	b := &bridge{
		endpoint:  base + "/api/mcp/rpc",
		apiKey:    apiKey,
		userAgent: buildUserAgent(),
		client:    &http.Client{Timeout: httpTimeout},
		sessionID: newSessionID(),
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
}

// serve reads JSON-RPC frames one per line from r, forwards them
// verbatim to the portal, and writes the response to w. Notifications
// (POST returns 202 with empty body) are silently dropped, per spec.
func (b *bridge) serve(r io.Reader, w io.Writer) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)

	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}

		resp, err := b.forward(line)
		if err != nil {
			// Network-level error: emit a synthetic JSON-RPC error so the
			// client sees something actionable instead of a closed pipe.
			_, _ = fmt.Fprintf(w, `{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":%q}}`+"\n", err.Error())
			continue
		}

		if len(resp) == 0 {
			// 202-no-body — notification; nothing to write.
			continue
		}

		// Ensure newline-delimited so the client's line reader frames.
		if _, err := w.Write(resp); err != nil {
			return err
		}
		if !bytes.HasSuffix(resp, []byte("\n")) {
			_, _ = w.Write([]byte("\n"))
		}
	}

	return scanner.Err()
}

// forward POSTs the JSON-RPC frame to the portal and returns the
// response body. A 202 status is treated as "notification accepted,
// no response" — we return an empty body in that case.
func (b *bridge) forward(frame []byte) ([]byte, error) {
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

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
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

// idempotencyKey derives a stable per-frame token from the JSON-RPC
// `id` field. Re-sends of the same id (e.g. client retry within the
// same process) collapse to one run at the portal. Notifications
// (no id) get no key.
//
// We pluck `id` with a cheap string match instead of decoding JSON;
// the bridge has no business parsing the payload it's just relaying.
func (b *bridge) idempotencyKey(frame []byte) string {
	// Look for `"id":<value>` — the spec allows numbers, strings, null.
	idx := bytes.Index(frame, []byte(`"id"`))
	if idx < 0 {
		return ""
	}
	// Skip past `"id"` and any whitespace + colon.
	tail := frame[idx+4:]
	for len(tail) > 0 && (tail[0] == ' ' || tail[0] == ':' || tail[0] == '\t') {
		tail = tail[1:]
	}
	if len(tail) == 0 {
		return ""
	}

	// Take everything up to the next comma or closing brace.
	end := len(tail)
	for i, c := range tail {
		if c == ',' || c == '}' {
			end = i
			break
		}
	}
	val := bytes.TrimSpace(tail[:end])
	if len(val) == 0 || bytes.Equal(val, []byte("null")) {
		return ""
	}
	return b.sessionID + ":" + strings.Trim(string(val), `"`)
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
// frame collapses to one run.
func newSessionID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "nosession"
	}
	return hex.EncodeToString(b[:])
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
