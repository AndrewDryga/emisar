# emisar MCP bridge

emisar exposes one MCP surface for discovering runners and packs, inspecting
declared action schemas, dispatching work, waiting for results, and reading the
audit trail. New packs add actions behind that same surface; clients do not need
a new server entry every time the infrastructure catalog changes.

The Go binary in this directory is the bridge for clients that launch MCP
servers over stdio. It forwards bounded JSON-RPC frames to the hosted HTTP
endpoint and keeps credentials and optional dispatch-signing keys on the client.
All tools, schemas, authorization, policy, approvals, and response content live
in the portal.

## Choose a connection

| Client capability | Connection | Local install |
| --- | --- | --- |
| Remote MCP with OAuth | `https://emisar.dev/api/mcp/rpc` | None |
| Local stdio MCP | `emisar-mcp` -> the same endpoint | Install the bridge |
| Direct HTTP with a scoped API key | `POST /api/mcp/rpc` | None |

Claude.ai, ChatGPT, and other remote OAuth clients should connect directly.
Claude Desktop, Claude Code, Cursor local mode, Codex CLI, Gemini CLI, Grok CLI,
Zed, Windsurf, and similar stdio clients can use the bridge.

The current per-client instructions are at
[emisar.dev/docs/connect-an-llm](https://emisar.dev/docs/connect-an-llm). The
dashboard's **LLM agents** page generates the exact configuration for the
signed-in operator and their runner scope.

## Install the stdio bridge

```sh
curl -sSL https://emisar.dev/install-mcp.sh | sudo bash
```

The installer resolves the latest tagged release, verifies its checksum, and
installs `emisar-mcp` in `/usr/local/bin`. Set
`INSTALL_DIR="$HOME/.local/bin"` for a no-sudo installation.

In an interactive terminal it then finds supported MCP clients and offers to
configure each one. Approve the device grant in the browser; emisar writes a
separate scoped key into every selected client config, so the raw key never
needs to pass through the clipboard. Existing client settings and other MCP
servers are preserved.

After installation, restart the client and confirm that the `emisar` server is
connected. Ask the agent to list available infrastructure or inspect a known
runner. You are done when the client can discover the in-scope action catalog;
run a low-risk action such as `linux.uptime` to certify execution and audit.

Use `emisar-mcp --help` for current registration commands and config locations.
Pin a reviewed release for managed rollouts:

```sh
curl -sSL https://emisar.dev/install-mcp.sh \
  | sudo bash -s -- --version mcp-vX.Y.Z --yes
```

## Manual configuration

The bridge is configured through the environment in the MCP client's server
entry:

| Variable | Required | Purpose |
| --- | --- | --- |
| `EMISAR_URL` | yes | Absolute portal origin with no path, query, fragment, or credentials, for example `https://emisar.dev` |
| `EMISAR_API_KEY` | yes | Operator API key sent as a Bearer token |
| `EMISAR_CLIENT` | no | Client label recorded with audit attribution |
| `EMISAR_CLIENT_METADATA` | no | Self-reported JSON metadata for audit/SIEM correlation; at most 10 string keys with string or number values |
| `EMISAR_ALLOW_INSECURE` | no | Set to `1` only for an intentional non-loopback HTTP development endpoint; loopback HTTP already works |
| `EMISAR_SIGNING_KEY` | no | Ed25519 leaf private-key seed used for client-attested dispatch |
| `EMISAR_SIGNING_CERT` | no | CA-signed certificate for `EMISAR_SIGNING_KEY`; required with it |

Client metadata is untrusted enrichment. It is never used for authorization,
posture, policy, or approval. Keys are limited to 128 characters, values to 512
characters, and invalid metadata stops the bridge at startup.

For example, a generic stdio client entry has this shape:

```json
{
  "mcpServers": {
    "emisar": {
      "command": "emisar-mcp",
      "env": {
        "EMISAR_URL": "https://emisar.dev",
        "EMISAR_API_KEY": "emk-...",
        "EMISAR_CLIENT": "my-client"
      }
    }
  }
}
```

Do not commit this configuration with a real key. API keys inherit the member's
runner scope and the account's server-side policy; use a separate key per client
so attribution and revocation stay precise.

## What the bridge owns

The bridge is intentionally thin. It owns only the client-to-portal transport:

- line-delimited JSON-RPC on stdin and stdout;
- bounded request and response frames;
- request-ID correlation and concurrent-duplicate rejection;
- MCP protocol and Streamable HTTP headers;
- response status, media type, UTF-8, envelope, and ID validation;
- cancellation of observation without claiming to undo committed work;
- endpoint-bound API-key rotation state;
- optional client-side signing for `run_action`.

It writes only validated MCP frames to stdout. Diagnostics stay on stderr. A
network failure becomes a correlated JSON-RPC error instead of corrupting the
client stream.

The portal owns every tool and semantic response. The normative contract is
[`docs/mcp-api-spec.md`](../docs/mcp-api-spec.md) with machine-readable schemas
in [`docs/mcp-api-schemas.json`](../docs/mcp-api-schemas.json). Server-side tool
changes do not require a bridge release.

## Transport identity and recovery

The bridge admits at most eight concurrent requests within a 1 MiB aggregate
request budget. Each request is capped at 128 KiB, each response at 512 KiB,
and decoded string IDs and integer decimal forms at 4,096 bytes. Its 90-second
HTTP deadline stays above the portal's 60-second wait cap, so pings and unrelated
calls remain responsive during a wait.

Every admitted `tools/call` receives a private, bounded operation identity
derived from the bridge process and request sequence. The portal reserves that
identity with mutations under the API-key rotation lineage. An identical retry
returns the original resource; changed facts or a different mutation conflict.
If the client loses a mutation response, `get_operation` is the recovery path
when the transport error includes an operation ID. Reads retry normally.

JSON-RPC request IDs may be reused after completion; only concurrent duplicates
are rejected. Cancellation after a request is sent stops observation only. It
does not assert that infrastructure work was rolled back or never committed.

## API-key rotation

Expiring MCP API keys rotate through a crash-safe, client-prepared exchange:

1. The bridge generates a successor and persists it as pending before making a
   request.
2. It sends only the successor prefix and digest. The portal installs those
   exact values atomically when the current key enters its rotation window.
3. The bridge promotes the acknowledged successor durably before using it.
   First successful use retires the replaced key chain.

Credential state is stored per canonical endpoint and bootstrap prefix under
the user's emisar config directory. The directory is mode 0700; files are mode
0600 and updated through a cross-process lock, temporary write, filesystem sync,
and atomic rename. Corrupt or endpoint-mismatched state is a startup error, not
a reason to send a secret to another origin.

If durable storage is unavailable, the bridge keeps using the configured key
but does not offer automatic rotation. Containers should persist `/config`.
OAuth tokens, arbitrary Bearer tokens, non-expiring quick-connect keys, and
audit-export tokens bypass local rotation state.

## Client-attested dispatch

`EMISAR_SIGNING_KEY` and `EMISAR_SIGNING_CERT` let the bridge sign the exact
`run_action` intent: portal origin, action, immutable pack, arguments, complete
runner set, reason, operation identity, nonce, and time. A signature-enforcing
runner verifies that intent against a trusted offline CA and refuses altered,
replayed, stale, or out-of-scope calls.

Signing is the only place where the bridge inspects tool semantics. The public
MCP frame remains unchanged; the attestation travels in a private HTTP header.
Setup and rotation are documented in
[`docs/signed-dispatch.md`](../docs/signed-dispatch.md).

## Development

Build and run from the repository root:

```sh
(cd mcp && go build -o ../bin/emisar-mcp .)
EMISAR_URL=http://localhost:4000 \
EMISAR_API_KEY=emk-... \
  ./bin/emisar-mcp
```

The module gate is:

```sh
cd mcp
gofmt -l -s .
go vet ./...
go mod tidy
test ! -e go.sum
git diff --exit-code -- go.mod
go test -race -count=1 ./...
```

The forwarding path lives in `main.go`; key rotation lives in `rotate.go`; and
`sign.go` is the only tool-aware code. The attestation implementation under
`internal/attest` is duplicated deliberately in the runner module and must stay
byte-identical. Read [`AGENTS.md`](AGENTS.md) before changing the boundary.
