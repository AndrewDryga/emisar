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
components. The current release snapshot is product `v0.43.0`, runner
`0.22.1`, and `emisar-mcp` `0.10.1`. Those component versions are release tips;
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
envelope before closing the session. A missing or unparseable reported version
classifies as `:unknown` and is never rejected, even with enforcement on;
enforcement acts only on a parseable version below the minimum. That is
deliberate: the version is self-reported, so it is an operational hygiene
signal, not a security control — an authenticated peer gains no capability by
lying about it, and a `dev` build must not be locked out. Both behaviors are
pinned by `Emisar.CompatTest` and the enforcement call sites act on
`:unsupported` alone.

The pre-1.0 thresholds are operational warning lines, not certified
interoperability promises: no 0.x artifact pair is cross-version tested, and
components are expected to move together (the greenfield assumption). The v1
support window is deliberately narrow and coordinated: when `v1.0.0` is cut,
`runner_minimum` and `mcp_minimum` are raised to the coordinated v1 component
releases shipped with it, so the certified pair is exactly the v1 portal with
the v1 runner and bridge — proven by the same-repo gates and the wire golden at
the release tag, not by a cross-version binary matrix against 0.x artifacts.
Raising the minimums does not by itself disconnect deployed 0.x components:
enforcement is a separate, deliberate flip taken only after operators have had
an upgrade window, and until then a below-minimum peer is warned, not cut off.
From then on the frozen wire contract, not a test matrix, is what keeps every
later 1.x portal compatible with the v1.0 runner and bridge; the golden and the
additive-change rules in this section are the enforcement mechanism.

**What happens on skew.** A known frame with the wrong `protocol_version` fails
loudly: the portal closes the socket with WebSocket code 1002 and a reason, and
the runner tears down the session with a protocol error. An unknown field or
message type is additive-safe. An older portal that receives a future
`action_result.status` currently writes the terminal run as `failed`; adding a
status therefore requires a coordinated runner emission, portal mapping, and
enum change even though the fallback is fail-safe.

Optional `action_result.structured_output` and runner descriptor
`output_schema` are additive v1 fields. Old runners omit them. The portal
accepts their absence, but it never invents a missing schema: a runner that does
not advertise the exact schema cannot match a schema-bearing trusted manifest.
Schema-bearing packs must therefore roll out only after portal acceptance and
runner enforcement are deployed.

The runner handles every `shutdown` envelope and logs the portal's reason and
message. `cloud_shutdown`, `runner_disabled`, and `account_disabled` reconnect.
`runner_revoked` persists a terminal shutdown and requires re-enrollment;
`runner_version_unsupported` persists one and requires a supported binary.
The runner's wire golden captures every known frame. CI rejects a changed frame
until the golden is deliberately regenerated, and refuses non-additive
regeneration at the same `protocol_version`; a rename, removal, or retype must
bump the protocol version.

### Pack, action, catalog, and trusted-manifest schemas

**What they are.** A pack is a versioned YAML bundle containing action
descriptors. The published JSON catalog describes those bundles. The catalog
and trusted manifest bind the published metadata to content-addressed pack
hashes; the runner re-hashes the pack it loads.

**How they are versioned today.** The pack manifest, action schema, catalog,
trusted-manifest, and runner configuration currently use `schema_version: 1`.
A trusted descriptor's optional `output_schema` is an additive field that
participates in descriptor trust and drift comparison; a descriptor without one
simply omits the key. Pack and action YAML loading is strict about unknown
fields. Schema versions are exact-match gates, not ranges. The catalog keeps
the current pack plus up to `K=3` previous published versions in
`previous_versions` for the trust window. `packctl catalog build --previous`
keeps a pack's `retired_below` watermark monotonic in the normal publication
path by refusing to lower or drop an already-published one; the portal runtime
logs a lowered or dropped watermark as a regression and still serves the
catalog, so that monotonicity is a publisher guarantee rather than a runtime
invariant.

**What happens on skew.** A runner that cannot read a newer pack or action
schema rejects it closed and does not advertise it. A consumer that sees a
newer catalog or trusted-manifest schema gets an explicit unsupported-schema
error. It does not guess at the format.

The window is read from the catalog the portal is configured to fetch, so a
slightly older published version can remain auto-trusted. A pack outside that
catalog's current-or-retained entries needs an operator trust decision. A
version strictly below `retired_below` is not dispatchable: the portal refuses
it as retired, untrusted, or hash-mismatched and does not create the run. Its
immutable tarball remains installable, and an administrator can use the audited
override when there is a reason to do so. Both the bundled boot catalog and the
published one carry `retired_below` watermarks across real packs, so retirement
is represented in product metadata rather than only synthetic fixtures.

The content hash is part of this contract. Reusing a pack version with changed
bytes is not a compatible edit; publish a new version. See
[`packs/PUBLISHING.md`](../../../packs/PUBLISHING.md) for the append-only registry and
retirement rules.

### Runbook definition schema

**What it is.** A runbook's live release and its one unpublished change each
carry a strict JSON-compatible DefinitionV1 object. It declares Markdown context, typed inputs, ordered stages,
stage mode and concurrency, action steps, one `pack: {id}` per step, an explicit
`all` or `random_one` selection over tagged runner and group refs, whole-value
bindings, named output extractors, success conditions, and optional bounded waits. Approval is execution state
derived from account policy, not part of the runbook definition. The console,
persistence layer, compiler, and MCP tools consume and return this same object;
there is no alternate YAML or legacy flat-step contract.

**How a runbook is referenced.** `runbook_ref` is `slug@release`. The slug is
the runbook's stable public identity — editable only until the first release,
frozen afterwards because refs depend on it — and the number is a release
number counting publishes of that runbook, 1..N. It is not a save counter and
not a definition schema version. Execution accepts only the LIVE release; an
older number answers `not_live` rather than silently running current content.
An unpublished change has no number: it is named by slug plus the
`definition_sha256` of the exact content the caller consents to run.

**How it is versioned today.** The definition requires exact
`schema_version: 1`. Its machine schema is
[`definition-v1.schema.json`](../../../portal/apps/emisar/priv/runbooks/definition-v1.schema.json)
and the MCP schema references that identity as
`https://emisar.dev/schemas/runbook-definition-v1.json`. Unknown fields are
rejected. Execution resolves each pack ID and action against the current trusted
catalog, then freezes the exact selected runner, pack ref, and hash per item.
`random_one` accepts exactly one group, validates its complete online pool, and
records both the chosen runner and source group. An already-frozen
execution cannot be reinterpreted by a later pack update. A runbook whose
current pack or action contract no longer resolves fails preflight until an
operator publishes a working release.

**What happens on skew.** A consumer or stored definition using an unsupported
schema version fails closed with `unsupported_schema_version`. It is never
treated as v1 by resemblance. After 1.0, an incompatible definition change
adds a new schema version and keeps the old reader and semantics for the
deprecation window. Additive fields still need either optional v1 semantics
that old consumers safely ignore where allowed, or a new schema version when
the strict v1 object would reject them.

### MCP transport and the 13-tool surface

**What it is.** The portal exposes stateless, JSON-only Streamable HTTP at
`/api/mcp/rpc`. `tools/list` is server-authoritative and currently returns
these thirteen tools:

```text
list_packs          list_runners          find_actions
get_action          run_action             get_operation
wait_for_run        recent_runs           list_runbooks
get_runbook         execute_runbook        create_runbook_draft
update_runbook_draft
```

The tool catalog advertises `tools.listChanged: false`. Packs and runner state
appear in tool results; they do not become one tool per action.

Every descriptor carries its complete, self-contained `inputSchema`; response
schemas stay server-side as normative contracts exercised by the portal's
fixture and integration tests, so `tools/list` stays small on every client.

The `wait_for_run` output-tail `cursor` input and its `output`-delta result
(`run_tail`) are additive v1 fields. A client that never sends `cursor` keeps
the unchanged tail-snapshot result; the streamed shape is a distinct member of
the tool's output `oneOf`, so neither the input nor the output contract of an
existing caller changes.

**How it is versioned today.** The endpoint is dual-era. A `2026-07-28`
client declares its version per request in `_meta` with a matching
`MCP-Protocol-Version` header plus the `Mcp-Method`/`Mcp-Name` routing
headers; header mismatches are HTTP 400 with `-32020` and an unsupported
declared version is HTTP 400 with `-32022` naming the supported set. Legacy
negotiation accepts `2025-11-25` and `2025-06-18` during `initialize`
(`initialize` selects legacy semantics and never negotiates the modern
revision); the negotiated `MCP-Protocol-Version` must be sent on later
requests, and an unsupported header is rejected with HTTP 400 (`-32022`).
Tool names and descriptor field sets are compiled and fixture-checked. Tool
inputs are strict: unknown or renamed fields are rejected. The bridge
identifies itself as `emisar-mcp/<version>` and the current bridge
threshold is `mcp_minimum >= 0.3.0`, also warn-only in production today.

**What happens on skew.** An older client calling a renamed or removed tool
gets JSON-RPC `method-not-found`. A stray or renamed input field is rejected;
it is not silently ignored. A new optional input field or a new tool is
additive for clients that do not use it. If MCP enforcement is enabled, a
bridge below the minimum receives a structured JSON-RPC `-32003` upgrade error
with the required minimum and upgrade URL. A bridge reporting a missing or
unparseable version is classified `:unknown` and never rejected; like the
runner policy, enforcement acts only on a parseable version below the minimum,
and the bridge minimum follows the same coordinated v1 window (raised to the
v1 bridge release when `v1.0.0` is cut). The current MCP surface has no
general deprecation mechanism; removals and renames must use the path below.

The normative tool names and schemas live in
[MCP API specification](mcp-api.md) and its
[machine-readable schema](../../../portal/apps/emisar_web/priv/mcp/api-schemas.json).

### OAuth authorization server and device authorization

**What it is.** The portal is the OAuth authorization server MCP clients are
configured against. It serves `GET /.well-known/oauth-protected-resource`
(RFC 9728), `GET /.well-known/oauth-authorization-server` (RFC 8414),
`POST /oauth/register` (RFC 7591 dynamic registration, deprecated),
`GET`/`POST /oauth/authorize`, and `POST /oauth/token`. The bridge installer's
interactive setup drives the separate RFC 8628-shaped device pair
`POST /api/mcp/device_authorization` and `POST /api/mcp/device_token`.

**How it is versioned today.** There is no path version; the advertised
metadata is the negotiation surface. The authorization-server document
advertises `response_types_supported: ["code"]`, grants `authorization_code`
and `refresh_token`, PKCE `S256` only (`plain` is rejected and the challenge
is mandatory), `token_endpoint_auth_methods_supported: ["none"]`, scopes
`mcp` and `offline_access`, `authorization_response_iss_parameter_supported`
(RFC 9207 — every authorization redirect, success or error, carries `iss`
equal to the metadata `issuer`), and `client_id_metadata_document_supported`.
Client registration accepts both mechanisms: a Client ID Metadata Document
client presents an HTTPS document URL as its `client_id`, which the server
fetches and validates on every authorization and addresses the client by
thereafter; a deprecated DCR client is addressed only by its issued id. The
`resource` parameter must exactly equal the advertised MCP resource URI.
Issued credentials are recognizable prefixed formats — authorization codes
`emoc-`, access tokens `emo-`, refresh tokens `emor-` (rotated on use, issued
only with `offline_access`), device codes `emdg-`, and the per-client `emk-`
API keys the device flow mints. Lifetimes (60 s codes, 1 h access tokens,
30 day refresh tokens, 900 s device grants) are policy advertised per
response via `expires_in`, not frozen contract. The device-authorization
response fields (`device_code`, `user_code`, `verification_uri`,
`verification_uri_complete`, `expires_in`, `interval`) and the token poll's
emisar-specific success payload — a `client_keys` map of per-client API keys,
plus `account_id`, `account_slug`, and `account_name` for the approved account,
not an OAuth token response — are frozen; today's poll errors are
`authorization_pending`, `access_denied`, `expired_token`, and
`invalid_grant`, and `slow_down` is never emitted.

**What happens on skew.** An unknown grant type fails with
`unsupported_grant_type`, a wrong `resource` with `invalid_target`, and an
unregistered `redirect_uri` with a non-redirecting error page — explicit
failures, never silent downgrades. The frozen part of the metadata is the
issuer, the endpoint paths, and the meaning of every advertised member;
capability sets and error vocabularies may still grow additively, since
RFC 8414 clients ignore unknown members — adding a scope or grant type is not
a breaking change. The device poll follows the same rule for terminal outcomes: the deployed
installer reads a poll verdict only from an HTTP 400 body (rate limits,
proxy responses, and blips on any other status keep polling), retries only
`authorization_pending`, and fails cleanly on every other or unknown 400
code — so a new terminal poll error is an additive change. The breaking
direction is a new retryable code: a deployed installer would abort on it,
so `slow_down` or any other retry signal needs a new poll contract. Already-issued `emk-` keys and
live refresh tokens are saved customer credentials and must keep authenticating. Replaying a
still-unexpired refresh token that rotation already spent revokes its backing OAuth connection and
every active successor; the operator must reconnect the client to establish a fresh grant.

### Enterprise SSO callback and SCIM provisioning

**What they are.** Customers register two portal values inside their identity
provider, where we cannot rotate them: the fixed OIDC redirect URI
`GET /sign_in/sso/callback` for SSO sign-in, and the SCIM 2.0 base URL
`<base>/scim/v2` plus a per-provider `ems-` bearer token for directory
provisioning (Okta, Entra, JumpCloud, Keycloak, Google).

**How they are versioned today.** SCIM is path-versioned at `/scim/v2`
(RFC 7643/7644). Discovery serves `ServiceProviderConfig`, `ResourceTypes`,
and `Schemas` advertising the deliberate subset: `patch` and `filter`
(`maxResults` 100) on, `bulk`/`sort`/`etag` off. Every SCIM resource `id` is an
immutable UUID assigned by emisar. The IdP-owned `externalId` remains the
create/reconciliation and filter key, and for Users it remains the value that
must converge with the configured OIDC subject claim. Single-resource routes
use the returned `id`; Group `members[].value` entries use the returned User
`id`. User and Group collections
honor RFC 7644's one-based `startIndex` and `count`, return at most 100 resources
per page, and report the filtered collection's full count in `totalResults`;
malformed pagination values fail with 400 `invalidValue`. Users support idempotent
create/reconcile, `userName eq`/`externalId eq` filters only, PATCH limited to
`active` and rename attributes, PUT limited to `displayName` plus `active`,
and DELETE as membership suspension plus wire-resource retirement: the User is
omitted from lists and its GET/PATCH/PUT/DELETE routes return 404, while a later
POST with the same `externalId` restores the same resource and person. An
`active:true` update restores only an addressable `active:false` resource; it
does not restore a DELETEd one. Groups reconcile POSTs by `externalId` when one is supplied. A POST without `externalId`
creates a fresh resource with a new server `id`; the display name is never
identity. Groups support membership `add`/`remove`/`replace` including Okta's filtered removal form, a
`displayName eq` filter, and DELETE removes the Group resource, clears its
members, and revokes authorization derived from its mappings. Several tolerant
parses are load-bearing for specific IdPs and are part of the contract: the
case-insensitive and schemeless `Authorization` header (Okta header-auth
apps), unquoted `eq` filter values, and the externalId-less Group create used by
JumpCloud's activation probe. An unsupported Users filter fails with 400 `invalidFilter`;
unsupported or unparseable Group filters fail with the same 400 `invalidFilter` response.

**What happens on skew.** An IdP sending an unsupported operation gets an
explicit SCIM error (`invalidPath`, `invalidFilter`, `tooMany`, 409
`uniqueness`/`mutability`), never silent acceptance, and a rejected request
changes nothing. Renaming either registered value, narrowing a tolerant parse,
or reinterpreting `id`, `externalId`, or Group member references breaks deployed
IdP configurations that only the customer can update — after 1.0 all of it moves only through the
deprecation path, and already-issued `ems-` tokens must keep authenticating.

### Audit export for SIEM

**What it is.** `GET /api/audit` streams the account audit trail as NDJSON
(`application/x-ndjson`, one event object per line) for SIEM collectors,
authenticated by a bearer `emk-` API key of the dedicated `audit_export`
kind. The console also serves a CSV download of the same trail.
The console CSV is bounded to 100,000 events or 256 MiB, whichever comes
first. It is prepared before download headers are sent; an empty, changed,
failed, or oversized attempt sends no CSV, and a complete prepared export is
available through Support.

**How it is versioned today.** There is no path version; the contract is the
parameter and field names. Query parameters are `since` (ISO 8601 inclusive
lower bound), `cursor` (opaque resume point, wins over `since`),
`event_type` (repeatable or comma-separated), and `limit` (default 100,
cap 1000). Any non-empty page returns `X-Next-Cursor`; a full page also
returns `Link: <…>; rel="next"`; an empty page returns neither. Each exported
event today carries the 15 top-level fields `id`, `occurred_at`,
`account_id`, `event_type`, `actor_kind`, `actor_id`, `actor_label`,
`target_kind`, `target_id`, `target_label`, `ip_address`, `user_agent`,
`request_id`, `mcp_client_metadata`, and `payload`. The CSV download's header
row, column order, CRLF line endings, always-quoted fields, and
formula-injection guard are likewise fixed, since operators parse the saved
artifact.

**What happens on skew.** A key of the wrong kind fails with 403
`wrong_key_kind`; a malformed parameter with 400 `invalid_params`. Adding a
new top-level field or event type is additive; removing or renaming one of
the 15 fields, a parameter, or the `X-Next-Cursor` header is breaking. A
SIEM persists its last cursor across polls, so previously issued cursor
values must remain resumable; a change to the cursor encoding must keep
accepting the old form for the deprecation window.

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
status
events tail|cat|grep
signing init|new-ca|new-cert
state [check-dispatch-log]
update
version
completion
help
```

The runner's global flags are `--config`, `--json`, `--packs-dir`, and
`-v/--version`. **Every flag `emisar <verb> --help` documents on the commands
above is frozen with its command** — the list is deliberately not enumerated
here, because an enumeration drifts silently as verbs gain flags and then reads
as permission to rename the ones it forgot. `action run --arg/--reason/
--timeout/--stream`, `pack install --hash/--dest/--force`, `pack suggest
--catalog/--names-only`, `pack update --dry-run`, `audit verify --all`, `events
tail --lines/-f`, `events grep --action/--caller/--event`, `state
check-dispatch-log --data-dir`, `signing init --ca-name/--scope/--ttl/--key`,
`signing new-ca --ca-name/--ttl/--key`, and `signing new-cert
--ca-key/--ca-cert/--key-name/--scope/--ttl/--key` are all inside the freeze.
These command names and flags, including the documented aliases, are public
inputs. The structured output
`--json` emits exists to be parsed by scripts, so those shapes freeze with the
flags: after 1.0 they change only additively. That includes the complete
`status --json` report and its embedded `runtime` object.

The runner also writes `<paths.data_dir>/runtime-status.json` with exact
`schema_version: 1`. It is an owner-only, advisory operational snapshot for
`emisar status`: the reader must correlate it with the held runner lock, live
PID, and heartbeat freshness. It is not a control-plane receipt, trust decision,
or authority boundary. Its JSON shape joins the compatibility freeze at 1.0.

The runner configuration is YAML with exact `schema_version: 1` and strict
keys. Its top-level sections are `runner`, `cloud`, `paths`, `execution`,
`admission`, `signing`, `events`, and `redaction`. `EMISAR_CONFIG` selects the
file, `EMISAR_URL` overrides `cloud.url`, `EMISAR_GROUP` and `EMISAR_RUNNER_ID`
override `runner.group` and `runner.id` (an empty value never blanks a file
value), and `cloud.enrollment_key_env` names the bootstrap credential (normally
`EMISAR_ENROLLMENT_KEY`). `EMISAR_PACKS_REGISTRY` and
the `--registry` flag select a pack registry.

With no command, the MCP bridge keeps its stdio behavior. Its direct CLI surface
has a local `auth` / `auth login [URL]` browser device flow, local
`auth status [URL]`, `accounts list [--json]`, `accounts use <slug-or-id>`, `connect [--all | --client <id>]`, and
`disconnect [--all | --client <id>] [--forget]`, then a descriptor-driven tool
surface: `list_tools [--json]` lists the live server catalog, `help <tool>
[--json]` and, for non-conflicting names, `<tool> --help` document one live
descriptor. `<tool> [JSON | -]` calls any exact tool name with an omitted `{}`,
one inline JSON object, or an object read from stdin. `-- <tool> [JSON | -]`
bypasses the local command namespace for an exact conflicting name. Calls print
purpose-built readable text for the thirteen fixed tools by default; an unknown
future tool falls back to the generic structured-object renderer. `list_tools`
groups the live catalog for people, while `list_tools --json` remains the exact
descriptor array. `--json` makes one logical tool invocation, follows no
continuations, and prints its exact `structuredContent`; the transport may
resend the identical request under the same operation ID during bounded network
or credential recovery. Default-output `run_action` and `execute_runbook` may
make additional `wait_for_run` calls, but only by following exact
server-returned continuations correlated to the same run or execution; they
never issue a second mutation. Server, tool, configuration, and transport failures exit 1, local
usage failures exit 2, and Ctrl-C during human mutation observation exits 130
without claiming to cancel the work. Human `run_action` also exits 1 for
terminal `failed`, `error`, `validation_failed`, `unknown_action`, `denied`,
`cancelled`, `timed_out`, or `refused`; `execute_runbook` exits 1 for `halted`
or `cancelled`. Tool names and schemas remain owned by
`tools/list`, not compiled into an independent bridge registry. `--account
<slug-or-id>` selects one stored account for one command; the other global flags
remain `-h/--help` and `-v/--version`. Its environment is:

```text
EMISAR_URL              required stdio origin; optional direct-CLI override
EMISAR_API_KEY          required stdio key; optional direct-CLI override
EMISAR_CLIENT           optional audit label
EMISAR_CLIENT_METADATA  optional untrusted audit metadata
EMISAR_ALLOW_INSECURE   development-only cleartext opt-in
EMISAR_SIGNING_KEY      optional local signing key
EMISAR_SIGNING_CERT     optional certificate for that key
```

With no command, it reads and writes line-delimited JSON-RPC 2.0 over stdio. In
stdio mode both authentication variables are required. Direct commands use the
current owner-only stored account credential only when both variables are
absent; an explicit pair overrides it, while a partial pair fails rather than
mixing sources. In both modes it sends the user agent `emisar-mcp/<version>`.
The attestation identifier `emisar-attestation-v5` and the dispatch certificate
profile `emisar-x509-profile-v1` are also frozen security formats.
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
`install-mcp.sh` installs the stdio bridge on macOS and Linux, and
`install-mcp.ps1` installs it on Windows. They are public script entry points
that select binaries from the Emisar release mirror, with GitHub Releases as
the fallback.

Generated bootstrap commands use the conventional `curl -fsSL` spelling. Their
initial origin must use HTTPS; plain HTTP is accepted only for
`localhost`/`*.localhost`, IPv4 loopback or RFC1918 literals, IPv6 loopback, and
IPv6 ULA literals. Private DNS names are not resolved to infer safety and
therefore require HTTPS. Once running, both installers constrain their GitHub
API, release artifact, and checksum downloads to HTTPS with HTTPS-only
redirects.

**How they are versioned today.** The script interfaces are flag- and
environment-based, not protocol-negotiated. `install.sh` accepts runner tags
in `runner-vX.Y.Z`, `vX.Y.Z`, or `X.Y.Z` form and flags including `--yes`,
`--uninstall`, `--purge`, `--no-start`, `--no-service`,
`--bin-dir`, `--etc-dir`, `--data-dir`, `--log-dir`, `--user`, and `--packs`. Its environment
includes `VERSION`, the directory and service settings, `EMISAR_PACKS`,
`EMISAR_URL`, and `EMISAR_ENROLLMENT_KEY`.
An unattended runner install requires `--yes` plus an explicit
`--packs`/`EMISAR_PACKS` value; an explicitly empty value installs no new packs
and preserves existing ones. A caller without a controlling terminal is refused
without `--yes`. Interactive installs may leave pack selection unset to review
host-matched recommendations.

`install-mcp.sh` accepts `--version`, `--install-dir`, `--uninstall`, and
`--yes`. It accepts
`VERSION`, `INSTALL_DIR`, `EMISAR_REPO`, `EMISAR_GITHUB_TOKEN`, `ASSUME_YES`,
and `EMISAR_URL` (the portal the connection phase talks to and writes into
configs; default `https://emisar.dev`). The bridge installer also requires the
selected GitHub release to be marked immutable. The current release tags are
`runner-v0.22.1` and `mcp-v0.10.1`.

**The installers place the binary; the bridge owns the connection phase.** An
interactive install runs `emisar-mcp connect` as the invoking user, and
`--uninstall` runs `emisar-mcp disconnect --all --forget --yes` before removing
the binary. Both are also operator commands in their own right, so a client
installed later is connected without reinstalling the bridge. Because the
script is fetched fresh while the installed binary is whatever the operator
has, `--uninstall` probes for the verb first and reports that client entries
were left in place when the bridge predates it, rather than reporting a
removal that did not happen.

`install-mcp.ps1` accepts `-Version`, `-InstallDir`,
`-PortalOrigin`, `-Uninstall`, `-Yes`, and `-ConnectAll`. It installs the native
`windows-amd64` or `windows-arm64` zip per user, verifies `SHA256SUMS-MCP`, and
checks Sigstore provenance when an authenticated GitHub CLI is available. It
uses protected Windows DACLs for the binary directory and direct-CLI
credentials, and delegates the connection phase to the same `connect` and
`disconnect` commands.

**`emisar-mcp connect` / `disconnect`.** `connect` accepts `--url <origin>`,
`--all`, `--client <id>` (repeatable), `--yes`, and `--auto-permit`;
`disconnect` accepts `--all`, `--client <id>`, `--yes`, and `--forget` (also
delete every stored direct-CLI account and the bridge's rotation state). Both
ignore `EMISAR_URL` and `EMISAR_API_KEY` for credential decisions, because they
operate on per-account stored state rather than an ambient key. `connect`
requests a dedicated `emisar-mcp-cli` key plus one key per selected client from
a single device-authorization grant, and writes nothing until every requested
key validates. A stored CLI credential that still authenticates against the
same endpoint makes a rerun hands-off; a credential the control plane rejects
starts a fresh approval, while a transport failure does not. This drives the
portal's device-authorization pair, whose frozen contract lives in the OAuth
authorization server section above; the installers and bridge are the deployed
consumers its skew note describes.

The client contract is Claude Code, Claude Desktop, Cursor, VS Code, Gemini
CLI, Codex CLI, OpenClaw, OpenCode, Windsurf, Pi, Copilot CLI, Zed, Hermes,
Goose, and Grok CLI. Each writes that client's own schema, backs an existing
file up to `<config>.emisar-bak`, and edits the document textually so comments,
key order, and every unrelated setting survive byte for byte. VS Code means the
stable default user profile: its user-level `mcp.json` references an owner-only
`vscode.env` beside the bridge's credential state instead of carrying the API
key in a file the editor may synchronize. Other profiles and VS Code Insiders
use the console's manual snippet. `--auto-permit` additionally silences a
client's own per-tool prompt for the emisar server alone, and only for the four
clients that scope that setting to one server: Claude Code, Gemini CLI, Codex
CLI, and Grok CLI. Every adapter's install, unrelated-setting preservation,
backup, and removal path is table-tested in `mcp/clientconfig_test.go`; the
native installer harness covers the installed binary end to end.

**What happens on skew.** A renamed installer flag or environment variable
fails the one-liner with an unknown-option or missing-configuration error. A
changed release asset name fails the download or verification step. The
scripts do not negotiate an older interface, so a 1.0 change must keep the
old input and asset path during the deprecation window or publish an explicit
migration.

### Official runner container image

**What it is.** The hardened runner release process publishes
`ghcr.io/andrewdryga/emisar-runner:<version>` (linux/amd64 + linux/arm64,
signed provenance + SBOM), built by the exact-SHA
`runner-release-trusted.yml` reusable workflow (triggered by
`runner-release.yml`) from
`runner/release/Dockerfile` around the exact tested release binary. Its
operator-facing contract is the image name and version-tag scheme (no `latest`
tag is published), the `EMISAR_ENROLLMENT_KEY` / `EMISAR_URL` /
`EMISAR_GROUP` / `EMISAR_RUNNER_ID` environment
variables, the default config at `/etc/emisar/config.yaml`, state under
`/var/lib/emisar`, packs under `/opt/emisar/packs`, the observation-only
default (baked admission caps at `low` risk), and the non-root uid 65532 —
the container and Kubernetes docs and operators' extension Dockerfiles
(`FROM` + tools + `emisar pack install`) all depend on these.

**How it is versioned today.** Tags follow the runner release version, and a
published version tag is never moved to a different digest (the release
workflow refuses); each release's notes carry the digest reference. A given
digest is immutable — same runner, packs, and OS packages forever. The baked
pack set (`runner/release/container-packs.txt`) is deliberately small and may
change between releases; it is not itself a frozen contract.

**What happens on skew.** A renamed image, retagged version, moved config or
state path, or changed uid breaks deployed pull specs, mounted configs,
volume ownership, and extension Dockerfiles with no negotiation layer. At 1.0
these freeze like the install scripts: a breaking change needs a new image
name or a major release, following the deprecation path.

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

This policy records the boundary. Runner shutdown handling, the mechanical wire
golden, and catalog retirement watermarks are implemented today. General
CLI/MCP deprecation signaling is not; until that additive warning path exists,
a 1.x release must preserve the old CLI or MCP form instead of starting a
deprecation clock it cannot surface.
