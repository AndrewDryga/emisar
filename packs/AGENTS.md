# packs — how we build (the action-pack catalog)

`packs/` is the catalog of **infrastructure actions** the runner executes and the portal exposes to operators and LLMs (via MCP). Each `packs/<name>/` is a `pack.yaml` manifest plus `actions/*.yaml` — ~73 packs / ~1,100 actions today. **This is attack surface**: every action declares exactly what may run on a host, so the runner and policy can enforce a hard boundary. Read the root `../AGENTS.md` (the creed) first. The authoritative schema is the Go types in `runner/pkg/actionspec` + `runner/pkg/packspec`; this file is the conventions.

## The gate (verify before claiming done)

A pack change is done only when it validates:

```
emisar pack validate packs/<name>      # → "pack <id> OK: <n> actions" + the sha256
```

That runs the runner's load-time checks. A malformed pack breaks **both** consumers: the runner (loads + SHA-256-pins each pack at runtime) and the portal (`EmisarWeb.PacksRegistry` compile-scans every `packs/*/pack.yaml` at build time, so a bad pack **fails the portal build**). Validate every pack you touch.

## Anatomy

```
packs/<name>/
  pack.yaml        # id, name, version, description, requires/detect/setup, actions: [actions/*.yaml]
  actions/*.yaml   # one action each (kind: script also ships scripts/*.sh)
```

An **action** declares: `id` (`<namespace>.<name>`), `risk` (low|medium|high|critical), `kind` (exec|script), `args` (typed + validated), `execution` (binary + argv template, timeout, env), and `output` (parser + byte caps + redaction).

## Conventions (non-negotiable — this is a security product)

- **argv arrays, never a shell.** `execution.command.argv` is a list; args interpolate via `{{ args.x }}` as discrete words — no `sh -c`, no command strings, no word-splitting. The **`shell` pack is the one deliberate exception** (arbitrary `/bin/sh -c`, `risk: critical`, default-denied — staging break-glass only).
- **Binary paths are bare, PATH-resolved names** (`systemctl`, `psql`), never absolute. `/bin/sh` is the sole absolute exception (the shell pack).
- **Bound every LLM-supplied arg.** Strings/paths get `max_length`; prefer `enum`/`allowed`/`pattern` whitelists over blocklists; path args use `allowed_paths`/`denied_paths` (symlink-contained). An unbounded string arg is a DoS hole.
- **Arg names can't shadow control fields.** An action arg must not be named `reason`, `runners`, `idempotency_key`, `wait`, or `action_id` — the control plane owns those top-level fields on every MCP dispatch and strips them before the rest reach the runner, so a colliding arg could never receive a value. `emisar pack validate` rejects it (runner `pkg/actionspec` `reservedArgNames`).
- **Risk is honest.** `low` = read-only (runs without approval); `medium`/`high` = mutating/destructive (policy-gated); `critical` = unrestricted (default-deny). Mislabeling a mutating action `low` bypasses the approval gate.
- **Redact at the source.** `output.redact[]` (regex/literal) scrubs stdout/stderr before it leaves the host; mark secret args `sensitive: true`. An uncompilable redaction rule fails validation (fail-closed).
- **No env hijack vectors** in `execution.env` — `LD_*` / `DYLD_*` / `BASH_ENV` are rejected.
- **Greenfield:** edit the pack in place; **bump `version` when its contract changes** — the runner re-pins the hash and operators must re-trust (below).

## Trust model

The runner SHA-256-hashes each pack on load and advertises it; the portal verifies every dispatch against the version an operator explicitly **trusted** (Packs page). A changed pack → hash mismatch → `pack_untrusted` until re-trusted. A pack edit is an operator-visible event, never a silent change — which is why honest `version` bumps and risk labels matter.
