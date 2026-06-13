---
name: new-context
description: Scaffold a new Emisar domain context — context + authorizer + schema + query + changeset + migration + tests, wired into the permission union. Use when adding a new resource/table/domain concept to portal/apps/emisar, or starting a feature that needs its own context.
effort: high
argument-hint: "<Context> <Schema>  e.g.  Widgets Widget"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Scaffold a new context (the standard shape)

Build a complete, authorized, tested context. The module templates live in
**`portal/AGENTS.md` §1–§5** (already in context) — this skill is the *order*,
the *wiring* AGENTS.md doesn't cover, and the checklist. Copy an existing
context (`Runbooks` is the cleanest reference) rather than inventing shapes.

`<Context>` = plural domain (e.g. `Widgets`). `<Schema>` = singular (e.g. `Widget`).
All paths under `portal/apps/emisar/`.

## Before writing — wear the hats

This is a new domain concept, so spend 30 seconds on it: is this its **own**
context or a function on an existing one (`/product-manager`)? Does it touch
runner trust / untrusted input (`/security-engineer`)? Don't scaffold a context
for what is really one new function — use `/context-fn` instead.

## Files to create (in this order)

The per-layer rules + module templates are **`portal/AGENTS.md` §1–§5** — read them and copy `Runbooks` (the cleanest reference) rather than restating shapes here. Create, in order:

1. **Migration** — `priv/repo/migrations/<ts>_create_<table>.exs`: `binary_id` PK/FKs, `add :deleted_at, :utc_datetime_usec` if soft-deletable, an index per `belongs_to` + the `unique_constraint` indexes the changeset relies on (e.g. `[:account_id, :slug]`). IL-12 (money `:decimal`/`:integer`, never `:float`) and IL-11 (greenfield — edit this migration later, don't stack a corrective one unless prod already ran it) apply.
2. **Schema** — `lib/emisar/<context>/<schema>.ex` — fields + associations only (§3, IL-7).
3. **Query** — `lib/emisar/<context>/<schema>/query.ex` — `all/0` named binding, `not_deleted/1`, `by_id/2`, `by_account_id/2`, plus `cursor_fields/0`/`filters/0` as needed (§2, IL-6).
4. **Changeset** — `lib/emisar/<context>/<schema>/changeset.ex` — one function per transition, pure, private `changeset/1` for shared validations (§4, IL-8).
5. **Authorizer** — `lib/emisar/<context>/authorizer.ex` — `build(<Schema>, :view|:manage)` accessors; `list_permissions_for_role/1` over the real roles **`:owner, :admin, :operator, :viewer, :api_client, :runner`** (there is **no `:system`**) + `_ -> []`; `for_subject/2` = account-scope + `_` fallback (§5, IL-9).
6. **Context** — `lib/emisar/<context>.ex` — the public API (§1, IL-1…IL-5).
7. **Tests** — `test/emisar/<context>_test.exs` (skeleton below).

## Wiring (the part AGENTS.md doesn't show)

**Register the authorizer** in the permission union, or the new permissions
never reach any `%Subject{}`:

`lib/emisar/auth/authorizer.ex` → add `Emisar.<Context>.Authorizer` to the
`@authorizers` list (keep it alphabetical).

## Test skeleton (non-negotiable three paths — IL-3, §7)

```elixir
defmodule Emisar.<Context>Test do
  use Emisar.DataCase, async: true
  alias Emisar.<Context>

  describe "list_<plural>/2" do
    test "happy path returns the account's rows" do
      subject = owner_subject_fixture()
      {:ok, _row} = <Context>.create_<singular>(valid_attrs(), subject)
      assert {:ok, [_], _meta} = <Context>.list_<plural>(subject)
    end

    test "denial path: a role without the permission is unauthorized" do
      subject = subject_for(viewer_or_wrong_role_fixture())  # pick a role NOT in the perm list
      assert {:error, :unauthorized} = <Context>.create_<singular>(valid_attrs(), subject)
    end

    test "cross-account isolation: cannot see another account's rows" do
      a = owner_subject_fixture()
      b = owner_subject_fixture()                              # different account
      {:ok, row} = <Context>.create_<singular>(valid_attrs(), a)
      assert {:error, :not_found} = <Context>.fetch_<singular>_by_id(row.id, b)
    end
  end
end
```

Check `test/support/fixtures.ex` for the exact fixture names (`owner_subject_fixture/1`,
`subject_for/2`, role fixtures). Add a fixture there if the context needs one.

## Finish

1. The IL-20 gate, green: `cd portal && mix compile --warnings-as-errors && mix format --check-formatted && mix credo && mix test test/emisar/<context>_test.exs`. `mix credo` is the mechanical check — the `Emisar.Checks.*` AST rules (AGENTS.md → Enforcement) must report zero.
2. Run `/iron-review` on the diff.

Stop and report what you built + the test output. Don't wire the LiveView in the
same change unless asked — keep the context PR reviewable.
