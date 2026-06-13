# mcp — how we build (Go, MCP stdio↔HTTP bridge)

`mcp` is a thin bridge: it forwards every JSON-RPC frame from an MCP client's stdin to `POST /api/mcp/rpc` on the portal and writes the portal's response back to stdout. **It contains zero MCP protocol logic** — the portal produces all tool descriptors, content blocks, and the synthetic `wait_for_run` tool. Keep it that way: new MCP behavior belongs in the portal, not here.

Read the root `../AGENTS.md` (the creed) first; the Go house style is in `runner/AGENTS.md` and applies here too.

## The gate

Run from `mcp/`:

```
gofmt -l -s .                                       # zero output
go vet ./...
go mod tidy && git diff --exit-code go.mod go.sum
go test -race -count=1 ./...
```

## Shape

- **One file, `main.go`** (~330 lines), **stdlib only — no external dependencies.** A new dep here needs a strong, stated reason.
- A `bridge` struct holds the endpoint, API key, user-agent, session id, and HTTP client. `serve(io.Reader, io.Writer)` scans line-delimited JSON-RPC; `forward(frame)` POSTs with the Bearer token, an idempotency key, and the `MCP-Session-Id` header.
- **Security:** refuse cleartext `http://` to a non-loopback host (mirrors the runner's `cloud.allow_insecure`). The session id is random per process and namespaces idempotency.
- It's small enough that **stderr (`fatalln`) for startup errors is right — don't add `slog` ceremony.** A network failure becomes a synthetic JSON-RPC error response, never a closed pipe. Wrap errors with `fmt.Errorf("…: %w", err)`; tests are stdlib + table-driven.
- Operation detail is in `docs/mcp.md`.
