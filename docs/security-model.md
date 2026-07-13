# Security model

## What emisar gives you

1. **No inbound surface.** The runner dials out to the control plane over a
   TLS websocket. There is no emisar listener on the host and no inbound
   port-scan target.
2. **No cloud-supplied command line.** Actions declare a literal `binary` and
   argv array, which the runner executes with `os/exec`. Most actions call a
   binary directly. A pack may declare a fixed `/bin/sh -c` program for pipes
   or other shell features, but that program is pack-authored and every
   substituted argument must be schema-bounded against shell metacharacters.
   The staging-only `shell` pack is the explicit critical-risk break-glass
   exception: it accepts an operator-supplied script and is default-denied.
3. **No request-time script files.** Script-kind actions reference a file
   inside the owning pack. The script's SHA-256 is computed at load time,
   rechecked immediately before execution, and journaled with every
   invocation. Callers cannot upload or replace script content at run time.
4. **Schema-validated args.** Every action declares its arguments with
   types, defaults, enums, patterns, and path allow/deny. Unknown args
   are rejected; missing required args are rejected; types are coerced.
5. **Double validation.** The control plane pre-validates every request and
   applies policy; the runner still re-checks every arg against the action's
   declared schema before executing.
6. **Clamped opts.** Per-call opts (`timeout`, `max_*_bytes`) are clamped
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
    group (`Setpgid`); cancel/timeout SIGTERMs the whole group, then
    SIGKILLs after the grace window. On Linux `Pdeathsig: SIGKILL` makes
    the kernel reap the child if the runner itself dies — no orphaned
    actions outliving their supervisor.
11. **Local admission control.** An optional `admission:` block in
    `config.yaml` filters what this host will even advertise — by action
    id (allow/deny globs) and by a `max_risk` ceiling (one flag turns a
    fleet read-only for a demo, dropping high/critical actions). A rule
    baked into the image overrides anything the cloud asks for: a
    suppressed action is hidden from the catalog AND refused at dispatch,
    journaling `action_blocked_by_admission`.
12. **A local hash-chained JSONL log.** Every attempt — validation-failed,
   executed, errored — produces a line in `/var/log/emisar/events.jsonl`.
   Each entry carries `prev_hash = sha256(previous_line)`, so cutting,
   reordering, or mutating any line is detected by `emisar audit verify`.
   The runner only appends to the file. It is meant for on-host forensics;
   a privileged attacker can still delete or rewrite the entire file.
13. **Client-attested dispatch (optional).** With `signing.enforce_signatures`
    on, the runner runs a dispatch only if it carries a valid Ed25519 signature
    — over the action, exact JSON args, durable runner-id set, nonce, and
    timestamp — from a leaf key vouched for by a still-valid, in-scope
    certificate signed by a trusted, offline certificate authority, inside a
    freshness window, with a nonce it hasn't seen. The runner requires its local
    durable id in the signed target set; the certificate's CA-asserted scope is
    a second group/label ceiling. The leaf private key lives only in the
    operator's MCP client and the CA private key stays offline; the control
    plane holds neither, so it can relay a user-signed action but never forge,
    alter, widen its signed targets, replay it on a selected runner, or originate
    one. Replay state is process-owned and durable: every hot-reloaded verifier
    shares the same nonce store, so a policy swap cannot forget a nonce consumed
    during reload. The runner advertises enforcement and the cloud then disables
    its own (operator/runbook/API) dispatch to that host. See
    [`docs/signed-dispatch.md`](signed-dispatch.md).

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
- Operators who want to grant elevated privileges to specific
  actions configure sudo / polkit / capabilities for the runner
  user. See [`runner/README.md`](../runner/README.md#granting-elevated-privileges-to-specific-actions).
- Operators who want defense-in-depth sandboxing on top can drop in
  an opt-in systemd hardening override. See
  [`runner/README.md`](../runner/README.md#hardening-optional).
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
| LLM constructs a malicious shell string  | It cannot choose the binary or command program; substituted values are schema-validated. The arbitrary-shell pack is staging-only, critical-risk, and default-denied. |
| LLM passes unexpected arguments          | Unknown args rejected; declared schema enforced on runner.     |
| Cloud bug sends bogus opts (huge timeout)| Opts clamped to action min/max.                               |
| LLM tries to read /etc/shadow            | Path arg `denied_paths`; OS perms still apply.                |
| Output contains a stray bearer token     | Default + per-action redaction rules; size caps.              |
| Runaway process                          | Timeouts enforced via `context.WithTimeout`.                  |
| Output flood                             | Stdout/stderr byte caps; surplus dropped, counted, signalled. |
| Pack swapped on disk after trust         | Runner recomputes the cloud-pinned trusted hash before execution. |
| Pack sets `LD_PRELOAD`/`BASH_ENV`        | Hijack-vector env vars rejected at pack validation.           |
| Action outlives a dying runner           | `Pdeathsig` (Linux) + process-group SIGTERM/SIGKILL on cancel/timeout. |
| Inbound surface attacked                 | There is none.                                                |
| Compromised runner declares a looser policy `group` | Accepted: `group` is runner-declared and the host is the trust anchor — a host that can forge it already owns the box the runner executes on, so widening its own policy buys nothing. Pin `group` to the auth key for operator-authoritative scoping. |
| TOFU pack understates an action's `risk`/`kind`     | Accepted: those are runner-declared, so trusting a pack's *hash* = trusting its declared risk. A compiled-baseline pack's risk is inside the trusted hash; a TOFU pack (no baseline) has no such anchor. Pin risk at trust-time if you need it author-independent. |
| Compromised control plane forges or replays a dispatch | With `signing.enforce_signatures` on, the runner requires a valid v3 Ed25519 client signature over an unambiguous JSON body containing the action, exact args digest, durable runner-id-set digest, nonce, and time, under a leaf key vouched for by a trusted offline CA. The cloud holds neither private key, so it cannot forge the claim or widen its signed targets; the freshness window and bounded, fsynced replay journal prevent reuse without evicting live nonces, and CA scope adds a group/label ceiling. Limitations: the cloud can withhold a call or lie about the human-readable id/name mapping during discovery, and a queued call can become stale. Verify ids out of band and use narrow cert scopes for the highest-trust workflows. See `docs/signed-dispatch.md`. |

## Threats *not* considered (yet)

- Local privilege escalation via the executor user. emisar runs `argv`
  exactly as declared; the OS still owns access decisions.
- Pack *publisher* signature verification. The current model relies on the
  image build pipeline being trusted; pack signing becomes useful when
  third-party packs join the catalog. (Distinct from *dispatch* signing —
  client-attested dispatch above, which is shipped.)
- Cryptographic signing or external anchoring of the local JSONL chain.
  The hash chain detects mutation within the retained file, but a privileged
  attacker can replace the entire file. Cloud audit is the durable fleet
  record; use WORM-capable storage when stronger on-host guarantees matter.

## Control-plane and runner boundary

The runner-side guarantees above pair with the control plane's own model:

- Every bearer credential is hashed at rest — sessions, email tokens,
  invitations, API keys, runner auth keys, per-runner tokens, OAuth
  access/refresh tokens, MFA recovery codes. A database leak yields no
  replayable secrets.
- Policy is default-deny: no policy row, no matching tier default, no
  override → the dispatch is refused.
- MCP access is scoped (`actions:read`, `actions:execute`,
  `audit:read`) over API keys or OAuth (PKCE S256 only), and per-user
  runner ACLs narrow which hosts an operator or key can touch at all.
- Operator sign-in supports TOTP MFA with one-shot hashed recovery
  codes; approvals and credential lifecycles are all audited.

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
- Audit the JSONL log for `validation_failed` and `execution_failed`
  events — they're often the most interesting signal.
