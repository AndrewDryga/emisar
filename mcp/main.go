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
//	        "EMISAR_URL":     "https://app.emisar.com",
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
                    e.g. https://app.emisar.com
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
		baseURL: url,
		apiKey:  apiKey,
		http:    &http.Client{Timeout: httpTimeout},
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
	baseURL string
	apiKey  string
	http    *http.Client
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
		result, err := b.callTool(p.Name, p.Arguments)
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
	out := make([]map[string]any, 0, len(body.Tools))
	for _, t := range body.Tools {
		out = append(out, map[string]any{
			"name":        t["name"],
			"description": t["description"],
			"inputSchema": t["inputSchema"],
		})
	}
	return out, nil
}

func (b *bridge) callTool(name string, args map[string]any) (map[string]any, error) {
	if name == "" {
		return nil, errors.New("missing tool name")
	}

	// Synchronous: long-poll up to 60s for a terminal state. If the
	// run requires approval or doesn't terminate in time, the cloud
	// returns 202 with `status: "pending_approval"` or
	// `status: "running"`; we surface that to the LLM.
	payload, _ := json.Marshal(map[string]any{
		"args": args,
	})

	var result map[string]any
	err := b.postJSON("/api/mcp/tools/"+name+"?wait=60s", payload, &result)
	if err != nil {
		return nil, err
	}

	// Translate emisar's response into an MCP `tools/call` result —
	// an array of `content` items. The LLM sees stdout (or the
	// pending-approval marker) as the tool output text.
	content := []map[string]any{}

	if s, _ := result["stdout"].(string); s != "" {
		content = append(content, map[string]any{"type": "text", "text": s})
	}

	if s, _ := result["stderr"].(string); s != "" {
		content = append(content, map[string]any{
			"type": "text",
			"text": "stderr:\n" + s,
		})
	}

	if status, _ := result["status"].(string); status != "" && status != "success" {
		content = append(content, map[string]any{
			"type": "text",
			"text": fmt.Sprintf("emisar status: %s", status),
		})
	}

	if len(content) == 0 {
		content = append(content, map[string]any{
			"type": "text",
			"text": "(no output)",
		})
	}

	isError := false
	if exit, ok := result["exit_code"].(float64); ok && exit != 0 {
		isError = true
	}

	return map[string]any{
		"content": content,
		"isError": isError,
	}, nil
}

// -- HTTP helpers ----------------------------------------------------

func (b *bridge) get(path string, out any) error {
	req, err := http.NewRequest(http.MethodGet, b.baseURL+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+b.apiKey)
	return b.do(req, out)
}

func (b *bridge) postJSON(path string, body []byte, out any) error {
	req, err := http.NewRequest(http.MethodPost, b.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+b.apiKey)
	req.Header.Set("Content-Type", "application/json")
	return b.do(req, out)
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
