# Architecture

emisar has three runtime components and one versioned action catalog. The
hosted control plane decides whether a request may run; the outbound-only
runner enforces the declared action contract on the target host; the optional
MCP bridge connects local MCP clients to the same control-plane surface.

## Components

| Component | Responsibility | Trust boundary |
| --- | --- | --- |
| `portal/` | Phoenix control plane, operator console, remote MCP/OAuth, policy, approvals, pack trust, runbooks, and searchable audit | Authorizes callers and dispatches only trusted catalog actions; it is not trusted to bypass runner validation |
| `runner/` | Long-lived host agent, pack loader, local admission, argument validation, execution, redaction, and hash-chained journal | Has the OS permissions of its service user and gets the final decision on what this host will execute |
| `mcp/` | Thin stdio-to-HTTP JSON-RPC bridge for local MCP clients | Holds the operator API key and optional signed-dispatch leaf key; it does not implement policy or action behavior |
| `packs/` | Versioned action manifests, schemas, commands, scripts, limits, and redaction rules | Pack bytes are executable configuration; a trusted content hash is the reviewed unit |

`tools/` contains pack-authoring support, repository checks, and maintainer E2E
drivers. It is not shipped to customers and is not part of the runtime system.

## Request flow

1. The runner loads local packs, validates their manifests and referenced
   scripts, computes content hashes, applies the host's admission policy, and
   advertises the resulting catalog over an outbound TLS websocket.
2. An operator or MCP client requests a declared action. The control plane
   authenticates the caller, applies account and runner scope, verifies the
   trusted pack hash, evaluates policy, and creates any required approval.
3. The control plane sends one `run_action` message containing the action id,
   arguments, bounded option overrides, reason, and trusted pack hash.
4. The runner re-hashes the pack, checks local admission, looks up the action,
   re-validates every argument, clamps options to the action envelope, and
   renders the pack-authored argv and environment.
5. The runner executes through `os/exec`. Most actions call a binary directly.
   Packs may use a fixed, reviewed `/bin/sh -c` program when shell features are
   necessary; only schema-bounded values may be substituted into it. The
   staging-only `shell` pack is the explicit arbitrary-shell break-glass path.
6. Output is line-buffered, bounded, and redacted before progress leaves the
   host. The runner writes a hash-chained local JSONL event and sends the final
   result. The control plane stores the searchable fleet record.

The runner websocket contract is versioned in
[`wire-protocol.md`](wire-protocol.md). Client-attested dispatch adds an
optional signature gate described in
[`signed-dispatch.md`](signed-dispatch.md).

## Enforcement ownership

| Question | Owner |
| --- | --- |
| Who authenticates users, API keys, OAuth clients, and runners? | Control plane |
| Who decides account policy and approvals? | Control plane and authorized human operators |
| Who pins the reviewed pack version and content hash? | Control plane |
| Who validates action arguments immediately before execution? | Runner |
| Who can narrow the host's advertised and executable actions? | Runner-local admission policy |
| Who recomputes trusted pack and script bytes? | Runner |
| Who grants OS privileges to an action? | Host operator, through the runner service user and OS controls |
| Who stores the searchable audit history? | Control plane |
| Who stores the local forensic trail? | Runner |

The control plane cannot make the runner execute an unknown action or an
argument that fails the local schema. The runner does not create approvals,
evaluate account policy, or compose runbooks. One runner belongs to one
workspace.

## Runner lifecycle

At boot, the runner locks its data directory, then loads config, packs, admission
rules, and the local journal. A runner enforcing signed dispatch also opens its
durable nonce store before building the verifier; unsigned runners do not depend
on signing state. It then exchanges a bootstrap key for a per-runner token when
needed, connects, and advertises state. While enforcement is active, `SIGHUP`
rebuilds packs and immutable signing policy and atomically swaps them for new
requests; all verifier generations share the boot-owned nonce store, while
in-flight actions continue with the policy snapshot they started under.

The connection, action, result, and acknowledgement loops are independent so
an in-flight action can finish across a websocket reconnect. Results remain
correlated by request id and the runner's durable delivery state prevents a
replayed dispatch from silently becoming a second execution.

## Data and deployment

The hosted portal runs on Google Cloud behind a global load balancer with
private application instances and Cloud SQL. CI validates a commit; main-only
CD publishes the tested image and creates a saved HCP Terraform plan; a human
reviews and applies that plan. See [`.github/DEPLOYMENT.md`](../.github/DEPLOYMENT.md)
and [`infra/README.md`](../infra/README.md).

The runner exposes no inbound network listener. Its durable local state is the
per-runner credential, dispatch log, installed packs, signing nonces, and the
JSONL journal. The MCP bridge is a local child process of the MCP client and
persists only rotated API-key successors in the user's config directory.
