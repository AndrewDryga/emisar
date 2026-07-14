# mcp — how we build (Go, MCP stdio↔HTTP bridge)

`mcp` is a thin bridge: it forwards JSON-RPC frames from an MCP client's stdin to `POST /api/mcp/rpc` on the portal and writes correlated responses back to stdout. The bridge owns only transport invariants: bounded line framing, request-id correlation, Streamable HTTP headers, response validation, and notification silence. The portal owns every tool descriptor, content block, and synthetic tool. The one semantic exception is client-attested `run_action` dispatch (`sign.go`): it reads that tool's exact action, pack, argument bytes, runner refs, reason, and operation ID to create an Ed25519 execution attestation, because the signing key must stay client-side. Keep that boundary: new tool behavior belongs in the portal, not here.

**Dynamic action catalogs are server-owned.** Never require operators to mirror
current action ids into client `enabled_tools` / `includeTools` configuration:
runner scope, connectivity, and advertised packs change underneath such lists.
Large-catalog discovery is a portal contract; the bridge remains transport-only.

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

- **Small top-level production files plus the in-tree attestation package, stdlib only.** A new *external* dep needs a strong, stated reason.
  - **`main.go`** (~1,200 lines) — bounded concurrent stdio and Streamable HTTP transport, response validation, help/version. It may inspect only envelope metadata needed for transport correctness (`id`, notification and cancellation status, `initialize` protocol version); it must not interpret tools or content.
  - **`rotate.go` + `rotate_lock_*.go`** — client-prepared API-key rotation and its small platform lock adapters. Credential state is one owner-only file per canonical endpoint origin + bootstrap prefix; every transition is temp-write, file-sync, rename, then directory-sync. Endpoint-unbound state is never reused. Keep generation, persistence, acknowledgement, refresh, and activation ordered so a crash at any boundary leaves the configured/current key or the pending successor recoverable.
  - **`sign.go`** (~225 lines) — the client-attested-dispatch seam, and the only code that reads tool semantics. It keys off `method == "tools/call"` and exact `params.name == "run_action"`, preserves the public frame unchanged, and returns a private `Emisar-Attestation` header over the exact execution intent. Reads and other mutations are never signed merely because they use `tools/call`. Invalid tool input is forwarded for the portal's normal schema error; once a valid action reaches cryptographic signing, failure stops locally rather than silently sending it unsigned.
  - **`internal/attest/`** (~350 lines) — the canonical attestation encoding: the exact bytes the client signs and the runner verifies. **Duplicated VERBATIM in `runner/`** (separate Go modules, no shared import by design). Keep both implementations and fixed-vector constants identical in the same change; the root gate mechanically compares them.
- A `bridge` struct holds the endpoint, API key, user-agent, HTTP client, session id, negotiated protocol version, optional `signer`, and key-rotation state (`credentialStore`, `pendingKey`). `serve(io.Reader, io.Writer)` owns admission, in-flight ids, and serialized stdout while a fixed maximum of eight HTTP requests may run concurrently; `forward(frame)` POSTs with the Bearer token, a fixed-length typed idempotency digest, and MCP session/protocol headers. `notifications/cancelled` bypasses ordinary admission and targets one request generation. Untrusted HTTP bodies reach stdout only after status, media type, UTF-8, JSON-RPC shape, and response-id validation.
- **Key rotation:** only portal-compatible `emk-` secrets use local rotation state; OAuth and arbitrary Bearer tokens pass through unchanged. The bridge durably prepares a random successor, sends only its prefix + SHA-256 digest on `initialize`, and activates it only after the portal acknowledges that exact digest and the promotion is durable. Lost requests/responses retry the same pending key. The portal installs the proposal atomically and idempotently; first authenticated use of the successor retires its replaced chain. If durable client storage is unavailable, do not propose a successor. Every HTTP send refreshes the endpoint-bound state under the cross-process lock. Cancellation uses the current credential, and the portal authorizes a successor against only its immediate predecessor's request topic, so a peer promotion cannot strand an in-flight wait.
- **Security:** refuse cleartext `http://` to a non-loopback host (mirrors the runner's `cloud.allow_insecure`). The session id is random per process and namespaces idempotency. The signing key and the persisted successor key are secrets that stay on the client. The portal validates the bounded attestation envelope and exact target-set match before relaying it, but only the runner is the cryptographic authority.
- It's small enough that **stderr (`fatalln`) for startup errors is right — don't add `slog` ceremony.** A network failure becomes a synthetic JSON-RPC error response, never a closed pipe. Wrap errors with `fmt.Errorf("…: %w", err)`; tests are stdlib + table-driven.
- Operation detail is in [`README.md`](README.md).
