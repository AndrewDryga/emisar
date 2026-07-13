---
name: tooling-verify-api
description: Confirm a function, argument, option, type, callback, or CLI flag actually exists with the signature you think — before you call it. Use whenever you're about to use an API you're not certain of (a Repo/Ecto/Phoenix/Oban/Swoosh function, a mix task, a dependency's option, a runner/CLI flag), or any time you'd otherwise be guessing. Stops hallucinated functions before they're written.
effort: low
argument-hint: "<the function/option/flag you're unsure about>"
allowed-tools: Read, Grep, Glob, Bash, WebFetch
---

# Verify the API — don't invent it

A hallucinated function/arg/flag costs far more than the lookup. When in doubt,
**check before you write.** Stop at the first rung that gives a definitive answer;
you rarely need them all. Local sources beat the web — they're exact for the
versions this repo actually uses.

## The ladder (highest authority first)

1. **This repo — for our own code.** The source IS the spec. Grep for the
   definition, then read it + its `@spec`/`@doc`.
   ```sh
   rg -n 'def fetch_and_update' portal/apps/emisar/lib/emisar/repo.ex
   rg -n 'def (for_user|for_runner|for_api_key)' portal/apps/emisar/lib/emisar/auth/subject.ex
   ```
   For the in-house building blocks (`Repo.fetch/list/fetch_and_update`, `Subject`,
   `Authorizer.build/2`, the `use Emisar, :query|:schema|:changeset` macros), the
   module under `lib/emisar/` is the only authority — don't assume Ecto/Phoenix
   defaults apply.

2. **Dependency source — `deps/` (exact, offline, version-matched).** The pinned
   version's real code, not a guess or a newer doc:
   ```sh
   rg -n 'def fetch\b|@spec fetch' portal/deps/ecto/lib
   rg -n 'def (stream|assign_async)\b' portal/deps/phoenix_live_view/lib
   ```
   Confirm the version first if it matters: `grep -A1 '"ecto"' portal/mix.lock`.

3. **`mix help` / IEx.** Task flags and quick signatures:
   ```sh
   cd portal && mix help ecto.gen.migration       # a mix task's real args/flags
   cd portal && echo 'h Ecto.Query.from' | iex -S mix    # docs for a fn/macro
   ```
   In IEx: `h Mod.fun`, `exports Mod`, `b Behaviour` (behaviour callbacks — useful
   for the `Emisar.Repo.Query`/`Authorizer` callbacks).

4. **HexDocs (web) — last resort, match the version.** Only when local source is
   unclear. Use `WebFetch` on `https://hexdocs.pm/<pkg>/<version>/<Module>.html`
   with the version from `mix.lock` (a bare `/<pkg>/` redirects to *latest*, which
   may not be ours).

5. **CLI flags (the runner, MCP bridge, system tools).** Never guess a flag:
   ```sh
   ./bin/emisar --help          # and `./bin/emisar <subcmd> --help`
   ```
   Or read the flag definitions in `runner/` (Go `flag`/cobra) / `mcp/`. For an
   action's args/opts, the action pack schema is the source of truth, not memory.

6. **Backstop, not first line: `cd portal && mix compile --warnings-as-errors`.**
   It flags `undefined or private` functions and wrong arity. Use it to *catch* a
   slip — but checking first (rungs 1–2) is cheaper than a failed compile + retry.

## The rule

If, after a reasonable check, you still can't confirm an API exists with the
signature you need — **say so and ask, or pick a verified alternative.** Never
write a call you couldn't confirm and hope it compiles. "I assumed `X` exists" is
the failure mode this skill removes; surfacing "I couldn't find `X` — did you mean
`Y`?" is the win.
