// Command emisar-mcp is a stdio MCP bridge that proxies tools/list +
// tools/call requests from MCP-aware clients (Claude Desktop, Cursor,
// etc.) into the emisar control-plane HTTP API.
//
// Configure your client to launch:
//
//	{
//	  "mcpServers": {
//	    "emisar": {
//	      "command": "/usr/local/bin/emisar-mcp",
//	      "env": {
//	        "EMISAR_URL":     "https://app.emisar.dev",
//	        "EMISAR_API_KEY": "emk-..."
//	      }
//	    }
//	  }
//	}
//
// Protocol: JSON-RPC 2.0 line-delimited on stdio. We implement just the
// subset Claude Desktop / Cursor actually use today: `initialize`,
// `tools/list`, `tools/call`. Everything else returns a -32601 method
// not found.
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
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	bridgeName = "emisar-mcp"

	// Per request to the cloud, including the long-poll wait.
	httpTimeout = 90 * time.Second
)

// Version is the build version. Stamped by `-ldflags "-X main.Version=..."`
// from the release pipeline; "dev" when built locally.
var Version = "dev"

// bridgeVersion is what the bridge advertises in `initialize` responses.
// Mirrors Version so an MCP client can see exactly what's connected.
var bridgeVersion = Version

const helpText = `emisar-mcp — MCP stdio bridge for emisar

  Proxies MCP JSON-RPC requests (tools/list, tools/call) from a
  local LLM client (Claude Desktop, Claude Code, Cursor, Gemini CLI,
  Codex CLI, …) into the emisar control-plane HTTP API.

Environment:
  EMISAR_URL        Base URL of the control plane (required)
                    e.g. https://app.emisar.dev
  EMISAR_API_KEY    Operator API key with the right scopes (required)
                    e.g. emk-...

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

	url := strings.TrimRight(os.Getenv("EMISAR_URL"), "/")
	apiKey := os.Getenv("EMISAR_API_KEY")

	if url == "" || apiKey == "" {
		fatalln("EMISAR_URL and EMISAR_API_KEY must both be set (try --help)")
	}

	srv := &bridge{
		baseURL:   url,
		apiKey:    apiKey,
		userAgent: buildUserAgent(),
		http:      &http.Client{Timeout: httpTimeout},
		sessionID: newSessionID(),
	}

	if err := srv.serve(os.Stdin, os.Stdout); err != nil && !errors.Is(err, io.EOF) {
		fatalln("serve:", err)
	}
}

// -- JSON-RPC plumbing -----------------------------------------------

type rpcReq struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResp struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcErr         `json:"error,omitempty"`
}

type rpcErr struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

type bridge struct {
	baseURL   string
	apiKey    string
	userAgent string
	http      *http.Client

	// sessionID namespaces this process's idempotency keys. See
	// newSessionID + idempotencyKey for why it's needed.
	sessionID string
}

// newSessionID returns a random hex nonce that namespaces the
// idempotency keys this process mints. The per-call key is derived from
// (sessionID, JSON-RPC request id): a client that re-sends the SAME
// request id within this process collapses to one run at the cloud,
// while distinct ids — or a different process — never collide. The
// nonce is what stops two unrelated sessions, each starting their
// JSON-RPC ids at 1, from aliasing one another's runs. (A retry that
// also restarts the bridge gets a fresh nonce and dispatches a new run
// — the safe direction.)
func newSessionID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand should never fail; if it does, fall back to a
		// fixed marker. We lose per-process uniqueness but still
		// namespace away from raw request ids.
		return "nosession"
	}
	return hex.EncodeToString(b[:])
}

// buildUserAgent stamps every cloud request with structured client +
// host posture. The cloud's audit pipeline extracts these from the
// User-Agent header, so:
//
//	emisar-mcp/0.2.0 (client=claude-desktop; host=andrews-mbp.local)
//
// becomes a "Client: claude-desktop" + "Host: andrews-mbp.local" row
// on each audit event the LLM produces. Without this the audit page
// can only say "some MCP call from <IP>", which is the wrong fidelity
// for an LLM-driven system.
//
// EMISAR_CLIENT is set in the install snippet on each client (Claude
// Desktop / Claude Code / Cursor / etc.); falls back to "unknown" so
// hand-rolled integrations still get logged, just without the label.
func buildUserAgent() string {
	client := os.Getenv("EMISAR_CLIENT")
	if client == "" {
		client = "unknown"
	}

	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "unknown"
	}

	return fmt.Sprintf("%s/%s (client=%s; host=%s)", bridgeName, Version, client, host)
}

// serve reads JSON-RPC requests one per line from r and writes
// responses to w. Notifications (no id) get no response.
func (b *bridge) serve(r io.Reader, w io.Writer) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
	enc := json.NewEncoder(w)

	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}

		var req rpcReq
		if err := json.Unmarshal(line, &req); err != nil {
			_ = enc.Encode(errorResp(nil, -32700, "parse error", err.Error()))
			continue
		}

		resp := b.handle(req)
		if resp == nil {
			// notification — no reply.
			continue
		}
		_ = enc.Encode(resp)
	}

	return scanner.Err()
}

func (b *bridge) handle(req rpcReq) *rpcResp {
	// Notifications: methods that begin with "notifications/" + no id.
	isNotification := len(req.ID) == 0 || string(req.ID) == "null"

	switch req.Method {
	case "initialize":
		return okResp(req.ID, b.initialize())

	case "tools/list":
		tools, err := b.listTools()
		if err != nil {
			return errorResp(req.ID, -32603, "tools/list failed", err.Error())
		}
		return okResp(req.ID, map[string]any{"tools": tools})

	case "tools/call":
		var p struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return errorResp(req.ID, -32602, "invalid params", err.Error())
		}
		result, err := b.callTool(p.Name, p.Arguments, b.idempotencyKey(req.ID))
		if err != nil {
			return errorResp(req.ID, -32603, "tools/call failed", err.Error())
		}
		return okResp(req.ID, result)

	case "notifications/initialized", "notifications/cancelled":
		return nil

	default:
		if isNotification {
			return nil
		}
		return errorResp(req.ID, -32601, "method not found", req.Method)
	}
}

// -- MCP handlers ----------------------------------------------------

func (b *bridge) initialize() map[string]any {
	return map[string]any{
		"protocolVersion": "2024-11-05",
		"serverInfo": map[string]any{
			"name":    bridgeName,
			"version": bridgeVersion,
		},
		"capabilities": map[string]any{
			"tools": map[string]any{"listChanged": false},
		},
	}
}

func (b *bridge) listTools() ([]map[string]any, error) {
	var body struct {
		Tools []map[string]any `json:"tools"`
	}

	if err := b.get("/api/mcp/tools", &body); err != nil {
		return nil, err
	}

	// MCP tool descriptors need `name`, `description`, `inputSchema`.
	// Strip emisar-specific fields the client doesn't need.
	out := make([]map[string]any, 0, len(body.Tools)+1)
	for _, t := range body.Tools {
		out = append(out, map[string]any{
			"name":        t["name"],
			"description": t["description"],
			"inputSchema": t["inputSchema"],
		})
	}

	// Synthetic tool: wait_for_run. The LLM uses this to park on a
	// pending-approval run until the operator decides. Without it,
	// pending_approval would be a dead end — the LLM has no way to
	// see whether the human ever clicked Approve.
	out = append(out, waitForRunTool())

	return out, nil
}

func waitForRunTool() map[string]any {
	return map[string]any{
		"name": "wait_for_run",
		"description": "Park on a previously-dispatched run until it reaches a terminal state " +
			"(success, failed, denied, cancelled, etc.). Call this whenever a tool returns " +
			"`status: \"pending_approval\"` — the response carries a `run_id` and this tool " +
			"polls the cloud for the operator's decision and the action's output. " +
			"Times out after 5 minutes; if you hit the timeout, call wait_for_run again " +
			"with the same run_id to keep waiting.",
		"inputSchema": map[string]any{
			"$schema":              "https://json-schema.org/draft/2020-12/schema",
			"type":                 "object",
			"additionalProperties": false,
			"required":             []string{"run_id"},
			"properties": map[string]any{
				"run_id": map[string]any{
					"type":        "string",
					"description": "The run id returned by the tool that requested approval.",
				},
				"timeout": map[string]any{
					"type":        "string",
					"description": "How long to block (e.g. \"60s\", \"3m\"). Max 5m. Defaults to 5m.",
					"pattern":     "^[0-9]+(ms|s|m)$",
				},
			},
		},
	}
}

// idempotencyKey derives the per-call Idempotency-Key sent to the
// cloud (Layer 1: transport-retry protection). It's stable for a given
// (session, JSON-RPC id) so a resend of the same request collapses to
// one run; it's empty for notifications (no id) where there's nothing
// to retry against. The cloud treats this header as the dedup token
// unless the LLM set an explicit `idempotency_key` arg (Layer 2), which
// takes precedence server-side.
func (b *bridge) idempotencyKey(id json.RawMessage) string {
	if len(id) == 0 || string(id) == "null" {
		return ""
	}
	// JSON-RPC ids are numbers or strings; strip surrounding quotes so
	// id 7 and id "7" don't produce visually-different keys.
	return b.sessionID + ":" + strings.Trim(string(id), `"`)
}

func (b *bridge) callTool(name string, args map[string]any, idemKey string) (map[string]any, error) {
	if name == "" {
		return nil, errors.New("missing tool name")
	}

	// Synthetic tool intercept: the cloud doesn't know about
	// wait_for_run — it's a bridge-side concept that translates into
	// `GET /api/mcp/runs/:id?wait=...` long-polling. The cloud route
	// exists so an external HTTP client can poll directly too.
	if name == "wait_for_run" {
		return b.waitForRun(args)
	}

	// Synchronous: long-poll up to 60s for a terminal state. If the
	// run requires approval or doesn't terminate in time, the cloud
	// returns 202 with `status: "pending_approval"` or
	// `status: "running"`; we surface that to the LLM.
	//
	// The bridge is a pass-through: the LLM's tool args declare
	// `reason`, `runner`, and the action's own args at the top level
	// (per the inputSchema the cloud emits in /tools), and the cloud
	// splits known top-level keys from action args. We don't pre-wrap.
	payload, _ := json.Marshal(args)

	status, body, err := b.postRaw("/api/mcp/tools/"+name+"?wait=60s", payload, idemKey)
	if err != nil {
		return nil, err
	}

	// 4xx is "the LLM called us wrong" (missing runner, bad arg, no
	// such action). Surface the cloud's JSON body as a tool result
	// with isError=true so the model sees the actionable details
	// (candidate runner names, etc.) and can self-correct on retry.
	// Without this, the body gets buried inside a JSON-RPC -32603 and
	// the model only sees "tools/call failed".
	if status >= 400 && status < 500 {
		return map[string]any{
			"content": []map[string]any{{
				"type": "text",
				"text": fmt.Sprintf("Cloud rejected the call (HTTP %d): %s", status, strings.TrimSpace(string(body))),
			}},
			"isError": true,
		}, nil
	}

	if status >= 500 {
		return nil, fmt.Errorf("emisar /api/mcp/tools/%s: %d %s", name, status, strings.TrimSpace(string(body)))
	}

	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("decode /api/mcp/tools/%s response: %w", name, err)
	}

	// The cloud's dispatch response is always {"runs": [...]} — even
	// when the LLM only targeted one runner. Each entry has its own
	// status (success / failed / error / denied / pending_approval),
	// stdout, stderr, exit_code, error_message, etc. Render one
	// content block per run so the model sees each runner's outcome
	// distinctly; without this everything past the first run gets
	// silently dropped.
	rawRuns, hasRuns := result["runs"].([]any)
	if !hasRuns {
		// Defensive fallback for any older-shape response — treat the
		// whole body as a single run.
		rawRuns = []any{result}
	}

	multi := len(rawRuns) > 1
	allContent := []map[string]any{}
	anyError := false

	for _, raw := range rawRuns {
		run, ok := raw.(map[string]any)
		if !ok {
			continue
		}

		blocks, isErr := renderRunBlocks(run, multi)
		allContent = append(allContent, blocks...)
		if isErr {
			anyError = true
		}
	}

	if len(allContent) == 0 {
		allContent = append(allContent, map[string]any{
			"type": "text",
			"text": "(no output)",
		})
	}

	return map[string]any{
		"content": allContent,
		"isError": anyError,
	}, nil
}

// renderRunBlocks turns a single per-run payload (the shape emitted by
// `Emisar.Runs.full_run_payload/1` on the cloud side) into LLM-facing
// content blocks. It surfaces stdout, stderr, exit code, and
// error_message explicitly so the model can diagnose failures
// instead of seeing an opaque "status: error". When `multi` is true a
// runner-name header is prepended so the LLM can tell entries apart.
//
// Returns the content blocks and whether the run should mark the
// overall tool call as an error (isError=true on MCP).
func renderRunBlocks(run map[string]any, multi bool) (blocks []map[string]any, isError bool) {
	status, _ := run["status"].(string)
	runner, _ := run["runner"].(string)
	stdout, _ := run["stdout"].(string)
	stderr, _ := run["stderr"].(string)
	errMsg, _ := run["error_message"].(string)
	reason, _ := run["reason"].(string)
	policyReasonStr := policyReason(run)

	exitCode, hasExit := numericField(run, "exit_code")
	durationMs, hasDur := numericField(run, "duration_ms")

	// Pending approval is the "do this next" path — the LLM must call
	// wait_for_run with the run_id. Without this hint the model
	// assumes the call failed.
	if status == "pending_approval" {
		runID := stringField(run, "run_id", "id")
		hdr := ""
		if multi && runner != "" {
			hdr = fmt.Sprintf("[%s] ", runner)
		}
		blocks = append(blocks, map[string]any{
			"type": "text",
			"text": fmt.Sprintf(
				"%sHuman approval pending in the operator dashboard.\n"+
					"run_id: %s\n\n"+
					"Call `wait_for_run` with this run_id to block until the operator "+
					"decides (up to 5 minutes per call). You'll get the action output on "+
					"approve, or the denial reason on deny.",
				hdr, runID,
			),
		})
		return blocks, false
	}

	// Policy denied at dispatch — the action never reached the runner.
	if status == "denied_by_policy" || status == "denied" {
		hdr := ""
		if multi && runner != "" {
			hdr = fmt.Sprintf("[%s] ", runner)
		}
		policyMsg := policyReasonStr
		if policyMsg == "" {
			policyMsg = reason
		}
		blocks = append(blocks, map[string]any{
			"type": "text",
			"text": fmt.Sprintf("%sDenied by policy: %s", hdr, policyMsg),
		})
		return blocks, true
	}

	// Per-runner validation errors surface as {error: "..."} entries
	// from the multi-runner controller path — render them clearly.
	if errStr, _ := run["error"].(string); errStr != "" {
		hdr := ""
		if multi && runner != "" {
			hdr = fmt.Sprintf("[%s] ", runner)
		}
		msg, _ := run["message"].(string)
		text := fmt.Sprintf("%sError: %s", hdr, errStr)
		if msg != "" {
			text += "\n" + msg
		}
		blocks = append(blocks, map[string]any{"type": "text", "text": text})
		return blocks, true
	}

	// Build the header for runner + status + exit code. This is the
	// single most useful line for an LLM diagnosing a failure: at a
	// glance it knows which host, terminal status, and exit code.
	headerBits := []string{}
	if multi && runner != "" {
		headerBits = append(headerBits, fmt.Sprintf("[%s]", runner))
	}
	if status != "" {
		headerBits = append(headerBits, "status="+status)
	}
	if hasExit {
		headerBits = append(headerBits, fmt.Sprintf("exit_code=%d", int(exitCode)))
	}
	if hasDur {
		headerBits = append(headerBits, fmt.Sprintf("duration=%dms", int(durationMs)))
	}

	if len(headerBits) > 0 {
		blocks = append(blocks, map[string]any{
			"type": "text",
			"text": strings.Join(headerBits, " "),
		})
	}

	if stdout != "" {
		blocks = append(blocks, map[string]any{"type": "text", "text": stdout})
	}

	if stderr != "" {
		blocks = append(blocks, map[string]any{
			"type": "text",
			"text": "stderr:\n" + stderr,
		})
	}

	// error_message holds the runner-side failure cause for non-success
	// terminal states (e.g. "fork/exec /bin/systemctl: no such file"
	// when the binary isn't on PATH). Always show it when present —
	// this is the LLM's only window into what went wrong.
	if errMsg != "" {
		blocks = append(blocks, map[string]any{
			"type": "text",
			"text": "Error: " + errMsg,
		})
	}

	isError = isFailureStatus(status) || (hasExit && exitCode != 0)
	return blocks, isError
}

func isFailureStatus(s string) bool {
	switch s {
	case "failed", "error", "validation_failed", "unknown_action",
		"cancelled", "timed_out", "denied", "denied_by_policy":
		return true
	}
	return false
}

func numericField(m map[string]any, key string) (float64, bool) {
	switch v := m[key].(type) {
	case float64:
		return v, true
	case int:
		return float64(v), true
	}
	return 0, false
}

func stringField(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k].(string); ok && v != "" {
			return v
		}
	}
	return ""
}

func policyReason(run map[string]any) string {
	policy, ok := run["policy"].(map[string]any)
	if !ok {
		return ""
	}
	r, _ := policy["reason"].(string)
	return r
}

// waitForRun translates the synthetic `wait_for_run` MCP tool into a
// long-poll on /api/mcp/runs/:id?wait=300s. Surfaced to the LLM so it
// can park on pending_approval runs without manual polling.
func (b *bridge) waitForRun(args map[string]any) (map[string]any, error) {
	runID, _ := args["run_id"].(string)
	if runID == "" {
		return map[string]any{
			"content": []map[string]any{{
				"type": "text",
				"text": "wait_for_run requires `run_id` (string).",
			}},
			"isError": true,
		}, nil
	}

	timeout, _ := args["timeout"].(string)
	if timeout == "" {
		timeout = "300s"
	}

	status, body, err := b.getRaw(fmt.Sprintf("/api/mcp/runs/%s?wait=%s", runID, timeout))
	if err != nil {
		return nil, err
	}

	if status >= 400 && status < 500 {
		return map[string]any{
			"content": []map[string]any{{
				"type": "text",
				"text": fmt.Sprintf("Cloud rejected wait_for_run (HTTP %d): %s", status, strings.TrimSpace(string(body))),
			}},
			"isError": true,
		}, nil
	}

	if status >= 500 {
		return nil, fmt.Errorf("emisar /api/mcp/runs/%s: %d %s", runID, status, strings.TrimSpace(string(body)))
	}

	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("decode wait_for_run response: %w", err)
	}

	runStatus, _ := result["status"].(string)

	// Still in-flight — tell the LLM to call again. wait_for_run is the
	// only place this code path matters; the dispatch tool's
	// long-poll never returns a non-terminal run.
	if _, isWaiting := result["waiting"]; isWaiting || runStatus == "pending_approval" || runStatus == "pending" || runStatus == "sent" || runStatus == "running" {
		return map[string]any{
			"content": []map[string]any{{
				"type": "text",
				"text": fmt.Sprintf(
					"Run %s is still %q. Call wait_for_run with the same run_id to keep waiting.",
					runID, runStatus,
				),
			}},
			"isError": false,
		}, nil
	}

	// Terminal — surface stdout/stderr/exit_code/error_message the
	// same way the dispatch tool does, so the LLM gets identical
	// failure-diagnosis material whether it polled or got the result
	// inline.
	blocks, isErr := renderRunBlocks(result, false)
	if len(blocks) == 0 {
		blocks = append(blocks, map[string]any{
			"type": "text",
			"text": "(run finished with no captured output)",
		})
	}

	return map[string]any{
		"content": blocks,
		"isError": isErr,
	}, nil
}

// -- HTTP helpers ----------------------------------------------------

func (b *bridge) get(path string, out any) error {
	req, err := http.NewRequest(http.MethodGet, b.baseURL+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+b.apiKey)
	req.Header.Set("User-Agent", b.userAgent)
	return b.do(req, out)
}

func (b *bridge) postJSON(path string, body []byte, out any) error {
	req, err := http.NewRequest(http.MethodPost, b.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+b.apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", b.userAgent)
	return b.do(req, out)
}

// postRaw runs a POST and returns the HTTP status + raw body without
// raising on 4xx/5xx. Used by tool invocations so the bridge can
// reshape 4xx into an MCP tool result (isError=true) instead of an
// opaque JSON-RPC error — gives the LLM the body it needs to retry.
func (b *bridge) postRaw(path string, body []byte, idemKey string) (int, []byte, error) {
	req, err := http.NewRequest(http.MethodPost, b.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+b.apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", b.userAgent)
	if idemKey != "" {
		req.Header.Set("Idempotency-Key", idemKey)
	}

	resp, err := b.http.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, respBody, nil
}

// getRaw mirrors postRaw for GET. Used by wait_for_run.
func (b *bridge) getRaw(path string) (int, []byte, error) {
	req, err := http.NewRequest(http.MethodGet, b.baseURL+path, nil)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+b.apiKey)
	req.Header.Set("User-Agent", b.userAgent)

	resp, err := b.http.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, respBody, nil
}

func (b *bridge) do(req *http.Request, out any) error {
	resp, err := b.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode >= 400 {
		return fmt.Errorf("emisar %s: %d %s", req.URL.Path, resp.StatusCode, strings.TrimSpace(string(body)))
	}

	if out == nil {
		return nil
	}
	return json.Unmarshal(body, out)
}

// -- helpers ---------------------------------------------------------

func okResp(id json.RawMessage, result any) *rpcResp {
	return &rpcResp{JSONRPC: "2.0", ID: id, Result: result}
}

func errorResp(id json.RawMessage, code int, msg string, data any) *rpcResp {
	return &rpcResp{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &rpcErr{Code: code, Message: msg, Data: data},
	}
}

func fatalln(args ...any) {
	fmt.Fprintln(os.Stderr, append([]any{"emisar-mcp:"}, args...)...)
	os.Exit(1)
}
