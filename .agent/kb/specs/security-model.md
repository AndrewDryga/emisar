# Security model

## What emisar gives you

1. **No inbound surface.** The runner dials out to the control plane over a
   TLS websocket. There is no emisar listener on the host and no inbound
   port-scan target.
2. **No cloud-supplied command line.** Actions declare a literal `binary` and
   argv array, which the runner executes with `os/exec`. Most actions call a
   binary directly. A pack may declare a fixed `/bin/sh -c` program for pipes
   or other shell features, but that program is pack-authored. Open-ended
   strings and paths reach it through environment variables or whole positional
   argv elements; only finite choices and two-sided bounded numbers may be
   substituted into the program text. The pack loader rejects other references
   at authoring time.
   The staging-only `shell` pack is the explicit critical-risk break-glass
   exception: it accepts an operator-supplied script and is default-denied.
3. **No request-time script files.** Script-kind actions reference a file
   inside the owning pack. The script's SHA-256 is computed at load time,
   rechecked immediately before execution, and journaled with every
   invocation. Callers cannot upload or replace script content at run time.
4. **Schema-validated args.** Every action declares its arguments with
   types, defaults, enums, patterns, and path allow/deny. Unknown args
   are rejected; missing required args are rejected; types are coerced. Path
   rules resolve symlinks, and execution receives the canonical target that
   passed containment rather than the caller's lexical alias. Pathname APIs
   cannot prevent an actor with write access to an ancestor from replacing it
   between validation and the child opening the path; keep elevated actions
   away from attacker-writable trees and run the runner least-privileged.
5. **Double validation.** The control plane pre-validates every request and
   applies policy; the runner still re-checks every arg against the action's
   declared schema before executing.
6. **Clamped opts.** Per-call opts (`timeout_ms`, `max_*_bytes`) are clamped
   to the action's declared min/max envelope. A misbehaving cloud cannot
   ask for a 100h timeout on an action that declares a 30s ceiling.
7. **Output redaction.** Bearer tokens, AWS keys, GitHub tokens,
   private-key blocks, and common `password=`/`secret=`/`token=`
   assignments are masked by default. Pack authors can add per-action
   rules. Redaction runs **before** the chunk leaves the runner.
8. **Limits.** Every action has a timeout and stdout/stderr byte ceiling.
   Cloud opts can lower these but not raise them above the action's max.
   When an action declares `user:`, the runner resolves that local
   user/group and drops to its uid/gid via `SysProcAttr.Credential` on
   Linux before exec — so an action targeting Cassandra can run as the
   `cassandra` user even when the runner ships under a different
   service account.
9. **Environment hygiene.** Child processes get a minimal baseline env
   (`PATH`, `LANG`, `LC_ALL`, `TERM`) plus whatever the operator
   explicitly lists in `execution.inherit_env` — the runner's own
   environment (and its auth secrets) never leaks through. Packs that
   try to set hijack-vector variables (`LD_*`, `DYLD_*`, `BASH_ENV`)
   are rejected at validation time.
10. **Process containment on exit.** Children run in their own process
    group (`Setpgid`), and the runner signals the whole group — SIGTERM,
    then SIGKILL after the grace window — on cancel, on timeout, and when
    the runner itself exits. On Linux `Pdeathsig: SIGKILL` is the kernel
    backstop for a runner that cannot run that shutdown path at all (OOM
    kill, SIGKILL, panic). It reaches the direct child only, so a wrapper
    script that forks a worker and exits still orphans that worker to
    init: pack authors `exec` the target binary, or `trap` and forward
    signals. Losing the websocket is deliberately not an exit — in-flight
    actions keep running and replay their result on the next connection.
11. **Local admission control.** An optional `admission:` block in
    `config.yaml` filters what this host will even advertise — by action
    id (allow/deny globs) and by a `max_risk` ceiling (one flag turns a
    fleet read-only for a demo, dropping high/critical actions). A rule
    baked into the image overrides anything the cloud asks for: a
    suppressed action is hidden from the catalog AND refused at dispatch,
    journaling `action_blocked_by_admission`.
12. **A local hash-chained JSONL log.** Every dispatch decision produces a
   terminal line in `/var/log/emisar/events.jsonl`. An accepted execution first
   records `execution_started` immediately before crossing the process boundary,
   then records its terminal outcome; a crash can therefore leave an unmatched
   start rather than erasing evidence that execution began. Pre-execution trust,
   signature, capacity, and reservation refusals record `dispatch_refused`
   without persisting untrusted arguments. Each entry carries
   `prev_hash = sha256(previous_line)`, so reordering, mutation, or interior
   deletion within the retained journal is detected by `emisar audit verify`.
   The runner only appends to the file. Verification cannot prove that a
   privileged host operator did not replace or truncate the entire local
   journal; that requires an external anchor such as the off-host cloud audit.
13. **Bridge-attested dispatch (optional).** With `signing.enforce_signatures`
    on, the runner runs a dispatch only if it carries a valid signature from an
    Ed25519 or ECDSA P-256 leaf key
    over the canonical portal origin, action, immutable pack, digest of the
    exact JSON args, digest of the complete identity-bound runner-ref set,
    reason, digests of the evidence and expected result, operation ID, nonce,
    and timestamp. The leaf key is vouched for by
    a still-valid, in-scope certificate signed by a trusted, offline certificate
    authority. The runner requires exactly one ref with its locally derived
    identity suffix in the signed target set; the certificate's CA-asserted
    scope is a second group/label ceiling. The leaf private key lives only in the
    customer-authorized MCP bridge and the CA private key stays offline; the
    control plane holds neither, so it can relay a bridge-signed action but never
    forge, alter, widen its signed targets, or originate one. Preserved replay
    state prevents nonce reuse on that runner identity. Replay state is
    process-owned and durable: every hot-reloaded verifier
    shares the same nonce store, so a policy swap cannot forget a nonce consumed
    during reload. A replacement that reuses an external ID must preserve the
    nonce store or rotate its identity and trust material. The narrative digests
    bind what the bridge supplied, but they do not independently authenticate
    text rendered by a compromised control plane. The runner advertises
    enforcement and the cloud then disables
    its own (operator/runbook/API) dispatch to that host. See
    [`signed-dispatch.md`](signed-dispatch.md).

## What emisar is not

- **It is not a VM, container, or kernel sandbox.** Restarting Cassandra
  still restarts Cassandra. emisar is a curated allowlist with an audit
  envelope; it does not isolate the process from the host.
- **It is not an EDR.** It does not detect general host tampering, malicious
  binaries, or lateral movement. It does detect a broken local journal hash
  chain and rejects a pack whose on-disk hash no longer matches the trusted
  cloud-pinned hash before execution.
- **It does not guarantee read-only commands cannot leak.** `journalctl`
  output can contain operational secrets no rule will catch. Treat
  read-only output as confidential by default.
- **It is not the audit system of record.** Cloud is. The JSONL log is
  for on-host inspection; cloud holds the durable, queryable fleet log.
- **It is not a replacement for least privilege.** Run the runner as an
  unprivileged user with only the permissions it needs.

## Trust model: runner vs. actions

emisar is a **sysadmin's deputy**. The runner runs operator-authored
actions on the operator's behalf. The runner does NOT try to sandbox
its actions from itself:

- Actions are intentionally permissioned by the operator. The schema
  validation, policy gating (cloud), and JSONL audit are the
  enforcement layer. Adding a kernel sandbox on top would fight the
  operator: an action that needs to read `/home/<user>/foo` or write
  to `/tmp/myapp-cache/` should be able to.
- The default shipped systemd unit runs the runner as a dedicated
  unprivileged user (`emisar`). That is the security boundary —
  actions can do whatever the OS lets that user do.
- Linux action children always enter `no_new_privs`, so sudo and other
  setuid/setgid helpers cannot elevate them, and file capabilities on action
  binaries cannot add authority. Give the runner user narrow direct access
  through groups or ACLs, or use a mediated service boundary such as
  polkit/D-Bus. See [`runner/README.md`](../../../runner/README.md#giving-actions-the-os-access-they-need).
- Operators who want defense-in-depth sandboxing on top can drop in
  an opt-in systemd hardening override. See
  [`runner/README.md`](../../../runner/README.md#hardening-optional).
- The runner's **host is the trust anchor**, cloud-side too. Attributes a
  runner declares about itself on connect — notably its `group`, which
  selects the policy override governing dispatches *to that runner* — are
  trusted as given. A compromised host could declare a looser `group` to
  widen its own policy, but it already has code execution on the very box
  the runner executes on, so it gains nothing it couldn't already do
  locally. Pin `group` to the auth key (cloud-side) if you want it
  operator-authoritative rather than runner-declared.

## Threats considered

| Threat                                   | Mitigation                                                    |
| ---------------------------------------- | ------------------------------------------------------------- |
| LLM constructs a malicious shell string  | It cannot choose the binary or command program; the loader rejects open-ended values in shell program text and requires data-only env/argv channels. The arbitrary-shell pack is staging-only, critical-risk, and default-denied. |
| LLM passes unexpected arguments          | Unknown args rejected; declared schema enforced on runner.     |
| Cloud bug sends bogus opts (huge timeout)| Opts clamped to action min/max.                               |
| LLM tries to read /etc/shadow            | Path arg `denied_paths`; OS perms still apply.                |
| Output contains a stray bearer token     | Default + per-action redaction rules; size caps.              |
| Runaway process                          | Timeouts enforced via `context.WithTimeout`.                  |
| Output flood                             | Stdout/stderr byte caps; buffered progress is bounded, dropped chunks are counted structurally, and portal summaries mark incomplete delivery. |
| Runbook definition exhausts parser or scheduler | One strict JSON-only schema rejects unknown shapes and enforces byte, depth, node, stage, step, target, output, condition, fan-out, wait, and lifetime caps before persistence or dispatch. |
| Runbook regex consumes unbounded work | Expressions and source text are byte-bounded; PCRE match and recursion limits fail the item closed. Patterns remain data and never enter a command. |
| Runbook binds output from the wrong host | Output bindings may name only an earlier stage and must resolve to one unique producer or the same runner across fan-out. Ambiguous correlation fails preflight. |
| Pack fleet moves after runbook review | Preflight plans every item against the exact trusted pack its frozen runner deploys and freezes the full pack ref, hash, and action contract. Every later attempt rechecks those frozen facts. |
| Partial fleet mutation after target drift | The complete expanded target set must be in caller scope before creation; later authorization or trust loss halts before the next attempt or stage. Already-running peers only settle their real outcome. |
| One-runner group selection hides an incompatible or unauthorized peer | Preflight validates every online member in the subject-visible group before deterministically freezing one exact runner. The plan and approval retain the source group; a later disconnect halts instead of reselecting. |
| Approval hides a wider execution fan-out | Any item that requires approval opens one approval over the complete frozen execution before any action run exists; approver runner scope is checked against every item at notification, visibility, and decision. |
| An approval quorum is bypassed without accountable evidence | A current account owner or admin may deliberately use break-glass approval. Their active membership and role are rechecked under lock; a non-blank reason is mandatory; and one `approval.overridden` event records the actor, reason, approvals present, required quorum, reviews waived, and whether requester separation was waived. The operation creates neither an approval vote nor a standing grant. Target scope, expiry, cancellation, pack trust, dispatch-signature freshness, initiating-member authorization, and runner admission still apply. This is explicit owner/admin authority: quorum and self-approval rules do not protect against a malicious or compromised owner/admin. |
| Pack swapped on disk after trust         | Runner recomputes the cloud-pinned trusted hash before execution. |
| Pack sets `LD_PRELOAD`/`BASH_ENV`        | Hijack-vector env vars rejected at pack validation.           |
| Action outlives a dying runner           | Process-group SIGTERM/SIGKILL on cancel, timeout, and runner exit, with `Pdeathsig` (Linux) as the backstop for a hard kill. `Pdeathsig` reaches the direct child only, so a wrapper script that forks and exits orphans its worker unless it `exec`s or forwards signals. |
| Inbound surface attacked                 | There is none.                                                |
| Compromised runner declares a looser policy `group` | Accepted: `group` is runner-declared and the host is the trust anchor — a host that can forge it already owns the box the runner executes on, so widening its own policy buys nothing. Pin `group` to the auth key for operator-authoritative scoping. |
| TOFU pack understates an action's `risk`/`kind`     | Accepted: those are runner-declared, so trusting a pack's *hash* = trusting its declared risk. A pack whose hash matches the configured published catalog carries its risk inside the hash that catalog authorized; a TOFU pack (no catalog entry) has no such anchor. Pin risk at trust-time if you need it author-independent. |
| Compromised publisher of the configured catalog     | Accepted, bounded: whoever can write the catalog a portal fetches can authorize matching bytes already installed on a host, choose the trusted risk and kind that policy evaluates for those bytes, and set, lower, drop, or raise retirement floors. They cannot install bytes, bypass the runner's descriptor equality, argument validation, or local admission checks, or erase audit. The catalog is fetched over HTTPS, validated as a complete document, and its tarball URLs are pinned under the configured registry base, so an off-base or malformed document is refused and the last accepted snapshot is kept. |
| Compromised control plane forges or replays a dispatch | With `signing.enforce_signatures` on, the runner requires a valid v5 signature from an Ed25519 or ECDSA P-256 leaf key. The claim binds the canonical origin, action, immutable pack, exact arguments, complete identity-bound runner references, reason, evidence and expected-result digests, operation, nonce, and time. A trusted offline CA vouches for the leaf key. The cloud holds neither private key, so it cannot forge or widen the claim. The freshness window and fsynced replay journal prevent nonce reuse while durable replay state is preserved. A replacement that reuses an external ID must preserve that state or rotate its identity and trust material. CA scope adds a group or label ceiling. The cloud can still withhold a call, lie about display names during discovery, or render narrative text that does not match the signed digests. A queued call can also become stale. Verify runner suffixes and bridge-supplied approval narratives out of band, and use narrow certificate scopes for the highest-trust workflows. See [`signed-dispatch.md`](signed-dispatch.md). |

## Threats *not* considered (yet)

- Local privilege escalation via the executor user. emisar runs `argv`
  exactly as declared; the OS still owns access decisions.
- Pack-catalog publisher signature verification. The current model accepts a
  structurally valid catalog fetched over HTTPS from the configured origin;
  storage write controls and the publication workflow authenticate that
  publisher operationally, not cryptographically. Catalog signing would add an
  independent publisher-identity check for first- or third-party catalogs.
  (Distinct from *dispatch* signing — bridge-attested dispatch above, which is
  shipped.)
- Cryptographic signing or external anchoring of the local JSONL chain.
  Verification covers the retained journal or retained suffix; it cannot prove
  that a privileged host operator did not replace or truncate the entire local
  journal. Cloud audit is the durable fleet record; use WORM-capable storage
  when stronger on-host guarantees matter.

## Control-plane and runner boundary

The runner-side guarantees above pair with the control plane's own model:

- Every bearer credential is hashed at rest — sessions, email tokens,
  invitations, API keys, runner auth keys, per-runner tokens, OAuth
  access/refresh tokens, MFA recovery codes. A database leak yields no
  replayable secrets.
- Policy is default-deny: no policy row, no matching tier default, no
  override → the dispatch is refused.
- An MCP credential is an `:mcp`-kind API key or an OAuth token (PKCE
  S256 only). It carries no per-key authorization scope of its own: what
  it may do is decided by the account's policy, the approval gate, and
  the runner ACL of the operator who minted it, which narrows the hosts
  it can touch at all.
- Operator sign-in supports TOTP MFA with one-shot hashed recovery
  codes; approvals and credential lifecycles are all audited.
- Emisar staff reach a customer workspace through a read-only console at
  `/admin` — account search and an account detail view — gated on a
  platform `is_admin` flag, an enrolled second factor, and a session that
  proved that factor against the current enrollment. Staff hold no
  membership in the accounts they inspect, so the gate is the whole
  boundary. Every account detail view writes a `staff.account_viewed`
  event into that account's own audit trail, which the customer reads:
  access transparency, not an internal-only log. Support mutations are
  not on that console at all — they run through a private, colocated
  action pack over release RPC, so each one is an ordinary audited run.
- The BEAM operational dashboard at `/ops/live` is a separate surface
  behind the same `is_admin` and proven-MFA gate, and it does not share
  the staff console's two properties. It is not read-only: it can
  terminate a process on the running node, which on this product may be a
  customer's runner websocket or an in-flight approval transaction. And it
  is not account-attributed: it reads live node state across every tenant
  at once and writes no `staff.*` event, so nothing it shows or does
  reaches a customer's audit trail. Treat reaching it as an insider-risk
  action gated by the platform admin flag, not as customer-visible access.

Runbook definitions, typed inputs, bindings, extractor patterns, action output,
and runner/catalog state are all untrusted input. Static validation happens
before save or publication; execution preflight then resolves dynamic scope and
trusted contracts. The operation record, immutable expanded plan, execution,
stages, and logical items commit atomically. Physical action attempts commit
before runner delivery, and every scheduler advance locks the durable execution
state so overlapping callbacks and recovery sweeps are idempotent.

Sensitive inputs and extracted outputs are redacted from human/model plans,
result projections, approval context, and audit evidence. Their bounded raw
values remain in the control-plane execution record where needed to materialize
later bindings and wait attempts. Treat database access and backups as access
to operational secrets; redaction is an output boundary, not application-level
encryption of those execution fields.

| Question | Answer |
| --- | --- |
| Who decides what should happen? | Control-plane policy and an authorized caller. |
| Who creates and decides approvals? | Control plane and authorized human operators. |
| Who enforces the action schema? | Runner, immediately before execution. |
| Who enforces pack contents? | Control plane pins trust; runner recomputes the pinned hash. |
| Who installs packs and grants OS privileges? | Host operator through the image/configuration pipeline and OS controls. |
| Who stores searchable fleet history? | Control plane. |
| Who keeps the local forensic record? | Runner, as hash-chained JSONL. |
| Who composes runbooks? | Control plane; the runner receives one action at a time. |

The hosted control plane is the supported product boundary. The repository
contains deployable control-plane source for evaluation, but supported
self-hosted and air-gapped control-plane deployments are not generally
available.

## Operational checklist

- Run as a dedicated unprivileged user.
- Keep the bootstrap key and per-runner token in the root-readable installer
  environment file or a secrets manager. Do not commit them.
- Treat each pack as code. Packs are baked into VM images by your image
  pipeline; reviewing them is reviewing what the LLM can do on that host.
- Audit the JSONL log for `dispatch_refused`, `validation_failed`,
  `execution_failed`, and `execution_started` events without a later terminal
  event for the same request — they're often the most interesting signal.
