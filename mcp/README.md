# emisar MCP bridge

emisar exposes one MCP surface for discovering runners and packs, inspecting
declared action schemas, dispatching work, waiting for results, and reviewing
recent run history. New packs add actions behind that same surface; clients do not need
a new server entry every time the infrastructure catalog changes.

The Go binary in this directory is the bridge for clients that launch MCP
servers over stdio. It forwards bounded JSON-RPC frames to the hosted HTTP
endpoint and keeps credentials and optional dispatch-signing keys on the client.
All tools, schemas, authorization, policy, approvals, and response content live
in the control plane.

## Choose a connection

| Client capability | Connection | Local install |
| --- | --- | --- |
| Remote MCP with OAuth | `https://emisar.dev/api/mcp/rpc` | None |
| Local stdio MCP | `emisar-mcp` -> the same endpoint | Install the bridge |
| Direct HTTP with a scoped API key | `POST /api/mcp/rpc` | None |

Claude.ai, ChatGPT, and other remote OAuth clients should connect directly.
Claude Desktop, Claude Code, Cursor local mode, VS Code, Codex CLI, Gemini CLI,
Grok CLI, Zed, Windsurf, and similar stdio clients can use the bridge.

The current per-client instructions are at
[emisar.dev/docs/connect-cli-agent](https://emisar.dev/docs/connect-cli-agent). The
dashboard's **AI agents** page generates the exact configuration for the
signed-in operator and their runner scope.

## Install the stdio bridge

macOS or Linux:

```sh
curl -fsSL https://emisar.dev/install-mcp.sh | sudo bash
```

Windows PowerShell:

```powershell
irm https://emisar.dev/install-mcp.ps1 | iex
```

Both installers resolve the latest tagged release and verify its checksum. The
Unix installer puts `emisar-mcp` in `/usr/local/bin`; set
`INSTALL_DIR="$HOME/.local/bin"` for a no-sudo installation. The Windows
installer puts `emisar-mcp.exe` in the current user's Programs directory and
adds that directory to the user's `PATH`.

In an interactive terminal it opens one browser approval. That approval gives
the direct CLI its own key and, when supported MCP clients are present, offers
to configure each one with a separate key. The CLI key goes into owner-only
bridge state; client keys go into their client configs. No key passes through
the clipboard, and existing client settings and other MCP servers are
preserved. VS Code is the exception: its key goes into an owner-only environment
file referenced by the user-level `mcp.json`, because editor settings may sync.

You can authenticate the direct CLI without rerunning the installer. This opens
the approval page in your browser and stores a dedicated CLI key locally:

```sh
emisar-mcp auth
emisar-mcp list_tools
```

Authenticate each account once. The last account you authenticate becomes the
current account for bare commands. List your stored accounts, change the
current one, or choose one for a single command:

```sh
emisar-mcp auth
emisar-mcp accounts list
emisar-mcp accounts use immersive
emisar-mcp --account blitz list_runners
```

`accounts list` shows a star beside the current account. Add `--json` for a
script-friendly list. Account names and slugs come from the account you approved
in the browser; they are not local aliases. The credential remains tied to the
account's immutable ID if its name or slug changes.

Credentials follow the operating system's user config directory:
`~/Library/Application Support/emisar/credentials/` on macOS,
`$XDG_CONFIG_HOME/emisar/credentials/` on Linux when that variable is set
(otherwise `~/.config/emisar/credentials/`), and the user's AppData config
directory on Windows. The directory and files are owner-only. This is why macOS
does not put them under `~/.config`.

A later interactive installer run verifies the stored CLI credential against
the same endpoint and keeps it instead of minting another one. Run
`emisar-mcp auth` to replace a revoked or expired direct-CLI credential through
the same browser approval without reinstalling anything.

After installation, restart the client and confirm that the `emisar` server is
connected. Ask the agent to list available infrastructure or inspect a known
runner. You are done when the client can discover the in-scope action catalog;
run a low-risk action such as `linux.uptime` to certify execution and audit.

Run `emisar-mcp` in a terminal to see its command help. You can run any name
shown by `list_tools`, including `list_runners`. MCP clients start the same
program automatically and send MCP requests through stdin.
Use `emisar-mcp --help` for current registration commands and config locations.
Pin a reviewed release for managed rollouts:

```sh
curl -fsSL https://emisar.dev/install-mcp.sh \
  | sudo bash -s -- --version mcp-vX.Y.Z --yes
```

## Manual MCP-client configuration

Stdio MCP clients are configured through the environment in their server
entry, directly or through a referenced environment file. They never inherit
the direct CLI's stored credential:

| Variable | Required | Purpose |
| --- | --- | --- |
| `EMISAR_URL` | yes | Absolute control-plane origin with no path, query, fragment, or credentials, for example `https://emisar.dev` |
| `EMISAR_API_KEY` | yes | Operator API key sent as a Bearer token |
| `EMISAR_CLIENT` | no | Client label recorded with audit attribution |
| `EMISAR_CLIENT_METADATA` | no | Self-reported JSON metadata for audit/SIEM correlation; at most 10 string keys with string or number values |
| `EMISAR_ALLOW_INSECURE` | no | Set to `1` only for an intentional non-loopback HTTP development endpoint; loopback HTTP already works |
| `EMISAR_SIGNING_KEY` | no | Ed25519 leaf private-key seed used for bridge-attested dispatch |
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

## Use MCP tools from the shell

The same binary exposes the control plane's live MCP catalog as direct commands.
Names, descriptions, annotations, and argument schemas come from `tools/list`.
The thirteen fixed tools have purpose-built human output; an unknown future
tool still appears and remains callable through the generic fallback.

An interactive install authenticates these commands. Discover and inspect the
available tools directly:

```sh
emisar-mcp list_tools
emisar-mcp help find_actions
emisar-mcp get_action --help
```

`emisar-mcp auth` opens browser approval and stores the account you choose. Use
`emisar-mcp auth login [URL]` for a custom endpoint. `auth status` checks the
current account's local state without contacting the control plane or printing
the key. `accounts list` shows stored accounts; `accounts use <slug-or-id>`
changes the current one. A leading `--account <slug-or-id>` selects one account
for one command without changing the current account. Use
`accounts list --json` when you need an immutable account ID.

For a one-off endpoint, set `EMISAR_URL` and `EMISAR_API_KEY` together. That
explicit pair overrides stored credentials. Setting only one is an error—the
bridge never combines an environment value with half of a stored credential.
Do not combine the explicit pair with `--account`.
Stdio mode ignores direct-CLI account storage and still requires both variables
in its MCP-client configuration.

Plain `list_tools` groups the live catalog into Fleet, Actions, Runbooks, and
Continuations. `list_tools --json` prints the exact descriptor array.
`help <tool> --json` prints one exact descriptor, including its complete input
schema. Human-readable help summarizes top-level arguments. It calls out
conditional or mutually exclusive arguments, but the complete input schema
remains authoritative.

### Scripts and LLMs

Use `--json` for automation. It makes one logical tool invocation, follows no
continuations, and prints the exact `structuredContent` object with pretty
whitespace only. The transport may resend that identical request once, under
the same operation ID, after a network failure. Put `--json` last, pass `-` to
read one JSON object from stdin, and parse stdout as JSON. Diagnostics stay on
stderr and pipes never contain color.

```sh
emisar-mcp find_actions "diagnose postgres replication" --json |
  jq -ce '.candidates[0].next.arguments' |
  emisar-mcp get_action - --json
```

Without `--json`, every fixed tool uses a view made for a terminal. Fleet
results show inventory, action details show their trusted argument contract,
runs show status and output, and runbooks show their workflow and stage state.
These views are for people; scripts should use `--json`.

### Fleet

Fleet commands omit protocol fields such as `ok` and `observed_at`, summarize
large catalogs, and leave line wrapping to your terminal.

| Command | What it shows | Input worth knowing |
| --- | --- | --- |
| `list_runners` | Runner status, hostname, group, labels, available packs, issues, and exact `runner_ref` values | Use JSON to filter by status, runner name/group/host text, runner refs, pack, action, or issues. |
| `list_packs` | Trusted pack versions, availability, action counts, exact `pack_ref` values, and a command that finds the pack's actions | The default is executable packs. Pass `{"availability":"all"}` to include trusted unavailable packs. |

```sh
emisar-mcp list_runners
emisar-mcp list_runners '{"statuses":["connected"]}'
emisar-mcp list_packs
emisar-mcp list_packs '{"availability":"all"}'
```

Use `emisar-mcp help <tool>` for every argument and its constraints. Fleet list
commands return bounded pages. Their human output says when more results exist;
use `--json` to copy the returned cursor or continuation exactly.

### Actions

| Command | Human output |
| --- | --- |
| `find_actions` | Ranked matches with risk, immutable pack ref, and a safe inspection command. |
| `get_action` | Description, side effects, trusted arguments, an editable `run_action` template, and compatible runner refs. |
| `run_action` | Operation ID and inspection command, per-runner status, approvals, exit codes, and action output. |
| `get_operation` | The durable mutation identity and its safe recovery command. |
| `recent_runs` | Recent run status, errors, output, and exact run IDs. |

Human `run_action` waits when the response contains an exact `wait_for_run`
continuation for the same run. It can wait on several runners concurrently and
returns after every run is terminal and available output is drained. The
operation ID is printed before waiting. Ctrl-C stops waiting, exits 130, and
prints a `get_operation` command; it does not cancel the action. Any terminal
status except `success`—`failed`, `error`, `validation_failed`,
`unknown_action`, `denied`, `cancelled`, `timed_out`, or `refused`—makes the
human command exit 1.

```sh
emisar-mcp find_actions "postgres replication"
emisar-mcp get_action \
  '{"action_id":"postgres.status","pack_ref":"postgres@1.2.0/sha256:..."}'
emisar-mcp get_operation '{"operation_id":"op_..."}'
emisar-mcp recent_runs '{"scope":"own","limit":10}'
```

### Runbooks

| Command | Human output |
| --- | --- |
| `list_runbooks` | Live release, unpublished-change marker, description, workflow size, and exact live/draft inspection commands. |
| `get_runbook` | Runbook identity, inputs, stages, action steps with target and argument context, and an editable execution template. |
| `execute_runbook` | Operation ID and inspection command, compact stage progress, a terminal summary, and bounded latest-action output grouped by stage. |
| `create_runbook_draft` | Draft identity, content digest, operation inspection command, review link, and current live release. |
| `update_runbook_draft` | The same draft result after an optimistic, digest-bound update. |

Human copy-paste labels have one meaning: **Inspect** and **Actions** issue safe
reads, **Run** is an editable mutation template with visible placeholders,
**Next** is an exact server-owned continuation, and **Review** opens the operator
workflow. Commands preserve an explicit `--account`; `--json` remains the exact
MCP `structuredContent` object without these presentation helpers.

Human `execute_runbook` follows only read continuations tied to the returned
execution. On macOS and Linux, compatible interactive terminals redraw the
stage list in place. Piped or redirected output prints a new line only when a
stage changes.
At completion it uses the returned `runs_next` history to show the latest
physical attempt for every action in workflow order. For each result, it
follows the exact returned `wait_for_run` continuation for that same run and
replaces any clipped preview with the recovered output. It prints up to 16,384
characters per action; if more remains, it links to the run page. Extracted
public runbook outputs are shown separately when the execution returns
`outputs_next`.

Ctrl-C stops observation without cancelling the runbook. The command exits 1
when the execution is `halted` or `cancelled`. `--json` does none of this
following: it returns the original call's exact `structuredContent`.

The local `auth`, `accounts`, `help`, and `list_tools` names are conveniences,
not reserved MCP tool names. Use `--` before an exact tool name when it conflicts
with a local command or begins with a hyphen:

```sh
emisar-mcp -- help '{}'
emisar-mcp -- auth '{}'
```

Call any tool with one JSON object. Omit it when the tool accepts `{}`, or
pass `-` to read the object from stdin. Tool results are readable text by
default. Put `--json` last when a script needs the exact object.

Build JSON with `jq` when values come from shell variables, then parse the result
as a separate step:

```sh
query='diagnose postgres replication'
result=$(jq -cn --arg query "$query" '{query:$query}' |
  emisar-mcp find_actions - --json) || {
  status=$?
  printf '%s\n' "$result" | jq .
  exit "$status"
}
printf '%s\n' "$result" | jq -e '.candidates'
```

The process contract is:

| Condition | Exit | stdout | stderr |
| --- | ---: | --- | --- |
| Successful tool call | 0 | readable text, or exact `structuredContent` with `--json` | normally empty |
| Successful `list_tools` or `help` | 0 | text, or JSON with `--json` | normally empty |
| Tool or MCP error | 1 | readable text, or structured error with `--json` | an authentication hint when relevant |
| Human mutation reaches a failed terminal state | 1 | final action or runbook status and available output | normally empty |
| Tool call rejected locally before transmission | 1 | selected format; JSON omits `data.operation_id` | diagnostic text |
| Tool-call transport or response failure after transmission | 1 | selected format; JSON includes `data.operation_id` | safe diagnostic and operation-recovery step |
| Configuration or list/help transport error | 1 | empty | diagnostic text |
| Invalid command or JSON input | 2 | empty | usage text |
| Ctrl-C while human mode is waiting | 130 | initial mutation result | observation-stopped warning and `get_operation` command |

Direct-command errors use the same small shape: what failed, field-level schema
problems when the server returns them, and a recovery command or live
`help <tool>` command when useful. Submitted values are never echoed. Color is
used only when stderr is a terminal. Redirected output and pipes stay plain; set
`NO_COLOR` to disable color in a terminal too. Exact JSON on stdout is never
decorated.

After an ambiguous mutation response, pass the returned `operation_id` to
`get_operation` before deciding whether to retry. For example, if the failing
command's stdout is in `call-error.json`:

```sh
jq -ce 'select(.data.operation_id != null) |
  {operation_id:.data.operation_id}' call-error.json |
  emisar-mcp get_operation - --json
```

Use this only when `data.operation_id` exists. Reads can be repeated normally.
When piping commands directly, enable your shell's pipeline-failure handling so
a downstream formatter does not hide a nonzero `emisar-mcp` exit.

Use stdin when an argument contains operational details you do not want in the
process list. Credentials are configuration, not tool arguments: the installer
stores the direct CLI key, while MCP clients and explicit endpoint overrides
keep keys in their environment. Human `run_action` and `execute_runbook` may
follow exact read-only continuations for the same durable work after the
mutation response. No CLI mode adds a local authorization or confirmation gate;
scope, policy, approvals, signed dispatch, and audit remain server/runner-owned.

## What the bridge owns

The bridge is intentionally thin. It owns only the transport between the
client and the control plane:

- line-delimited JSON-RPC on stdin and stdout;
- bounded request and response frames;
- request-ID correlation and concurrent-duplicate rejection;
- MCP protocol and Streamable HTTP headers, including the `MCP-Protocol-Version`,
  `Mcp-Method`, and `Mcp-Name` routing headers a client declaring protocol
  revision `2026-07-28` or later mirrors from its own frame;
- response status, media type, UTF-8, envelope, and ID validation;
- cancellation of observation without claiming to undo committed work;
- endpoint-bound API-key rotation state;
- optional client-side signing for `run_action`.

The direct CLI fetches live descriptors for discovery and help, accepts one
strict JSON argument object, and renders exact JSON or a bounded semantic view
for each fixed tool. Unknown future tools use the generic renderer. Human
`run_action` and `execute_runbook` follow only correlated server-issued
observation continuations. For runbook result pagination, the CLI preserves the
execution filter and adds only the opaque `next_cursor` returned by the previous
`recent_runs` page. `--json` always prints the exact result of one call.

With no command, it writes only validated MCP frames to stdout. Diagnostics stay
on stderr, and a network failure becomes a correlated JSON-RPC error instead of
corrupting the client stream. Direct CLI commands use the stream and exit contract
above.

The control plane owns every tool and semantic response. The normative
contract is [the MCP API specification](../.agent/kb/specs/mcp-api.md) with
machine-readable schemas in
[`portal/apps/emisar_web/priv/mcp/api-schemas.json`](../portal/apps/emisar_web/priv/mcp/api-schemas.json).
Server-side tool changes do not require a bridge release.

## Transport identity and recovery

The bridge admits at most eight concurrent requests within a 1 MiB aggregate
request budget. Each request is capped at 128 KiB, each response at 512 KiB,
and decoded string IDs and integer decimal forms at 4,096 bytes. Its 90-second
HTTP deadline stays above the control plane's 60-second wait cap, so pings and
unrelated calls remain responsive during a wait.

Every admitted `tools/call` receives a private, bounded operation identity
derived from the bridge process and request sequence. The control plane
reserves that identity with mutations under the API-key rotation lineage. An
identical retry returns the original resource; changed facts or a different
mutation conflict.
If the client loses a mutation response, `get_operation` is the recovery path
when the transport error includes an operation ID. Reads retry normally.

JSON-RPC request IDs may be reused after completion; only concurrent duplicates
are rejected. Cancellation after a request is sent stops observation only. It
does not assert that infrastructure work was rolled back or never committed.

## API-key rotation

The bridge replaces expiring `emk-` keys automatically. It saves the new key
before using it, so a restart cannot lose the working credential. The new key
stays bound to the same endpoint and credential lineage.

Credential state is stored under the user's emisar config directory. MCP-client
rotation state is namespaced by canonical endpoint and bootstrap prefix; direct
CLI state is namespaced by canonical endpoint and immutable account ID. The
directory is mode 0700; files are mode 0600 and updated through a cross-process
lock, temporary write, filesystem sync, and atomic rename. Corrupt, unsafe, or
endpoint-mismatched state is a startup error, not a reason to send a secret to
another origin.

If a direct command stops authenticating, run `emisar-mcp auth` again and choose
that account. If an MCP client stops authenticating,
reconnect it from `/app/agents/connect`. Reconnecting does not revoke old keys;
revoke connected keys in LLM agents. Never-used installer keys stay hidden
there and expire after 30 days.

If durable storage is unavailable, the bridge keeps using the configured key
but does not offer automatic rotation. Containers should persist `/config`.
OAuth tokens, arbitrary Bearer tokens, non-expiring quick-connect keys, and
audit-export tokens bypass local rotation state.

## Bridge-attested dispatch

`EMISAR_SIGNING_KEY` and `EMISAR_SIGNING_CERT` let the bridge sign the exact
`run_action` intent: control-plane origin, action, immutable pack, arguments,
complete runner set, reason, operation identity, nonce, and time. A
signature-enforcing runner verifies that intent against a trusted offline CA
and refuses altered, replayed, stale, or out-of-scope calls.

Signing is the only stdio transport path that inspects tool semantics. The
direct CLI also understands fixed result contracts for presentation and safe
observation. The public MCP frame remains unchanged; the attestation travels in
a private HTTP header.
Setup and rotation are documented in
[the signed-dispatch specification](../.agent/kb/specs/signed-dispatch.md).

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
./run gate mcp
```

The forwarding path lives in `main.go`; key rotation lives in `rotate.go`; and
`sign.go` is the only tool-aware code. The attestation implementation under
`internal/attest` is duplicated deliberately in the runner module and must stay
byte-identical. Read [`AGENTS.md`](AGENTS.md) before changing the boundary.
