# Portal context conventions (DERIVED FROM firezone)

**Read this file before touching any context, schema, query, changeset, or LiveView in `portal/`.** The user has had to call out the same violations multiple times. Treat every rule below as a hard requirement, not a suggestion.

Reference: `../../firezone/elixir/apps/domain/lib/domain/`. When unsure, copy the pattern verbatim from a firezone domain context.

---

## 1. Context modules (`lib/emisar/<context>.ex`)

Context modules are the **only** public surface that LiveView, controllers, channels, and MCP call. They are the authorization boundary.

### 1.1 NO `Ecto.Query` in context modules

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
- `Repo.fetch_and_update(query, query_module, with: &Changeset.fun/1)` — locked read + update, atomic
- `Repo.insert(changeset)` / `Repo.update(changeset)` / `Repo.delete(struct)` — on a struct/changeset
- `Repo.transaction(fun)` / `Repo.transaction(multi)` — composing the above

**The hard line: the *queryable* must come from a Query module.** Calling `Repo.all(Schema.Query.not_deleted())` is fine. Calling `Repo.all(from s in Schema, ...)` is not — write `Schema.Query.matching(...)` and use that instead.

Canonical context-function shape:

```elixir
def list_runbooks(%Subject{} = subject, opts \\ []) do
  with :ok <- Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
    Runbook.Query.not_deleted()
    |> Runbook.Query.not_archived()
    |> Runbook.Query.ordered_by_title_version()
    |> Authorizer.for_subject(subject)
    |> Repo.list(Runbook.Query, opts)
  end
end
```

### 1.2 `%Auth.Subject{}` flows through every public read + write

- Every public function takes a `%Subject{}` argument and calls `Auth.Authorizer.ensure_has_permissions/2` before touching the DB.
- `Subject` is the **last required positional argument**. `opts \\ []` may follow as a trailing default.
  - ✅ `fetch_runbook_by_id(id, %Subject{} = subject)`
  - ✅ `list_events(%Subject{} = subject, opts \\ [])` (subject is the only required arg)
  - ✅ `update_rules(%Policy{} = policy, rules, %Subject{} = subject)`
  - ❌ `fetch_event_by_id(%Subject{} = subject, id)` — id is required and comes after subject
- Internal helpers called from sibling contexts that have already authorized may take an account_id / actor_id instead. Name them so it's obvious (`fetch_policy_for_account!/1`, `dispatch_runbook/4`), keep them private or moduledoc-marked "internal", and never expose them to LiveView/controllers/MCP.
- `Authorizer.for_subject(query, subject)` is **always** in the pipeline immediately before `Repo.fetch/list/fetch_and_update`. It is the second authorization gate (permission check + row scoping).
- `Auth.Authorizer.ensure_has_permissions/2` accepts a single permission, a list (all required), or `{:one_of, [perms]}` (any one).

### 1.3 Return shapes

- Reads: `{:ok, row} | {:error, :not_found | :unauthorized}` for single; `{:ok, [row], %Paginator.Metadata{}} | {:error, ...}` for list.
- Writes: `{:ok, struct} | {:error, %Ecto.Changeset{} | :unauthorized | :not_found}`.
- Never return a bare struct or `nil`. Tagged tuples only.

### 1.4 Internal sweepers + worker-only helpers

A small set of context functions never take a `%Subject{}`: the runner socket process's state advertisers (`Runners.apply_state/2`, `Runners.mark_connected/1`, `Runners.mark_disconnected/2`, `Runners.record_heartbeat/2`), the catalog observer (`Catalog.observe_state/2`), Oban sweepers (`Approvals.expire_overdue_requests/1`), and `Runs.create_run/1` / `Runs.dispatch_to_runner/1` / `Runs.mark_*` transition helpers. They run inside processes that have already authenticated (runner socket carries `Subject.for_runner` upstream; sweepers wrap with `Subject.system/1` if they need to call out). Mark these `@doc "Internal …"` and never expose them to LiveView/controllers/MCP.

`:preload` opts route through the per-Query `preloads/0` callback first; never call `Repo.preload/2` from a context module. The lone allowed exception is an internal mutation-side helper that's preloading an already-fetched struct for email rendering or a similar post-commit side effect.

---

## 2. Query modules (`lib/emisar/<context>/<schema>/query.ex`)

```elixir
defmodule Emisar.<Context>.<Schema>.Query do
  use Emisar, :query        # imports Ecto.Query, attaches @behaviour Emisar.Repo.Query
  alias Emisar.<Context>.<Schema>

  @impl true
  def cursor_fields, do: [{:order, :inserted_at}, {:order, :id}]

  @impl true
  def filters, do: [
    %Filter{name: :status, title: "Status", type: :list,
            values: [{"published", "Published"}, {"draft", "Draft"}],
            fun: &filter_status/2}
  ]

  def all, do: from(s in Schema, as: :schemas)
  def not_deleted(q \\ all()), do: where(q, [schemas: s], is_nil(s.deleted_at))
  def by_id(q \\ all(), id), do: where(q, [schemas: s], s.id == ^id)
  def by_account_id(q \\ all(), account_id),
    do: where(q, [schemas: s], s.account_id == ^account_id)

  defp filter_status(q, value), do: where(q, [schemas: s], s.status == ^value)
end
```

Rules:
- **`use Emisar, :query`** — never `import Ecto.Query` directly.
- Every helper is composable: takes `Ecto.Queryable.t()`, returns `Ecto.Queryable.t()`. First arg defaults to `all()` so you can either start a chain or extend one.
- Use **named bindings** (`as: :schemas`, `as: :requests`) so later helpers don't break when an upstream caller already added a `join`. Reference by `[schemas: s]`, not positionally.
- `not_deleted/1` is the standard partial-index-friendly soft-delete filter; pair it with `Repo.soft_delete/1`.
- Cross-table label helpers belong here too: `select_labels(q, ids, field)` (used by Audit).
- No `Repo.*` calls in Query modules. They build queryables; the context calls Repo.

---

## 3. Schema modules

```elixir
defmodule Emisar.<Context>.<Schema> do
  use Emisar, :schema       # imports Ecto.Schema, Ecto.Changeset, soft-delete helpers

  schema "<table>" do
    field :name, :string
    field :deleted_at, :utc_datetime_usec
    belongs_to :account, Emisar.Accounts.Account
    timestamps()
  end
end
```

- No business logic, no changeset functions in the schema module — those live in `Schema.Changeset`.
- Field declarations only. Associations only. That's it.

---

## 4. Changeset modules (`lib/emisar/<context>/<schema>/changeset.ex`)

```elixir
defmodule Emisar.<Context>.<Schema>.Changeset do
  use Emisar, :changeset
  alias Emisar.<Context>.<Schema>

  @create_fields ~w[name slug ...]a
  @required_fields ~w[name slug ...]a

  def create(account_id, attrs) do
    %Schema{account_id: account_id}
    |> cast(attrs, @create_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:account_id, :slug])
  end

  def update(%Schema{} = s, attrs), do: ...
end
```

- All `cast`/`validate_*`/`unique_constraint` lives here.
- No `Repo.*` calls. Changesets are pure.
- One function per state transition (`create`, `update`, `archive`, `publish`, …). Don't overload a single `changeset/2`.

---

## 5. Authorizer modules (`lib/emisar/<context>/authorizer.ex`)

```elixir
defmodule Emisar.<Context>.Authorizer do
  use Emisar.Auth.Authorizer  # attaches @behaviour Emisar.Auth.Authorizer

  @view_perm {:<context>, :view}
  @manage_perm {:<context>, :manage}

  def view_<context>_permission, do: @view_perm
  def manage_<context>_permission, do: @manage_perm

  @impl true
  def list_permissions_for_role(:owner),    do: [@view_perm, @manage_perm]
  def list_permissions_for_role(:admin),    do: [@view_perm, @manage_perm]
  def list_permissions_for_role(:operator), do: [@view_perm]
  def list_permissions_for_role(:viewer),   do: [@view_perm]
  def list_permissions_for_role(_),         do: []

  @impl true
  def for_subject(queryable, %Subject{actor: :system}), do: queryable
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Schema.Query.by_account_id(queryable, account_id)
end
```

- Permissions are `{:context_atom, :verb}` tuples. Expose them via per-permission accessor functions (`view_runbooks_permission/0`) so callers never reach into the attribute.
- `for_subject/2` is the **row-scoping** authorizer — it composes onto whatever query the context built. Use the Query module helpers; do not write raw `where` here.
- `:system` actors bypass row scoping (used by internal sweepers, schedulers, fixtures).
- `Emisar.Auth.Authorizer.permissions_for/1` unions every per-context Authorizer's role list — that union builds the `%Subject{}.permissions` MapSet.

---

## 6. Web layer

- LiveView mount + handle_params **assigns the Subject once** via `on_mount(:require_authenticated_user)` (already wired in `UserAuth`).
- Every context call uses `socket.assigns.current_subject` — never re-derive role inside the LV.
- `EmisarWeb.LiveTable` is stateless and URL-driven. Use `LiveTable.params_to_opts(params, Query.filters())` to translate URL params into `[filter:, page:]` for `Repo.list/3`.
- Controllers / channels follow the same pattern: build a `%Subject{}` via `Subject.for_user/4`, `Subject.for_api_key/3`, or `Subject.for_runner/3` at the auth boundary, then pass it through.

---

## 7. Tests

- `use Emisar.DataCase, async: true` — sandboxed concurrent runs. Anything that spawns DB-touching processes must inherit `$callers` or be made synchronous in test env (see `notify_approvers_async?` config flag).
- Fixtures build a real Subject when one is needed: `subject_for(user, account)` or `owner_subject_fixture/1` in `test/support/fixtures.ex`.
- Critical paths to cover: **happy path, denial path** (wrong role → `{:error, :unauthorized}`), **cross-account isolation** (account A subject cannot see account B rows → `{:error, :not_found}`).
- No `Process.sleep` for synchronization. Use `assert_receive` with an explicit timeout (default 500ms) when crossing process boundaries.

---

## 8. Greenfield, no legacy

This codebase is MVP, pre-release. **There is no legacy to preserve.** Do not:
- Layer migrations on top of bad earlier ones — edit the original migration.
- Keep deprecated functions "for compatibility" — delete them and update the callers.
- Add feature flags / shims for behavior nobody depends on yet.
- Write doc comments explaining "this is the new version" — just write the new version.

When refactoring: rip out the old shape, update every caller in the same change, run tests. No partial migrations.

---

## 9. Sanity grep before opening a PR

From `portal/apps/emisar/lib/emisar/`:

```sh
# Should return ZERO hits (excluding query.ex / repo.ex / repo/* / auth/user_token.ex):
rg 'import Ecto\.Query' --type elixir | rg -v '/query\.ex|/repo\.ex|/repo/|/user_token\.ex'

# Repo.get/get_by bypass Query modules — should return ZERO hits in lib/emisar:
rg '\bRepo\.(get|get!|get_by)\b' --type elixir

# Inline DSL outside Query/Repo — should return ZERO hits:
rg '\b(from|where|order_by|join|select|preload|limit|lock)\(' --type elixir lib/emisar | rg -v '/query\.ex|/repo\.ex|/repo/|/user_token\.ex'
```

If any of those return hits, the refactor isn't done.
