# MCP bridge

emisar exposes the fleet's action catalog to MCP-aware clients (Claude
Desktop, Claude Code, Cursor, Gemini CLI, Codex CLI, …) so an LLM can
run real infrastructure actions — gated by the same policy, approval,
and audit machinery as a human operator.

Two transports, one surface:

- **stdio bridge** — `emisar-mcp`, a single self-contained Go binary
  the client launches as a child process. It proxies JSON-RPC frames
  verbatim to `POST /api/mcp/rpc` and writes responses back to stdout.
  No MCP logic lives in the bridge; the portal generates all tool
  descriptors and content blocks.
- **REST** — `GET /api/mcp/runners`, `GET /api/mcp/tools`,
  `POST /api/mcp/tools/:action_id`, `GET /api/mcp/runs/:id` for
  integrations that prefer plain HTTP over JSON-RPC.

## Bridge install + client config

```sh
curl -sSL https://emisar.dev/install-mcp.sh | sudo bash
```

Drops `emisar-mcp` into `/usr/local/bin` (checksum-verified from
GitHub releases; `INSTALL_DIR=$HOME/.local/bin` for a no-sudo
install). The bridge is configured per client via env vars in the
launcher's JSON/TOML config — the portal's **/app/agents** page
generates the exact snippet per client:

| Env var | Required | Purpose |
| --- | --- | --- |
| `EMISAR_URL` | yes | Portal base URL |
| `EMISAR_API_KEY` | yes | Operator API key (`Bearer` on every request) |
| `EMISAR_CLIENT` | no | Client label for audit attribution (`claude-code`, `cursor`, …) |
| `EMISAR_CLIENT_METADATA` | no | Self-reported client metadata as a JSON object of string keys to string/number values (e.g. `{"asset_tag":"LT-4417","device_id":"…"}`), snapshotted onto each MCP action run so activity can be correlated with your own MDM/EDR/inventory in the audit log + SIEM export. Limits: ≤10 keys, keys ≤128 / values ≤512 chars. Untrusted, self-reported enrichment — never used for authorization, posture, or approval. Invalid metadata is a startup error. |
| `EMISAR_ALLOW_INSECURE` | no | Set to `1` only for an intentional non-loopback HTTP development endpoint. Loopback HTTP works without it; production should use HTTPS. |
| `EMISAR_SIGNING_KEY` | no | Ed25519 leaf private key (64-hex seed) used to sign each dispatch so signature-enforcing runners will run it. Keep it secret — never on the portal. See [`docs/signed-dispatch.md`](../docs/signed-dispatch.md). |
| `EMISAR_SIGNING_CERT` | no | The CA-signed certificate (JSON) vouching for `EMISAR_SIGNING_KEY` — required with it. Minted by `emisar signing new-cert` / `emisar signing init`; the runner verifies it against its trusted CA before running the dispatch. |

## Auth

Two credential types, both hashed at rest:

- **API keys** — minted on the portal (the Agents page auto-mints one
  so the snippet renders pre-filled; it stays hidden from lists until
  an LLM actually authenticates with it).
- **OAuth** — full RFC 8414 / RFC 9728 metadata + dynamic client
  registration (`POST /oauth/register`), authorization with a human
  consent screen, PKCE **S256 only**, token exchange at
  `POST /oauth/token`. Access tokens (`emo-*`) resolve to a backing
  API key that carries scope + attribution.

Scopes: `actions:read` (catalog), `actions:execute` (dispatch),
`audit:read` (the NDJSON export at `GET /api/audit`). Per-user runner
ACLs additionally narrow which runners a key can even see.

## Tool surface

`tools/list` returns one tool per catalog action (grouped across the
runners that advertise it, with a `runners` enum arg for fan-out) plus
three synthetic tools:

- `wait_for_run` — long-poll a run to terminal status. Accepts
  `run_id` + `timeout` (`"15s"`, `"1m"`, capped at 90s); resolves
  early on the run's pub/sub broadcast, re-checks status, and returns
  `waiting` (with current state) on timeout rather than erroring.
- `list_runbooks` — published runbooks with summaries.
- `get_runbook` — one runbook's ordered steps, runner targets resolved
  to current runner names. The cloud does NOT execute runbooks for the
  LLM over MCP — the client dispatches each step itself, in order,
  honoring each step's risk/approval.

Every action call must include a `reason` string — it's recorded on
the run and shown to operators in the audit log.

`tools/list` is a point-in-time snapshot: runner connectivity and pack
trust are resolved at dispatch time, not list time. Catalog-shaped
errors (`pack_untrusted`, "No runner advertises <action>", "No runner
in scope") mean *refresh the list and tell the human*, not *retry in a
loop* — `pack_untrusted` in particular clears only when an operator
trusts the pack version on the Packs page.

## Dispatch semantics

A `tools/call` flows: scope check → policy evaluation (risk-tier
defaults + per-action overrides, default-deny) → grant fast-path
(an unexpired standing approval matching key/action/runner/args) →
either immediate dispatch, an approval request (`pending_approval`
content tells the LLM to wait or escalate), or a refusal.

Idempotency: the bridge stamps every request that has a JSON-RPC `id`
with `Idempotency-Key: <session>:<id>` (the session id is random per
bridge process). Client retries collapse onto the same run row —
different clients never alias. The portal answers notifications with
202 and methods with a JSON-RPC result/error; the bridge's HTTP
timeout (120s) leaves headroom over the portal's 90s long-poll cap.

## Attribution + audit

Every request carries `User-Agent: emisar-mcp/<version>
(client=<EMISAR_CLIENT>; host=<hostname>; os=<goos>)` and a stable
`Mcp-Session-Id`. The portal snapshots MCP client info on dispatch, so
audit rows answer "which tool, which client, which key, why" — the
`reason` requirement closes the loop.

## Key auto-rotation

MCP keys default to a 30-day expiry. When the bridge initializes with a
key expiring within 7 days, the portal mints a scope-preserving
successor **exactly once** (the source row is marked `rotated_to_id`;
concurrent sessions can't double-mint) and returns it in the
`X-Emisar-Successor-Key` / `X-Emisar-Successor-Expires-At` response
headers — never the JSON-RPC body, which the bridge forwards verbatim
into the LLM transcript. The old key keeps working until its own expiry
(the overlap window), and the rotation lands in the audit log as
`api_key.auto_rotated`.

The bridge adopts the successor immediately and persists it to
`<user-config-dir>/emisar/credentials.json` (dir 0700, file 0600),
keyed by the *bootstrap* key's prefix — the `EMISAR_API_KEY` in the
client's config is never edited; every launch resolves that bootstrap
key to the current secret, so chained rotations keep working. If the
credentials file can't be written the swap still holds for the running
session. Remote connectors that hit `/api/mcp/rpc` directly ignore
response headers, so the portal only offers a successor to the bridge's
`emisar-mcp/` User-Agent; quick-connect keys (no expiry) and
audit-export tokens never rotate. Rotate manually anytime from the
Agents page — the auto path just removes the deadline.

## Development

Build and run the bridge from the repository root:

```sh
(cd mcp && go build -o ../bin/emisar-mcp .)
EMISAR_URL=http://localhost:4000 \
EMISAR_API_KEY=emk-... \
  ./bin/emisar-mcp
```

The process reads one JSON-RPC frame per stdin line and writes only JSON-RPC to
stdout. Diagnostics go to stderr. A network failure becomes a synthetic JSON-RPC
error so the MCP client process stays alive.

The module gate is:

```sh
cd mcp
gofmt -l -s .
go vet ./...
go mod tidy && git diff --exit-code -- go.mod go.sum
go test -race -count=1 ./...
```

The forwarding path lives in `main.go`; `sign.go` is the only code that inspects
`tools/call`, solely to attach client-attested dispatch data. The canonical
attestation encoding under `internal/attest` is duplicated deliberately in the
runner module and pinned by cross-implementation vectors.
