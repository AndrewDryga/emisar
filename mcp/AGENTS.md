# mcp — how we build (Go, MCP stdio↔HTTP bridge)

`mcp` is a thin bridge: it forwards every JSON-RPC frame from an MCP client's stdin to `POST /api/mcp/rpc` on the portal and writes the portal's response back to stdout. **The forwarding path contains zero MCP protocol logic** — the portal produces all tool descriptors, content blocks, and the synthetic `wait_for_run` tool. The one documented exception is client-attested dispatch (`sign.go`): it inspects `tools/call` frames to attach an Ed25519 signature over the action args, because the signing key must stay on the operator's client and never reach the control plane. Keep it that way: all *other* new MCP behavior belongs in the portal, not here.

Read the root `../AGENTS.md` (the creed) first; the Go house style is in `runner/AGENTS.md` and applies here too.

## The gate

Run from `mcp/`:

```
gofmt -l -s .                                       # zero output
go vet ./...
go mod tidy && git diff --exit-code -- go.mod go.sum
go test -race -count=1 ./...
```

## Shape

- **Two top-level production files plus the in-tree attestation package, stdlib only.** A new *external* dep needs a strong, stated reason.
  - **`main.go`** (~705 lines) — the zero-protocol forwarder: scan stdin, forward, key rotation, help/version. This is the part that "does nothing the portal couldn't."
  - **`sign.go`** (~225 lines) — the client-attested-dispatch seam, and the *only* code that reads MCP protocol. It keys off `method == "tools/call"` (then `params.name`/`params.arguments`) to attach an Ed25519 attestation over the action args and exact runner-id set, because the private key must live on the operator's client, never on the portal. It earns its own second file (the "strong reason" above); its header reasons the exception in full — read it before you fold it back into `main.go` or reject a signing change as "protocol creep." It **fails open**: any frame it can't cleanly sign is forwarded unchanged (an enforcing runner simply refuses an unsigned dispatch).
  - **`internal/attest/`** (~350 lines) — the canonical attestation encoding: the exact bytes the client signs and the runner verifies. **Duplicated VERBATIM in `runner/`** (separate Go modules, no shared import by design). Keep both implementations and fixed-vector constants identical in the same change; the root gate mechanically compares them.
- A `bridge` struct holds the endpoint, API key, user-agent, HTTP client, session id, the optional `signer`, and the key-rotation state (`bootstrapPrefix`, `credsPath`). `serve(io.Reader, io.Writer)` scans line-delimited JSON-RPC; `forward(frame)` POSTs with the Bearer token, an idempotency key, and the `Mcp-Session-Id` header.
- **Key rotation:** near an API key's expiry the portal returns a successor in the `initialize` response; the bridge adopts it in place (serve is single-goroutine, so plain field mutation is safe) and persists it to `<user-config-dir>/emisar/credentials.json` (dir `0700`, file `0600`, atomic rename), keyed by the original key's non-secret prefix — so the `EMISAR_API_KEY` in the client config keeps working across rotations without being edited.
- **Security:** refuse cleartext `http://` to a non-loopback host (mirrors the runner's `cloud.allow_insecure`). The session id is random per process and namespaces idempotency. The signing key and the persisted successor key are secrets that stay on the client. The portal validates the bounded attestation envelope and exact target-set match before relaying it, but only the runner is the cryptographic authority.
- It's small enough that **stderr (`fatalln`) for startup errors is right — don't add `slog` ceremony.** A network failure becomes a synthetic JSON-RPC error response, never a closed pipe. Wrap errors with `fmt.Errorf("…: %w", err)`; tests are stdlib + table-driven.
- Operation detail is in [`README.md`](README.md).
