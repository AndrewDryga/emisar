# Compatibility and deprecation policy

emisar is pre-1.0 today. That is why the portal, runner, MCP bridge, packs, and
their clients can still move together when a contract changes. That assumption
ends at `v1.0.0`. A deployed runner, an installed bridge, an operator's saved
configuration, and an LLM client will not all upgrade on the same day.

This document defines what becomes compatibility-bound at 1.0, what a skewed
peer does today, and how a public surface is retired afterward.

## Version policy

The product line uses one SemVer tag: `vMAJOR.MINOR.PATCH`. Component binaries
have separate release tags (`runner-v*` and `mcp-v*`), but they are part of the
same product contract.

Before 1.0, a normal product feature is a minor bump and a release hotfix is a
patch bump. Pre-1.0 releases do not promise long-lived compatibility between
components. The current release snapshot is product `v0.29.0`, runner
`0.13.0`, and `emisar-mcp` `0.3.0`. Those component versions are release tips;
unstamped local builds report `dev`.

At 1.0:

- `1.0.0` establishes the public contract listed below.
- A 1.x minor release may add compatible behavior. It must not silently rename,
  remove, narrow, or reinterpret a frozen contract.
- A patch release contains compatible fixes, security fixes, and documentation
  changes.
- A breaking change belongs in the next major release, normally after the
  deprecation window in this document.

The 1.0 freeze is a freeze on contract shape and compatibility behavior, not a
freeze on every pack, policy, or implementation detail. New packs and actions
can still be published. New fields, commands, and endpoints need to remain
additive or follow the deprecation path.

## Compatibility surfaces frozen at 1.0

### Portal-runner wire protocol

**What it is.** The runner opens a TLS WebSocket to the portal. Both sides send
JSON envelopes for `run_action`, `cancel`, `ack_result`, `runner_state`, action
events, heartbeats, and errors. There is no inbound runner listener.

**How it is versioned today.** Every known frame carries the single global
`protocol_version`, currently `1`. The version is checked per known message; it
is not negotiated as a version range. Unknown message types are ignored, and
unknown JSON fields are tolerated, which makes additive changes safe in either
direction. A non-additive change to a known frame must bump
`protocol_version`.

A separate runner SemVer policy lives in `Emisar.Compat`. The current production
threshold is `runner_minimum >= 0.10.0`, with enforcement off, so an old runner
is currently warned about rather than rejected. When enforcement is on, the
portal audits and rejects a runner below the minimum by sending a `shutdown`
envelope before closing the session.

**What happens on skew.** A known frame with the wrong `protocol_version` fails
loudly: the portal closes the socket with WebSocket code 1002 and a reason, and
the runner tears down the session with a protocol error. An unknown field or
message type is additive-safe. An older portal that receives a future
`action_result.status` currently writes the terminal run as `failed`; adding a
status therefore requires a coordinated runner emission, portal mapping, and
enum change even though the fallback is fail-safe.

There are two known limits in the current implementation. The runner has no
`shutdown`-reason handler, so the portal's useful version-rejection message is
not surfaced on the host; the host generally sees session-ended/reconnect
churn. Also, CI does not currently force a `protocol_version` bump when a
known field is renamed or retyped. A same-number, non-additive change can
therefore cause silent zero-value data loss or a retry loop. These are gaps to
close before relying on the 1.0 promise, not behavior this policy guarantees
away.

### Pack, action, catalog, and trusted-manifest schemas

**What they are.** A pack is a versioned YAML bundle containing action
descriptors. The published JSON catalog describes those bundles. The catalog
and trusted manifest bind the published metadata to content-addressed pack
hashes; the runner re-hashes the pack it loads.

**How they are versioned today.** The pack manifest, action schema, catalog,
trusted-manifest, and runner configuration currently use `schema_version: 1`.
Pack and action YAML loading is strict about unknown fields. Schema versions
are exact-match gates, not ranges. The catalog keeps the current pack plus up
to `K=3` previous published versions in `previous_versions` for the trust
window. A pack's `retired_below` watermark is permanent and monotonic once
published.

**What happens on skew.** A runner that cannot read a newer pack or action
schema rejects it closed and does not advertise it. A consumer that sees a
newer catalog or trusted-manifest schema gets an explicit unsupported-schema
error. It does not guess at the format.

Within the trust window, a slightly older pack can remain auto-trusted. A pack
outside the window may need an operator trust decision. A version strictly
below `retired_below` is not dispatchable: the portal refuses it as retired,
untrusted, or hash-mismatched and does not create the run. Its immutable
tarball remains installable, and an administrator can use the audited override
when there is a reason to do so. The current bundled catalog has no
`retired_below` entries, so the retirement refusal is implemented but has not
yet been exercised against a live pack.

The content hash is part of this contract. Reusing a pack version with changed
bytes is not a compatible edit; publish a new version. See
[`packs/PUBLISHING.md`](../packs/PUBLISHING.md) for the append-only registry and
retirement rules.

### MCP transport and the 12-tool surface

**What it is.** The portal exposes stateless, JSON-only Streamable HTTP at
`/api/mcp/rpc`. `tools/list` is server-authoritative and currently returns
these twelve tools:

```text
list_packs          list_runners          find_actions
get_action          run_action             get_operation
wait_for_run        recent_runs           list_runbooks
get_runbook         execute_runbook        create_runbook_draft
```

The tool catalog advertises `tools.listChanged: false`. Packs and runner state
appear in tool results; they do not become one tool per action.

**How it is versioned today.** MCP transport negotiation accepts
`2025-11-25` and `2025-06-18` during `initialize`. The negotiated
`MCP-Protocol-Version` must be sent on later requests; an unsupported header is
rejected with HTTP 400. Tool names and descriptor field sets are compiled and
fixture-checked. Tool inputs are strict: unknown or renamed fields are rejected.
The bridge identifies itself as `emisar-mcp/<version>` and the current bridge
threshold is `mcp_minimum >= 0.3.0`, also warn-only in production today.

**What happens on skew.** An older client calling a renamed or removed tool
gets JSON-RPC `method-not-found`. A stray or renamed input field is rejected;
it is not silently ignored. A new optional input field or a new tool is
additive for clients that do not use it. If MCP enforcement is enabled, a
bridge below the minimum receives a structured JSON-RPC `-32003` upgrade error
with the required minimum and upgrade URL. The current MCP surface has no
general deprecation mechanism; removals and renames must use the path below.

The normative tool names and schemas live in
[`docs/mcp-api-spec.md`](mcp-api-spec.md) and
[`docs/mcp-api-schemas.json`](mcp-api-schemas.json).

### Runner and MCP bridge CLI, configuration, and environment

**What they are.** These are the interfaces people put in service units,
runbooks, shell scripts, CI jobs, and MCP client configuration. The runner's
current top-level verbs are:

```text
connect
action list|describe|run
pack install|suggest|update|list|info|uninstall|validate
audit verify
doctor
events tail|cat|grep
signing init|new-ca|new-cert
state [check-dispatch-log]
version
completion
help
```

The runner's global flags are `--config`, `--json`, `--packs-dir`, and
`-v/--version`. `action run` also accepts `--arg`, `--reason`, `--timeout`, and
`--stream`. Pack registry operations accept `--registry`; pack installation
also accepts `--hash`, `--dest`, and `--force`. These command names and flags,
including the documented aliases, are public inputs.

The runner configuration is YAML with exact `schema_version: 1` and strict
keys. Its top-level sections are `runner`, `cloud`, `paths`, `execution`,
`admission`, `signing`, `events`, and `redaction`. `EMISAR_CONFIG` selects the
file, `EMISAR_URL` overrides `cloud.url`, and `cloud.enrollment_key_env` names the
bootstrap credential (normally `EMISAR_ENROLLMENT_KEY`). `EMISAR_PACKS_REGISTRY` and
the `--registry` flag select a pack registry.

The MCP bridge has no subcommands. Its flags are `-h/--help` and
`-v/--version`. Its environment is:

```text
EMISAR_URL              required control-plane origin
EMISAR_API_KEY          required operator API key
EMISAR_CLIENT           optional audit label
EMISAR_CLIENT_METADATA  optional untrusted audit metadata
EMISAR_ALLOW_INSECURE   development-only cleartext opt-in
EMISAR_SIGNING_KEY      optional local signing key
EMISAR_SIGNING_CERT     optional certificate for that key
```

It reads and writes line-delimited JSON-RPC 2.0 over stdio, and sends the user
agent `emisar-mcp/<version>`. The attestation identifiers
`emisar-attestation-v4` and `emisar-cert-v2` are also frozen security formats.
`packctl` is a maintainer-only build tool, not a customer CLI compatibility
surface.

**What happens on skew.** Adding a flag, config key, or environment variable
is additive when the old binary can ignore it. Removing or renaming one fails
loudly: Cobra reports an unknown flag and the runner's strict YAML loader
rejects an unknown config key. There is no migration path in the current CLI.
An old bridge may start, then be warned or rejected by the portal's bridge
minimum; it must not be assumed compatible just because it can launch.

### On-host runner state

**What it is.** State the runner already wrote to customer hosts and reads
back on its next boot: the durable dispatch log (`<data_dir>/dispatches.jsonl`,
previously `<data_dir>/dedup.jsonl`), the persisted runner identity and token,
the append-only events journal, signing/nonce state, and the installed pack
trees under the configured pack directories.

**Why it is a surface.** A new binary always boots against files an older
binary wrote — this state is "deployed" the way a committed DB migration is,
regardless of product version. Both halves were broken in one day pre-0.12:
deleting the dispatch-log format migration made every host carrying v0.9
history silently refuse all dispatches, and a stricter pack YAML parser made
one already-installed pack file boot-fatal, crash-looping a production runner
1,164 times. The rule since: a change to how this state is read either keeps
reading the old form or migrates it forward on boot (the dispatch log now does
both — legacy entries and the legacy path migrate with an audit-visible log
line); a per-item fault (one pack, one file) degrades that item loudly and
never the whole runner.

**What happens on skew.** A dispatch log the runner cannot read refuses
`connect` with the quarantine remedy in the error; `emisar doctor` and
`emisar state check-dispatch-log` report the same verdict offline, and
`install.sh` runs the check with the staged binary before touching a running
service. A broken installed pack loads as degraded (`packs.degraded` log
line, doctor failure naming the directory) while every healthy pack keeps
serving.

### Runner record retention

Portal runner rows are soft-deleted, never hard-deleted. The required
`action_runs.runner_id` foreign key cascades on a hard delete, which would
remove the run history and its event and approval records; deletion therefore
means tombstoning the runner row while preserving its historical references.

### Install scripts

**What they are.** `install.sh` installs the runner and its service integration;
`install-mcp.sh` installs the stdio bridge. Both are public curl-pipe-shell
entry points and both select binaries from GitHub Releases.

**How they are versioned today.** The script interfaces are flag- and
environment-based, not protocol-negotiated. `install.sh` accepts runner tags
in `runner-vX.Y.Z`, `vX.Y.Z`, or `X.Y.Z` form and flags including `--yes`,
`--uninstall`, `--purge`, `--no-start`, `--no-service`, `--bin-dir`,
`--etc-dir`, `--data-dir`, `--log-dir`, `--user`, and `--packs`. Its environment
includes `VERSION`, the directory and service settings, `EMISAR_PACKS`,
`EMISAR_URL`, and `EMISAR_ENROLLMENT_KEY`.

`install-mcp.sh` accepts `--version`, `--install-dir`, and `--yes`. It accepts
`VERSION`, `INSTALL_DIR`, `EMISAR_REPO`, `EMISAR_GITHUB_TOKEN`, `ASSUME_YES`,
and `EMISAR_URL` (the portal its interactive LLM-client setup talks to and
writes into configs; default `https://emisar.dev`). The interactive setup
drives the portal's device-authorization pair —
`POST /api/mcp/device_authorization` and `POST /api/mcp/device_token`, RFC
8628-shaped fields and poll errors with an emisar-specific success payload
(per-client API keys) — which freezes at 1.0 alongside the other public API
surfaces. The current release tags are `runner-v0.13.0` and `mcp-v0.3.0`. The
bridge installer also requires the selected GitHub release to be marked
immutable.

**What happens on skew.** A renamed installer flag or environment variable
fails the one-liner with an unknown-option or missing-configuration error. A
changed release asset name fails the download or verification step. The
scripts do not negotiate an older interface, so a 1.0 change must keep the
old input and asset path during the deprecation window or publish an explicit
migration.

### Registry URL layout

**What it is.** The pack registry has two related URL contracts:

- The versioned CDN at `https://registry.emisar.dev/v1/` publishes
  `catalog.json`, `suggest.json`, immutable catalog snapshots, versioned JSON
  schemas, and content-addressed pack tarballs under
  `v1/packs/<id>/<version>/<sha256>/pack.tar.gz`.
- The runner's default registry is currently the facade
  `https://emisar.dev`. The facade serves `/packs.json`,
  `/packs/suggest.json`, `/packs/<id>/pack.tar.gz`, and
  `/packs/<id>/versions/<version>/pack.tar.gz`.

**How it is versioned today.** The CDN's `/v1/` prefix, content addressing,
append-only pack history, and written stability promise are the versioned
part of the current publishing contract. The runner's facade is intentionally
unversioned and hard-coded as the default registry base. The exact facade
paths listed above are frozen at 1.0; a future breaking registry shape must
use an additive versioned path and keep these routes available.

**What happens on skew.** A consumer using the CDN gets immutable objects and
clear schema failures when the catalog format is not supported. A change to
the facade path shape breaks deployed runners' `pack install` and `pack update`
commands. There is no negotiation layer to save an old binary.

The `/v1/` CDN and the `emisar.dev/packs…` facade are 1.0 compatibility
surfaces. The facade remains unversioned by design; its paths and response
semantics must not be silently edited after 1.0.

## Deprecating and removing a surface after 1.0

This is the policy for a normal deprecation. The current 0.x implementation
does not yet provide every warning or negotiation hook described here.

1. **Announce the change.** The first release that deprecates a surface must
   name the old contract, the replacement, the migration step, the first
   affected component versions, and the earliest removal release in its
   release notes and compatibility documentation.
2. **Keep it for the window.** The default window is the longer of two minor
   product releases or 12 months from the first deprecation notice. During the
   window the old name, path, flag, key, or schema remains accepted. A minor or
   patch release must not remove it.
3. **Warn where the operator can act.** The portal must show the deprecation
   in the console and audit trail for runners and bridges. CLIs must warn on
   use and mark the old form in `--help`; config and environment aliases must
   warn at startup. Warnings must include the replacement and removal release.
   A warning is not a substitute for accepting the old contract.
4. **Negotiate or run both versions.** The current runner wire protocol uses an
   exact per-frame version and has no handshake negotiation. A breaking wire
   change therefore needs either a real supported-version handshake or a
   parallel endpoint/implementation that keeps the old peer working. Pack and
   catalog schema bumps need the same two-version support or a separate
   versioned artifact path; never reinterpret schema 1 as schema 2. MCP
   transport can negotiate its supported protocol set, but the tool surface
   must keep the old tool name and input contract, or provide a versioned
   surface, until the window ends. CLI, environment, install, and URL changes
   need aliases or parallel paths because they have no negotiation today.
5. **Remove only after the window.** Removal belongs in a major release and
   must leave an explicit, actionable failure for callers that still use the
   old form. A security issue can shorten the window when keeping the old path
   would preserve the unsafe behavior; the release notes must say so and name
   the replacement.

## The greenfield exception changes at 1.0

Before 1.0, emisar's working assumption is that components move together. That
is why the MCP spec rejected a long-lived compatibility mode and creed #6 says
to edit the original and delete dead behavior. At 1.0, the surfaces above are
like a committed database migration: deployed peers and saved operator
configuration make the published contract real. Treat them as frozen, add a
version when the shape is breaking, and use the deprecation path instead of
silently editing the original.

This policy records the boundary. It does not claim that every 1.0 safeguard is
already implemented. The missing runner shutdown-reason handler, the lack of a
mechanical wire-version bump guard, the unexercised retirement path, and the
current absence of general CLI/MCP deprecation signaling remain explicit
pre-1.0 work items.
