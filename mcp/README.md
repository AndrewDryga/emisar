# MCP bridge

emisar exposes the fleet's action catalog to MCP-aware clients (Claude
Desktop, Claude Code, Cursor, Gemini CLI, Codex CLI, Grok, …) so an LLM can
run real infrastructure actions — gated by the same policy, approval,
and audit machinery as a human operator.

Two transports, one surface:

- **stdio bridge** — `emisar-mcp`, a single self-contained Go binary
  the client launches as a child process. It proxies JSON-RPC frames to
  `POST /api/mcp/rpc`, validates correlated protocol responses, and writes
  only valid MCP frames to stdout. Tool descriptors, content blocks, and
  action semantics remain in the portal.
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

Run `emisar-mcp --help` for compact registration instructions for Claude
Desktop, Claude Code, Cursor, Codex, and Grok, including complete JSON for the
desktop clients and current CLI command forms.

| Env var | Required | Purpose |
| --- | --- | --- |
| `EMISAR_URL` | yes | Absolute HTTP(S) portal origin, with no path, credentials, query, or fragment (for example `https://emisar.dev`) |
| `EMISAR_API_KEY` | yes | Operator API key (`Bearer` on every request) |
| `EMISAR_CLIENT` | no | Client label for audit attribution (`claude-code`, `cursor`, `codex`, `grok`, …) |
| `EMISAR_CLIENT_METADATA` | no | Self-reported client metadata as a JSON object of string keys to string/number values (e.g. `{"asset_tag":"LT-4417","device_id":"…"}`), snapshotted onto each MCP action run so activity can be correlated with your own MDM/EDR/inventory in the audit log + SIEM export. Limits: ≤10 keys, keys ≤128 / values ≤512 chars. Untrusted, self-reported enrichment — never used for authorization, posture, or approval. Invalid metadata is a startup error. |
| `EMISAR_ALLOW_INSECURE` | no | Set to `1` only for an intentional non-loopback HTTP development endpoint. Loopback HTTP works without it; production should use HTTPS. |
| `EMISAR_SIGNING_KEY` | no | Ed25519 leaf private key (64-hex seed) used to sign each dispatch so signature-enforcing runners will run it. Keep it secret — never on the portal. See [`docs/signed-dispatch.md`](../docs/signed-dispatch.md). |
| `EMISAR_SIGNING_CERT` | no | The CA-signed certificate (JSON) vouching for `EMISAR_SIGNING_KEY` — required with it. Minted by `emisar signing new-cert` / `emisar signing init`; the runner verifies it against its trusted CA before running the dispatch. |

### Client compatibility

The bridge is exercised against current Claude Code, Cursor, Codex, Gemini, and
Grok client configuration shapes before release. Run `emisar-mcp --help` for
the registration commands and JSON paths. Client certification is
version-specific transport evidence; authorization remains server-side.

The fixed twelve-tool catalog keeps `tools/list` near 14 KiB so clients load the
full surface. Against a local portal, Claude Code, Codex, Gemini CLI, and Grok
CLI connect to the bridge and Grok's MCP doctor reports all twelve tools after
handshake. Read and mutation authorization still happen only on the portal.

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

`tools/list` is fixed at twelve tools regardless of fleet or pack size:

- `list_packs`, `list_runners`, `find_actions`, and `get_action` discover the
  current trusted catalog without embedding hundreds of schemas in tool setup.
- `run_action` dispatches one exact action contract to explicit generation-bound
  runner references.
- `get_operation`, `wait_for_run`, and `recent_runs` recover ambiguous mutations,
  wait for state changes, and inspect scoped history.
- `list_runbooks`, `get_runbook`, `execute_runbook`, and
  `create_runbook_draft` expose the governed runbook workflow.

The discovery flow is `find_actions` -> `get_action` -> `run_action`.
`get_action` returns the exact argument schema and compatible runners;
`run_action` revalidates scope, connectivity, pack trust, schema, policy, and
approval against current state. Defaults are 15 results, with authenticated
cursors for additional pages. See [`docs/mcp-api-spec.md`](../docs/mcp-api-spec.md)
for the complete contract.

Every action call must include a `reason` string — it's recorded on
the run and shown to operators in the audit log.

Catalog reads are point-in-time observations. `get_action` and `run_action`
re-resolve current runner scope, connectivity, descriptor parity, and pack
trust; a stale contract returns one generic refresh continuation without
disclosing which hidden fact changed.

## Dispatch semantics

A `tools/call` flows: scope check → policy evaluation (risk-tier
defaults + per-action overrides, default-deny) → grant fast-path
(an unexpired standing approval matching key/action/runner/args) →
either immediate dispatch, an approval request (`pending_approval`
content tells the LLM to wait or escalate), or a refusal.

For each mutation, the bridge derives a bounded operation ID from its random
session and the JSON-RPC request ID's exact type and value. The portal reserves
that ID under the API-key rotation lineage in the same transaction as the
mutation. An identical retry returns the original resource; changed facts or a
different mutation tool conflict. Numeric `7` and string `"7"`, and different
bridge sessions, never alias. `get_operation` is the recovery path after an
ambiguous transport failure: the bridge's correlated JSON-RPC error includes
the operation ID and a typed `get_operation` continuation. Reads carry no
operation header.

Request IDs are one-use within a bridge session. The bridge permits eight
in-flight requests within a 1 MiB aggregate request budget, caps each request at
128 KiB and each response at 512 KiB, and bounds decoded string IDs and integer
decimal forms to 4,096 bytes so every accepted ID can be echoed inside that
response ceiling. It keeps a 330-second HTTP deadline above the portal's
five-minute wait cap. Pings and unrelated calls remain responsive during a
wait. Cancellation after send stops observation only; it never claims to undo
committed infrastructure work.

## Attribution + audit

Every request carries `User-Agent: emisar-mcp/<version>
(client=<EMISAR_CLIENT>; host=<hostname>; os=<goos>)` and a stable
`Mcp-Session-Id`. The portal snapshots MCP client info on dispatch, so
audit rows answer "which tool, which client, which key, why" — the
`reason` requirement closes the loop.

## Key auto-rotation

MCP keys default to a 30-day expiry. When the bridge initializes with a
key expiring within 7 days, rotation uses a crash-safe two-phase exchange:

1. The bridge generates a successor with the operating system CSPRNG and
   durably records it as pending before making the request.
2. `initialize` sends only the successor's lookup prefix and SHA-256 digest.
   The portal atomically installs those exact values and acknowledges the
   digest. A retry of the same proposal returns the same acknowledgement.
3. The bridge durably promotes the pending key before using it. The old key
   remains usable until the successor's first authenticated request proves the
   swap, at which point the portal retires the replaced key chain.

The raw successor is absent from the rotation proposal and acknowledgement. It
first reaches the portal later as the ordinary Authorization bearer after the
bridge has durably activated it. Lost requests, lost responses, process
restarts, and persistence failures therefore leave at least one recoverable
credential. The rotation is recorded as
`api_key.auto_rotated`; retirement is recorded separately as
`api_key.retired_by_rotation`.

Credential state lives in one 0600 file per canonical endpoint origin and
bootstrap prefix under
`<user-config-dir>/emisar/credentials/`, protected by a 0700 directory,
cross-process locking, atomic rename, and filesystem sync. The
`EMISAR_API_KEY` in the client config is never edited; every launch resolves
that endpoint-bound bootstrap prefix to the current secret, and live bridge
processes refresh peer promotions before every request. Corrupt state and the
old endpoint-unbound v1 format are startup errors rather than reasons to send a
stored secret to an unverified origin. If no durable config directory is
available, the bridge continues with the configured key but does not offer
automatic rotation. Container users must mount `/config` persistently. OAuth
and arbitrary Bearer tokens bypass local rotation state; remote connectors,
non-expiring quick-connect keys, and audit-export tokens do not auto-rotate.
Operators can rotate a key manually from the Agents page at any time.

## Development

Build and run the bridge from the repository root:

```sh
(cd mcp && go build -o ../bin/emisar-mcp .)
EMISAR_URL=http://localhost:4000 \
EMISAR_API_KEY=emk-... \
  ./bin/emisar-mcp
```

The process reads one JSON-RPC frame per stdin line, rejects malformed envelopes
locally, and writes only validated, request-correlated JSON-RPC to stdout.
Diagnostics go to stderr. A network failure becomes a generic synthetic error
carrying the original request id; notification failures remain silent.

The module gate is:

```sh
cd mcp
gofmt -l -s .
go vet ./...
go mod tidy && git diff --exit-code -- go.mod go.sum
go test -race -count=1 ./...
```

The forwarding path lives in `main.go`; `sign.go` is the only code that inspects
`tools/call`, solely to attach client-attested `run_action` data. The canonical
attestation encoding under `internal/attest` is duplicated deliberately in the
runner module. Attestation v4 binds the action ID, immutable pack ref, digest of
the exact JSON argument bytes, complete sorted runner refs, reason, operation
ID, portal origin, nonce, and timestamp. The root gate compares both
implementations and fixed vectors so the bridge and runner cannot silently
disagree on those bytes.
