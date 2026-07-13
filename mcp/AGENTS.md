# mcp — how we build (Go, MCP stdio↔HTTP bridge)

`mcp` is a thin bridge: it forwards JSON-RPC frames from an MCP client's stdin to `POST /api/mcp/rpc` on the portal and writes correlated responses back to stdout. The bridge owns only transport invariants: bounded line framing, request-id correlation, Streamable HTTP headers, response validation, and notification silence. The portal owns every tool descriptor, content block, and synthetic tool. The one semantic exception is client-attested dispatch (`sign.go`): it inspects `tools/call` frames to attach an Ed25519 signature over the action args, because the signing key must stay client-side. Keep that boundary: new tool behavior belongs in the portal, not here.

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
  - **`main.go`** (~950 lines) — stdio and Streamable HTTP transport, response validation, key rotation, help/version. It may inspect only envelope metadata needed for transport correctness (`id`, notification status, `initialize` protocol version); it must not interpret tools or content.
  - **`sign.go`** (~225 lines) — the client-attested-dispatch seam, and the only code that reads tool semantics. It keys off `method == "tools/call"` (then `params.name`/`params.arguments`) to attach an Ed25519 attestation over the action args and exact runner-id set, because the private key must live on the operator's client, never on the portal. It earns its own second file (the "strong reason" above); its header reasons the exception in full — read it before you fold it back into `main.go` or reject a signing change as "protocol creep." It **fails open**: any frame it can't cleanly sign is forwarded unchanged (an enforcing runner simply refuses an unsigned dispatch).
  - **`internal/attest/`** (~350 lines) — the canonical attestation encoding: the exact bytes the client signs and the runner verifies. **Duplicated VERBATIM in `runner/`** (separate Go modules, no shared import by design). Keep both implementations and fixed-vector constants identical in the same change; the root gate mechanically compares them.
- A `bridge` struct holds the endpoint, API key, user-agent, HTTP client, session id, negotiated protocol version, optional `signer`, and key-rotation state (`bootstrapPrefix`, `credsPath`). `serve(io.Reader, io.Writer)` scans line-delimited JSON-RPC; `forward(frame)` POSTs with the Bearer token, a fixed-length typed idempotency digest, and MCP session/protocol headers. Untrusted HTTP bodies reach stdout only after status, media type, UTF-8, JSON-RPC shape, and response-id validation.
- **Key rotation:** near an API key's expiry the portal returns a successor in the `initialize` response; the bridge adopts it in place (serve is single-goroutine, so plain field mutation is safe) and persists it to `<user-config-dir>/emisar/credentials.json` (dir `0700`, file `0600`, atomic rename), keyed by the original key's non-secret prefix — so the `EMISAR_API_KEY` in the client config keeps working across rotations without being edited.
- **Security:** refuse cleartext `http://` to a non-loopback host (mirrors the runner's `cloud.allow_insecure`). The session id is random per process and namespaces idempotency. The signing key and the persisted successor key are secrets that stay on the client. The portal validates the bounded attestation envelope and exact target-set match before relaying it, but only the runner is the cryptographic authority.
- It's small enough that **stderr (`fatalln`) for startup errors is right — don't add `slog` ceremony.** A network failure becomes a synthetic JSON-RPC error response, never a closed pipe. Wrap errors with `fmt.Errorf("…: %w", err)`; tests are stdlib + table-driven.
- Operation detail is in [`README.md`](README.md).
