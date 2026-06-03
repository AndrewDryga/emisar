# Portal — how we build (Iron Laws + skills)

**Read this before touching any context, schema, query, changeset, LiveView, controller, or MCP handler in `portal/`.** The architecture is a strict layered-context pattern. When unsure, copy the shape verbatim from an existing context — `Runbooks` and `Policies` are the cleanest references.

The **Iron Laws** below are non-negotiable. The user has had to call out the same violations repeatedly; some are now enforced by a blocking `PostToolUse` hook (see [Enforcement](#enforcement)). Treat every law as a hard requirement, not a suggestion.

---

## How we build (prime directive)

These shape every change. When a decision isn't covered by an Iron Law, decide with these.

1. **Pragmatic. Boring solutions that work.** Reach for the dull, proven shape first — a context function, an Ecto changeset, an Oban job, a LiveView. Clever only earns its place when boring genuinely can't do the job, and you can say *why* in one sentence. No frameworks-within-the-framework.
2. **Opinionated.** This file is the opinion, and **the user extends it** — see [House opinions](#house-opinions-extend-freely). When two approaches both "work," pick the one this codebase already uses. Consistency beats personal preference.
3. **Wear every hat.** Before writing code, take the relevant lenses for two seconds — *PM*: is this even the right thing to build? *UX*: is the operator's path obvious? *Security*: what's the abuse case? *Frontend*: what's the smallest component? *Maintainer*: will this read clearly in six months? The hats are real skills — `/product-manager`, `/ux-designer`, `/security-engineer`, `/frontend`, `/seo-marketing` — invoke one when a change leans hard on its domain.
4. **Ship great products that stay easy to maintain.** Optimize for the next person reading the code, not for writing it fast now. A feature isn't done when it works once; it's done when it's verified, covered by a denial/cross-account test, and obvious.
5. **Very readable code, no bloat.** Match the surrounding style exactly. Delete more than you add when you can. No speculative abstraction, no config knobs nobody asked for, no "just in case" parameters, no commentary explaining that code is new. If a reviewer would ask "why is this here?", it shouldn't be.
6. **Verify before claiming done.** Run `mix compile --warnings-as-errors && mix format --check-formatted && mix test` and show the result. Never say "should work" — show that it does, or state plainly what you couldn't verify. (Iron Law IL-20.)
7. **Verify APIs before you call them — don't invent.** Never call a function, pass an argument/option, or use a CLI flag you're not certain exists with that signature. When in doubt, look it up *first* — run `/verify-api`: the code in this repo → the dependency source in `deps/` → `mix help` / IEx `h` → HexDocs (version-matched) → `--help`. A hallucinated function wastes far more than the 20-second check. `mix compile --warnings-as-errors` (it flags undefined/private functions and wrong arity) is the backstop, not the first line. If you still can't confirm it, say so and ask — don't guess.

### House opinions (extend freely)

Lower-stakes taste calls. Not Iron Laws, but the defaults. **The user adds to this list over time — append, don't rewrite.**

- Pipe into the data; don't nest calls. A function reads top-to-bottom as a pipeline (`Query.not_deleted() |> Authorizer.for_subject(subject) |> Repo.list(...)`).
- `with` for the happy path; let the `else` carry the error shapes. Don't pyramid `case`.
- Name by intent, not by type. `expire_overdue_requests`, not `update_requests`. Boolean-returning fns end in `?`.
- One public function = one job. If a context function has an `opts` flag that changes *what it does* (not just filtering), it's two functions.
- Small modules over big ones, but never a module per function. Follow the standard split (context / schema / query / changeset / authorizer) and stop there.
- Comments explain *why*, never *what*. The code says what. If you're tempted to narrate the what, the code isn't readable enough yet.
- Errors are values (`{:error, reason}`), not exceptions, on any path a caller can hit. `!`-raising variants only behind a proven invariant.

---

## Iron Laws (non-negotiable)

Numbered so the hook, `/iron-review`, and code review can cite them. **Architecture laws (IL-1…IL-11)** are the layered-context shape — the part the user repeats most. **Phoenix-safety laws (IL-12…IL-19)** are the generally-applicable Elixir/Phoenix guardrails. **IL-20** is process. Detail + code for each architecture law is in the [Reference](#reference--module-by-module) section it points to.

### Architecture laws (the layered-context shape)

| # | Law | Why | Detect |
|---|-----|-----|--------|
| **IL-1** | **No `Ecto.Query` / `from`/`where`/`order_by`/`join`/`select`/`preload`/`limit`/`lock` in `lib/emisar/<context>.ex` or `workers/*.ex`.** Every queryable starts at `Schema.Query.fun()`. | The Query module is the single place a table's shape is defined; inline DSL forks it. | `import Ecto.Query` outside `*/query.ex`, `*/repo*`; bare `from(`/`where(` in a context. → [§1](#1-context-modules) |
| **IL-2** | **Never `Repo.get` / `get!` / `get_by`.** | They bypass the Query module and its row-scoping entirely. | `\bRepo\.(get|get!|get_by)\b` anywhere in `lib/emisar`. → [§1](#1-context-modules) |
| **IL-3** | **`%Auth.Subject{}` is the last required positional arg of every public read and write,** and `Auth.Authorizer.ensure_has_permissions/2` runs before any DB touch. | The context is the authorization boundary. No subject = no gate. | Public context fn with no `%Subject{}` param, or DB call before the permission check. → [§1.2](#12-auth-subject-flows-through-every-public-read--write) |
| **IL-4** | **`Authorizer.for_subject(query, subject)` sits immediately before `Repo.fetch` / `list` / `fetch_and_update`.** | Second gate: it scopes rows to the subject's account. Skipping it leaks cross-account data. | `Repo.fetch`/`list` in a context with no `for_subject` directly above. → [§1.2](#12-auth-subject-flows-through-every-public-read--write) |
| **IL-5** | **Tagged tuples only.** Reads: `{:ok, row}` / `{:error, :not_found \| :unauthorized}`. Lists: `{:ok, rows, %Metadata{}}`. Writes: `{:ok, struct}` / `{:error, %Changeset{} \| :unauthorized \| :not_found}`. Never a bare struct or `nil`. | Callers pattern-match one shape. A bare struct or `nil` breaks every `with`. | Public context fn returning a struct/`nil` directly. → [§1.3](#13-return-shapes) |
| **IL-6** | **Query modules: `use Emisar, :query`, composable helpers (`(queryable) -> queryable`, first arg defaults to `all()`), named bindings (`as: :runbooks`), zero `Repo.*`.** | Composability + named bindings keep helpers safe to chain in any order. | `import Ecto.Query` instead of `use Emisar, :query`; positional bindings; `Repo.` in a query module. → [§2](#2-query-modules) |
| **IL-7** | **Schema modules are fields + associations only.** No changeset, no business logic. | A schema is a data shape. Logic in it can't be tested or reused in isolation. | `def create`/`cast`/`validate_` in a `*.ex` schema file. → [§3](#3-schema-modules) |
| **IL-8** | **Changeset modules are pure** — `use Emisar, :changeset`, no `Repo.*`, one function per state transition (`create`, `update`, `delete`, `publish`…). | Pure changesets are unit-testable and composable into `Multi`. One overloaded `changeset/2` hides transitions. | `Repo.` in a `*/changeset.ex`; a single `changeset/2` doing everything. → [§4](#4-changeset-modules) |
| **IL-9** | **Authorizers define permissions via `build(Schema, :verb)` exposed through accessor fns; `:system` actors bypass row-scoping in `for_subject/2`.** | One union of these role lists builds every `%Subject{}.permissions`. Reaching past the accessor desyncs them. | Raw permission tuples at call sites; `for_subject` without the `:system` clause. → [§5](#5-authorizer-modules) |
| **IL-10** | **`:preload` routes through the Query module's `preloads/0`; never `Repo.preload/2` in a context.** | Keeps preload shapes defined in one place per query. (Lone exception: an internal post-commit helper preloading an already-fetched struct for email.) | `Repo.preload(` inside `lib/emisar/<context>.ex`. → [§1.4](#14-internal-sweepers--worker-only-helpers) |
| **IL-11** | **Greenfield. No legacy.** Edit the original migration; delete deprecated code and update callers in the same change; no shims/flags/"this is the new version" comments. | Pre-release MVP. Every compatibility layer is permanent debt for behavior nobody depends on yet. | A corrective migration patching a same-tree migration; a `_v2`/`_old`; a flag with one value. → [§8](#8-greenfield-no-legacy) |

> **IL-11 caveat (from the user's memory):** a *standalone corrective migration* is correct — not a violation — when production has already run the original migration, or when the column was added by a later migration. Edit-the-original applies only while the migration hasn't shipped.

### Phoenix-safety laws

| # | Law | Why | Detect |
|---|-----|-----|--------|
| **IL-12** | **Never `:float` for money.** Use `:decimal` or `:integer` (cents). | Floats lose cents. Billing is real money (Paddle). | `field :amount, :float`, `add :price, :float` (money-ish names). |
| **IL-13** | **Oban jobs: idempotent, STRING-key args, store IDs not structs.** Pattern-match `%{"runner_id" => id}`. | Jobs retry. Atom-key/struct args don't round-trip through the DB. | Atom keys in `perform`; `%Runner{}` in `args`. |
| **IL-14** | **No `String.to_atom/1` on user/runner/LLM input.** Use `String.to_existing_atom/1` or a whitelist map. | Atom table never GCs → DoS. emisar takes input from runners and LLMs. | `String.to_atom(` outside tests. |
| **IL-15** | **Authorize in EVERY LiveView `handle_event` and EVERY MCP/controller action** — don't trust mount/connect. | `mount` auth doesn't cover later events; a crafted event can act beyond the rendered UI. | A `handle_event`/MCP action mutating state with no `ensure_has_permissions`/subject check. |
| **IL-16** | **Never `raw/1` (or `Phoenix.HTML.raw`) with untrusted content.** | Stored XSS — runner output, runbook text, and pack metadata are attacker-influenced. | `raw(` with a variable (not a literal/`~s`). |
| **IL-17** | **Supervise all long-lived processes.** No bare `GenServer.start_link`/`Agent.start_link` in app code — put them under a supervisor. | Unsupervised processes leak and don't restart. | `GenServer.start_link`/`Agent.start_link` outside a `child_spec`/`start_link`/supervision tree. |
| **IL-18** | **LiveView discipline:** `assign_async` (or `connected?/1` + cached branch) — no unconditional DB query in `mount` (it runs twice); **streams** for lists that can exceed ~100 rows; `connected?/1` guard before any PubSub `subscribe`; never `assign_new` for per-mount values (`current_user`, locale). | Doubles DB load, blows up socket memory, double-subscribes, or serves stale per-mount state. | `Repo`/context read in `mount` with no `connected?`/`assign_async`; collection `assign` with no `stream`; `subscribe` with no `connected?` guard. |
| **IL-19** | **Wrap third-party library APIs behind a project-owned module.** (Paddle, mailer, MCP transport…) | One seam to swap, stub in tests, and rate-limit. Vendor calls scattered across contexts can't be mocked or replaced. | A vendor module (`Paddle.`, raw HTTP client) called directly from a context/LiveView. |

### Process law

| # | Law | Why | Detect |
|---|-----|-----|--------|
| **IL-20** | **Verify before claiming done.** Run `mix compile --warnings-as-errors && mix format --check-formatted && mix test` and show output. If you can't run it, say so explicitly. | "Should work" has burned us. Generated code that doesn't pass `mix test` doesn't get committed. | A "done" claim with no command output in the transcript. |

---

## Skills

Project skills live in **`../.claude/skills/`** (repo root, so they're found from anywhere in the monorepo). Each is scoped to `portal/` Elixir. Invoke with `/<name>`.

| Skill | Use when |
|-------|----------|
| `/plan` | Designing a change that spans more than one file/context. Produces an opinionated, boring-by-default plan in the layered-context shape. |
| `/work` | Executing a plan step-by-step with compile/test gates between steps. |
| `/ship-review` | Reviewing a diff before merge through the product hats **and** the Iron Laws, in parallel. The product-level companion to `/code-review` (bugs) and `/iron-review` (laws). |
| `/new-context` | Scaffolding a whole new context (context + authorizer + schema + query + changeset + tests) in the standard shape. |
| `/context-fn` | Adding one read or write function to an existing context the canonical way. |
| `/iron-review` | Checking a diff (or the working tree) against IL-1…IL-20. The skill form of the enforcement hook. |
| `/verify-api` | In doubt whether a function/arg/option/CLI flag exists with that signature — check the repo, `deps/`, `mix help`/IEx, HexDocs, or `--help` before writing it (prime directive #7). |
| `/investigate` | Root-causing a crash, exception, stacktrace, failing test, or wrong behavior — find the cause, not a symptom. |
| `/perf` | A slow page/list/query, hot DB, or heavy socket — N+1, missing preloads/indexes, `stream` vs `assign`. |
| `/boundaries` | Auditing context coupling/layering via `mix xref` — web bypassing contexts, cross-context reach-ins, cycles. |
| `/oban` | Building or reviewing a background job / scheduled sweep in `workers/` (idempotent, string-key args — IL-13). |
| `/testing` | Writing ExUnit tests the house way — `DataCase`, `fixtures.ex`, the happy/denial/cross-account paths (§7). |
| `/document` | Writing `@moduledoc`/`@doc` — contract, required permission, and return shape, not narration. |
| `/deps-audit` | Vetting hex dependencies for supply-chain risk before adding one or before a release. |
| `/deploy` | Pre-deploy checklist + release sanity for the Fly.io control plane (does not run the deploy). |
| `/product-manager` | Deciding *what* to build / cut / sequence; writing the smallest valuable slice. |
| `/ux-designer` | Designing an operator flow or screen — clarity, trust, error states. |
| `/frontend` | Building the LiveView/HEEx/Tailwind — smallest component, `core_components` first. |
| `/security-engineer` | Anything touching auth, runner trust, MCP, policy, audit, or untrusted input. emisar *is* a security product. |
| `/seo-marketing` | Touching the marketing site (`controllers/marketing_html/`), positioning, or docs that rank. |

The hats are also **lenses** the prime directive tells you to wear inline; the skills are when a change leans hard enough on one domain to deserve its full checklist.

---

## Reference — module by module

The expanded law text. Iron Laws above are the index; this is the body.

### 1. Context modules (`lib/emisar/<context>.ex`)

Context modules are the **only** public surface that LiveView, controllers, channels, and MCP call. They are the authorization boundary.

#### 1.1 No `Ecto.Query` in context modules (IL-1, IL-2)

**Forbidden in `lib/emisar/<context>.ex` and `lib/emisar/workers/*.ex`:**
- `import Ecto.Query` (and any of `from/2`, `where/2`, `order_by/2`, `join/4`, `select/2`, `preload/2`, `limit/2`, `lock/2`, `update/2`, `subquery/1`, …)
- `Repo.get/2`, `Repo.get!/2`, `Repo.get_by/2` — these bypass the Query module entirely
- ANY raw `from(Schema, ...)` or DSL expression. Every queryable starts with `Schema.Query.fun()`.

**Public read functions** use:
- `Repo.fetch(query, query_module, opts)` — single row → `{:ok, row} | {:error, :not_found}`
- `Repo.fetch!/3` — single row, raises if missing (use only when invariants guarantee presence)
- `Repo.list(query, query_module, opts)` — paginated + filtered list → `{:ok, [row], %Metadata{}} | {:error, ...}`

**Internal helpers + workers + bulk operations** (where the query is already built via a Query module pipeline) may use:
- `Repo.peek(query)` — nil-or-struct, for cases where `nil` is a meaningful "no row" result (default-deny policy lookup, opaque prefix-keyed credential lookups)
- `Repo.all(query)` — plain list, for label batches and worker sweeps that intentionally fetch the entire set
- `Repo.one(query)` / `Repo.one!(query)` — for COUNT-1 lookups when the call site invariant guarantees uniqueness (`unique_constraint` covers it)
- `Repo.update_all(query, ...)` / `Repo.delete_all(query)` — bulk mutations on Query-built pipelines
- `Repo.aggregate(query, ...)`, `Repo.exists?(query)` — on Query-built pipelines

**Mutations + composition** in any context:
- `Repo.fetch_and_update(query, query_module, with: &Changeset.fun/1)` — locked read + update, atomic (also takes `:audit`, `:after_commit`, `:filter`, `:preload`)
- `Repo.insert(changeset)` / `Repo.update(changeset)` / `Repo.delete(struct)` — on a struct/changeset
- `Repo.transaction(fun)` / `Repo.commit_multi(multi)` — composing the above

**The hard line: the *queryable* must come from a Query module.** `Repo.all(Schema.Query.not_deleted())` is fine. `Repo.all(from s in Schema, ...)` is not — write `Schema.Query.matching(...)` and use that instead.

Canonical context-function shape:

```elixir
def list_runbooks(%Subject{} = subject, opts \\ []) do
  with :ok <- Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
    Runbook.Query.not_deleted()
    |> Runbook.Query.ordered_by_title_version()
    |> Authorizer.for_subject(subject)
    |> Repo.list(Runbook.Query, opts)
  end
end
```

#### 1.2 `%Auth.Subject{}` flows through every public read + write (IL-3, IL-4)

- Every public function takes a `%Subject{}` argument and calls `Auth.Authorizer.ensure_has_permissions/2` before touching the DB.
- `Subject` is the **last required positional argument**. `opts \\ []` may follow as a trailing default.
  - ✅ `fetch_runbook_by_id(id, %Subject{} = subject)`
  - ✅ `list_events(%Subject{} = subject, opts \\ [])` (subject is the only required arg)
  - ✅ `update_rules(%Policy{} = policy, rules, %Subject{} = subject)`
  - ❌ `fetch_event_by_id(%Subject{} = subject, id)` — id is required and comes after subject
- Internal helpers called from sibling contexts that have already authorized may take an account_id / actor_id instead. Name them so it's obvious (`fetch_policy_for_account!/1`, `dispatch_runbook/4`), keep them private or moduledoc-marked "internal", and never expose them to LiveView/controllers/MCP.
- `Authorizer.for_subject(query, subject)` is **always** in the pipeline immediately before `Repo.fetch/list/fetch_and_update`. It is the second authorization gate (permission check + row scoping).
- `Auth.Authorizer.ensure_has_permissions/2` accepts a single permission, a list (all required), or `{:one_of, [perms]}` (any one).

#### 1.3 Return shapes (IL-5)

- Reads: `{:ok, row} | {:error, :not_found | :unauthorized}` for single; `{:ok, [row], %Paginator.Metadata{}} | {:error, ...}` for list.
- Writes: `{:ok, struct} | {:error, %Ecto.Changeset{} | :unauthorized | :not_found}`.
- Never return a bare struct or `nil`. Tagged tuples only.

#### 1.4 Internal sweepers + worker-only helpers (IL-10)

A small set of context functions never take a `%Subject{}`: the runner socket process's state advertisers (`Runners.apply_state/2`, `Runners.mark_connected/1`, `Runners.mark_disconnected/2`, `Runners.record_heartbeat/2`), the catalog observer (`Catalog.observe_state/2`), Oban sweepers (`Approvals.expire_overdue_requests/1`), and `Runs.create_run/1` / `Runs.dispatch_to_runner/1` / `Runs.mark_*` transition helpers. They run inside processes that have already authenticated (runner socket carries `Subject.for_runner` upstream; sweepers wrap with `Subject.system/1` if they need to call out). Mark these `@doc "Internal …"` and never expose them to LiveView/controllers/MCP.

`:preload` opts route through the per-Query `preloads/0` callback first; never call `Repo.preload/2` from a context module. The lone allowed exception is an internal mutation-side helper that's preloading an already-fetched struct for email rendering or a similar post-commit side effect.

### 2. Query modules (`lib/emisar/<context>/<schema>/query.ex`)

```elixir
defmodule Emisar.Runbooks.Runbook.Query do
  use Emisar, :query        # imports Ecto.Query, attaches @behaviour Emisar.Repo.Query
  alias Emisar.Runbooks.Runbook

  def all, do: from(runbooks in Runbook, as: :runbooks)
  def not_deleted(q \\ all()), do: where(q, [runbooks: r], is_nil(r.deleted_at))
  def by_id(q \\ all(), id), do: where(q, [runbooks: r], r.id == ^id)
  def by_account_id(q \\ all(), account_id),
    do: where(q, [runbooks: r], r.account_id == ^account_id)
  def by_status(q \\ all(), status), do: where(q, [runbooks: r], r.status == ^status)
  def ordered_by_title_version(q),
    do: order_by(q, [runbooks: r], asc: r.title, desc: r.version)

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runbooks, :asc, :title}, {:runbooks, :desc, :version}, {:runbooks, :asc, :id}]

  # Label-batcher for Audit.resolve_references/1 — the query module owns the binding.
  def select_labels(q, ids, field) do
    q
    |> where([runbooks: r], r.id in ^ids)
    |> select([runbooks: r], {r.id, field(r, ^field)})
  end
end
```

Rules:
- **`use Emisar, :query`** — never `import Ecto.Query` directly.
- Every helper is composable: takes `Ecto.Queryable.t()`, returns `Ecto.Queryable.t()`. First arg defaults to `all()` so you can either start a chain or extend one.
- Use **named bindings** (`as: :runbooks`, `as: :requests`) so later helpers don't break when an upstream caller already added a `join`. Reference by `[runbooks: r]`, not positionally.
- `not_deleted/1` is the standard partial-index-friendly soft-delete filter; pair it with the changeset's `delete/1` (`deleted_at`).
- `cursor_fields/0` and `filters/0` are `Emisar.Repo.Query` callbacks; declare them when the context paginates or filters via `Repo.list/3`.
- Cross-table label helpers belong here too: `select_labels(q, ids, field)` (used by Audit).
- No `Repo.*` calls in Query modules. They build queryables; the context calls Repo.

### 3. Schema modules

```elixir
defmodule Emisar.Runbooks.Runbook do
  use Emisar, :schema       # UUIDv7 PK, binary_id FKs, utc_datetime_usec timestamps

  schema "runbooks" do
    field :name, :string
    field :status, :string
    field :deleted_at, :utc_datetime_usec
    belongs_to :account, Emisar.Accounts.Account
    timestamps()
  end
end
```

- No business logic, no changeset functions in the schema module — those live in `Schema.Changeset`.
- Field declarations only. Associations only. That's it.

### 4. Changeset modules (`lib/emisar/<context>/<schema>/changeset.ex`)

```elixir
defmodule Emisar.Runbooks.Runbook.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.Runbook

  @fields ~w[name slug title description status definition version]a

  def create(account_id, user_id, attrs) do
    %Runbook{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> changeset()
  end

  def update(%Runbook{} = runbook, attrs), do: runbook |> cast(attrs, @fields) |> changeset()

  def delete(%Runbook{} = runbook), do: change(runbook, deleted_at: now())

  defp changeset(cs) do
    cs
    |> validate_required([:account_id, :name, :slug, :title, :definition])
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_-]{0,79}$/)
    |> unique_constraint([:account_id, :slug, :version])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
```

- All `cast`/`validate_*`/`unique_constraint` live here.
- No `Repo.*` calls. Changesets are pure.
- One function per state transition (`create`, `update`, `delete`, `publish`, …). A private `changeset/1` carries the shared validations. Don't overload a single `changeset/2`.

### 5. Authorizer modules (`lib/emisar/<context>/authorizer.ex`)

```elixir
defmodule Emisar.Runbooks.Authorizer do
  @moduledoc "Authorization for cloud runbooks."
  use Emisar.Auth.Authorizer  # attaches @behaviour, imports build/2 + Subject

  alias Emisar.Runbooks.Runbook

  def manage_runbooks_permission, do: build(Runbook, :manage)
  def view_runbooks_permission, do: build(Runbook, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [manage_runbooks_permission(), view_runbooks_permission()]

  def list_permissions_for_role(:operator), do: [view_runbooks_permission()]
  def list_permissions_for_role(:viewer), do: [view_runbooks_permission()]
  def list_permissions_for_role(:api_client), do: [view_runbooks_permission()]
  def list_permissions_for_role(:system),
    do: [manage_runbooks_permission(), view_runbooks_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{actor: :system}), do: queryable

  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Runbook.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
```

- Permissions are built with **`build(Schema, :verb)`** and exposed via per-permission accessor functions (`view_runbooks_permission/0`) so callers never construct a permission inline.
- Roles in this codebase: `:owner`, `:admin`, `:operator`, `:viewer`, `:api_client`, `:system`. Every authorizer must clause all of them (plus a `_ -> []` catch-all).
- `for_subject/2` is the **row-scoping** authorizer — it composes onto whatever query the context built. Use the Query module helpers; do not write raw `where` here. Keep the three clauses: `:system` (bypass), account-scoped, and the `_` fallback.
- `Emisar.Auth.Authorizer.permissions_for/1` unions every per-context Authorizer's role list — that union builds the `%Subject{}.permissions` MapSet.

### 6. Web layer

- LiveView mount + handle_params **assigns the Subject once** via `on_mount(:require_authenticated_user)` (already wired in `UserAuth`).
- Every context call uses `socket.assigns.current_subject` — never re-derive role inside the LV. (IL-15: still re-check permission semantics in each `handle_event` — the context call does this for you when you pass the subject.)
- `EmisarWeb.LiveTable` is stateless and URL-driven. Use `LiveTable.params_to_opts(params, Query.filters())` to translate URL params into `[filter:, page:]` for `Repo.list/3`.
- Reach for `EmisarWeb.CoreComponents` before writing markup; reach for `stream/3` before assigning a list (IL-18).
- Controllers / channels / MCP follow the same pattern: build a `%Subject{}` via `Subject.for_user/4`, `Subject.for_api_key/3`, or `Subject.for_runner/3` at the auth boundary, then pass it through. The marketing site (`controllers/marketing_html/`) is the only unauthenticated, server-rendered surface — keep it that way for SEO (see `/seo-marketing`).

### 7. Tests

- `use Emisar.DataCase, async: true` — sandboxed concurrent runs. Anything that spawns DB-touching processes must inherit `$callers` or be made synchronous in test env (see `notify_approvers_async?` config flag).
- Fixtures build a real Subject when one is needed: `subject_for(user, account)` or `owner_subject_fixture/1` in `test/support/fixtures.ex`.
- Every context change covers three paths: **happy path**, **denial path** (wrong role → `{:error, :unauthorized}`), **cross-account isolation** (account A subject cannot see account B rows → `{:error, :not_found}`). A write isn't done without the denial test.
- No `Process.sleep` for synchronization. Use `assert_receive` with an explicit timeout (default 500ms) when crossing process boundaries.

### 8. Greenfield, no legacy (IL-11)

This codebase is MVP, pre-release. **There is no legacy to preserve.** Do not:
- Layer migrations on top of bad earlier ones — edit the original migration. *(Exception: a standalone corrective migration when prod already ran the original, or the column came from a later migration.)*
- Keep deprecated functions "for compatibility" — delete them and update the callers.
- Add feature flags / shims for behavior nobody depends on yet.
- Write doc comments explaining "this is the new version" — just write the new version.

When refactoring: rip out the old shape, update every caller in the same change, run tests. No partial migrations.

---

## Enforcement

Three layers, cheapest first:

1. **`PostToolUse` hook** (`../.claude/hooks/iron-law-verifier.sh`, wired in `../.claude/settings.json`). Runs after every `Edit`/`Write`, scans the touched `.ex`/`.exs` file under `portal/`, and **blocks with exit 2** on a violation of the regex-precise subset (**IL-1, IL-2, IL-6, IL-7, IL-8, IL-12**), feeding the specific law back for an immediate fix. The source-dependent laws (**IL-14** `String.to_atom`, **IL-16** `raw/1`) are left to `/iron-review`, which can tell a code literal / app-generated value from attacker input — the hook would false-block legitimate uses (e.g. `raw(@mfa_qr_svg)`). Read-only, ~10ms. To disable: delete the `PostToolUse` block from `../.claude/settings.json`.

2. **`/iron-review`** — the same checks plus the architecture greps, run on demand against a diff or the working tree, with fix suggestions.

3. **Sanity grep before a PR.** Run from `portal/apps/emisar/lib/emisar/`. Each is **zero hits on a clean tree** (verified against the current codebase — the globs exclude the Query/Repo machinery, and the `(^|[^.\w])` prefix stops `Path.join`/`Enum.join`/`Repo.preload`/Swoosh `from` from false-positiving):

```sh
# IL-1 — import Ecto.Query outside Query/Repo modules
rg 'import Ecto\.Query' -g '!**/query.ex' -g '!**/repo.ex' -g '!repo/**' -g '!**/user_token.ex'

# IL-2 — Repo.get/get!/get_by (bypass the Query module)
rg '\bRepo\.(get|get!|get_by)\b'

# IL-1 — inline Ecto DSL outside Query/Repo (unqualified macros only)
rg '(^|[^.\w])(from|where|order_by|join|select|preload|limit|lock|group_by|having|distinct|offset)\(' \
   -g '!**/query.ex' -g '!**/repo.ex' -g '!repo/**' -g '!**/user_token.ex' -g '!mailers/**'
```

If any return hits, the change isn't done. (The one documented exception to the third grep is `Repo.preload/2` in a post-commit/email helper — IL-10 — which is qualified and so won't match anyway.) Then run the [verify loop](#how-we-build-prime-directive) (IL-20).
