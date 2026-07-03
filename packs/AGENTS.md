# packs — how we build (the action-pack catalog)

`packs/` is the catalog of **infrastructure actions** the runner executes and the portal exposes to operators and LLMs (via MCP). Each `packs/<name>/` is a `pack.yaml` manifest plus `actions/*.yaml` — ~73 packs / ~1,100 actions today. **This is attack surface**: every action declares exactly what may run on a host, so the runner and policy can enforce a hard boundary. Read the root `../AGENTS.md` (the creed) first. The authoritative schema is the Go types in `runner/pkg/actionspec` + `runner/pkg/packspec`; this file is the conventions.

## The gate (verify before claiming done)

A pack change is done only when it validates:

```
emisar pack validate packs/<name>      # → "pack <id> OK: <n> actions" + the sha256
```

That runs the runner's load-time checks. A malformed pack breaks **both** consumers: the runner (loads + SHA-256-pins each pack at runtime) and the portal (`EmisarWeb.PacksRegistry` compile-scans every `packs/*/pack.yaml` at build time, so a bad pack **fails the portal build**). Validate every pack you touch.

**Editing `redis/` or `cassandra/`? Refresh the cross-impl hash golden too.** The portal test `apps/emisar_web/test/emisar_web/packs_test.exs` pins the `content_hash` of **redis** (exec-only) and **cassandra** (has a script-kind action) byte-for-byte — the proof that the Elixir `PacksRegistry` and the Go runner hash a pack identically. **`emisar pack validate` does NOT run that test**, so ANY byte change to those two packs (including a catalog-wide sweep that touches their action text) leaves the golden stale and the *portal* build RED — silently, from the packs side. After editing redis/ or cassandra/: copy the new `sha256:` that `emisar pack validate` prints into the two golden literals in `packs_test.exs`, then run the portal packs_test (`cd portal/apps/emisar_web && mix test test/emisar_web/packs_test.exs`) to confirm the Elixir hash agrees. Commit the golden refresh **with** the pack change.

## Anatomy

```
packs/<name>/
  pack.yaml        # id, name, version, description, requires/detect/setup, actions: [actions/*.yaml]
  actions/*.yaml   # one action each (kind: script also ships scripts/*.sh)
```

An **action** declares: `id` (`<namespace>.<name>`), `risk` (low|medium|high|critical), `kind` (exec|script), `args` (typed + validated), `execution` (binary + argv template, timeout, env), and `output` (parser + byte caps + redaction).

## Conventions (non-negotiable — this is a security product)

- **The cloud/LLM never controls the shell command.** `execution.command.argv` is a list and `{{ args.x }}` substitutes into its slots. Prefer a real binary's argv. When an action genuinely needs shell features (pipes, `${VAR:-default}`), `binary: /bin/sh` + a fixed `-c '<pipeline>'` script is supported — the script is *authored here, never cloud-supplied*, and every interpolated `{{ args.x }}` MUST be bounded (enum / numeric / an anchored `pattern` that blocks shell metacharacters) so a hostile arg can't break out of its slot. The **`shell` pack is the separate break-glass**: there the OPERATOR supplies the whole command (arbitrary `/bin/sh -c`, `risk: critical`, default-denied — staging only).
- **Binary paths are bare, PATH-resolved names** (`systemctl`, `psql`), never absolute. `/bin/sh` is the sole absolute exception — used by the `shell` break-glass pack AND by the many read actions that need a shell pipeline.
- **Bound every LLM-supplied arg.** Strings/paths get `max_length`; prefer `enum`/`allowed`/`pattern` whitelists over blocklists; path args use `allowed_paths`/`denied_paths` (symlink-contained). An unbounded string arg is a DoS hole.
- **Packs are generic across every fleet — never hardcode an environment-specific allowlist.** An arg that names a *deployment-specific* identifier — a systemd unit, a service, a database, a host — must NOT be a hardcoded `enum`/`allowed` list (`{cassandra,nginx,postgresql,docker}`): that list is wrong for the next fleet and can't touch `nomad`/`consul`/`frr`/whatever this operator actually runs. Bound it with an anchored `pattern` (blocks shell metacharacters) and lean on **operator policy/admission** to gate WHICH targets may be acted on — that's the layer that knows a given fleet's units. Reserve `enum`/`allowed` for genuinely environment-INDEPENDENT value sets (a log level, `stream: stdout|stderr`, an output format, an enum of API sections). (The over-narrow `systemctl_restart` unit enum was removed for exactly this reason — b7664f3f.)
- **Arg names can't shadow control fields.** An action arg must not be named `reason`, `runners`, `idempotency_key`, `wait`, or `action_id` — the control plane owns those top-level fields on every MCP dispatch and strips them before the rest reach the runner, so a colliding arg could never receive a value. `emisar pack validate` rejects it (runner `pkg/actionspec` `reservedArgNames`).
- **Risk is honest.** `low` = read-only (runs without approval); `medium`/`high` = mutating/destructive (policy-gated); `critical` = unrestricted (default-deny). Mislabeling a mutating action `low` bypasses the approval gate. **`low` also means no *inbound* exposure and no heavy blast radius — not just no host mutation.** An action that opens a listener, binds a port, or starts a server is **at least `medium`** even when it's transient and touches no files (opening the host to inbound connections *is* the state change); so is a probe that generates **sustained, link-saturating traffic** — real congestion on a shared path — as opposed to a cheap `ping`/`curl`. Reserve `low` for pure reads and cheap, bounded probes. (Sweep signal: any action that starts a server / `--listen` / binds a port, or floods a link. iperf3's `server` (inbound port) and `client`/`udp` (link-saturating) are `medium` for exactly these reasons, and the pack ships uniformly `medium`.)
- **Redact at the source.** `output.redact[]` (regex/literal) scrubs stdout/stderr before it leaves the host; mark secret args `sensitive: true`. An uncompilable redaction rule fails validation (fail-closed).
- **Design actions not to emit secrets — redaction is defense-in-depth, not a license to print.** `output.redact[]` (the runner's streaming `internal/redact`) is the fail-closed LAST line, but it is **pattern-bound**: a secret whose shape no rule matches leaks (the streaming-redaction secret-leak fix is exactly why). So don't emit them in the first place — no `printenv` / whole-environment dumps, no private-key blocks, no credential-bearing connection strings, no `cat` of an unfiltered config/secrets file. Pass a secret to a command via `execution.env` (mark the arg `sensitive: true`), never argv, and never echo it to stdout. An action whose JOB is to surface env/config (a debugging read) is the rare exception: scope it tightly, label its risk honestly, and say so in the description — never let "the redaction pass will mask it" stand in for the design.
- **No env hijack vectors** in `execution.env` — `LD_*` / `DYLD_*` / `BASH_ENV` are rejected.
- **Greenfield:** edit the pack in place; **bump `version` when its contract changes** — the runner re-pins the hash and operators must re-trust (below).
- **A read/enumerate action's description leads with a searchable verb.** The MCP catalog is what an LLM keyword-matches against, so open a read action's `description` with the verb of the job — **List** (a collection), **Show**/**Get** (state or one thing), **Tail**, **Dump**, **Count**, **Check** — never a bare noun ("All jobs…", "Active sessions…", "Server peers…"), which an LLM searching *"list nomad jobs"* will miss. A CLI-command opener counts when its verb is searchable (`` `kubectl get pods` ``, `` `systemctl list-units` ``, `` `ip neigh show` ``) — keep the command for operators; the leading verb is for discovery. This is description copy only: leading with a verb never changes `risk`, args, or execution, but it **is** a contract change to the catalog text, so it still bumps `version`.

## Trust model

The runner SHA-256-hashes each pack on load and advertises it; the portal verifies every dispatch against the version an operator explicitly **trusted** (Packs page). A changed pack → hash mismatch → `pack_untrusted` until re-trusted. A pack edit is an operator-visible event, never a silent change — which is why honest `version` bumps and risk labels matter.
