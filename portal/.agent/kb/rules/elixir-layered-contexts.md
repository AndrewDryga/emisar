# Portal layered-context reference

Read the section for the layer you are changing. The [Portal manual](../../../AGENTS.md) owns the Iron Laws.
Paths in backticks are relative to portal/ unless explicitly marked otherwise.

**The examples below build a fictional `Emisar.Widgets` context, and that is deliberate.** A template has to be simpler than production — the real `Runbooks.Authorizer.for_subject/2` dispatches on `query_source` across two schemas, which is exactly what a new single-schema context must *not* copy — so an example named after a real module invites two contradictory readings ("this mirrors the source" vs "this is the shape") and a stream of doc-drift PRs syncing the wrong thing. The invariant here is **the examples obey the rules this file states**, not that they match any one module. For real code to read, the Portal manual points at `Runbooks` and `Policies`. **Enforced** by `./run check agent-setup`: a `defmodule` inside a fenced `elixir` block in a manual or this reference may not name a module that exists in the tree.

<a id="1-context-modules"></a>

### 1. Context modules (`lib/emisar/<context>.ex`)

Context modules are the **only** public surface that LiveView, controllers, channels, and MCP call. They are the authorization boundary.

**Arrangement.** Order a context top-to-bottom as: moduledoc → aliases/`require`/module attributes → the domain API in `# -- Section ----` blocks (reads, then mutations/actions, then any specialized sections) → a trailing **`# -- Authorization ----`** section for the `subject_can_<verb>?/1` capability predicates → internal/private helpers last. The capability predicates are a *supporting* surface (the web calls them to show/hide UI) — they belong in their own near-the-end section, **never crammed at the very top before the domain API**.

#### 1.1 No `Ecto.Query` in context modules (IL-1, IL-2)

**Forbidden in `lib/emisar/<context>.ex` and context-owned `jobs/*.ex`:**
- `import Ecto.Query` (and any of `from/2`, `where/2`, `order_by/2`, `join/4`, `select/2`, `preload/2`, `limit/2`, `lock/2`, `update/2`, `subquery/1`, …)
- `Repo.get/2`, `Repo.get!/2`, `Repo.get_by/2` — these bypass the Query module entirely
- ANY raw `from(Schema, ...)` or DSL expression. Every queryable starts with `Schema.Query.fun()`.

**Public read functions** use:
- `Repo.fetch(query, query_module, opts)` — single row → `{:ok, row} | {:error, :not_found}`
- `Repo.fetch!/3` — single row, raises if missing (use only when invariants guarantee presence)
- `Repo.list(query, query_module, opts)` — paginated + filtered list → `{:ok, [row], %Metadata{}} | {:error, ...}`

**Internal helpers + jobs + bulk operations** (where the query is already built via a Query module pipeline) may use:
- `Repo.peek(query)` — nil-or-struct, for cases where `nil` is a meaningful "no row" result (default-deny policy lookup, opaque prefix-keyed credential lookups)
- `Repo.all(query)` — plain list, for label batches and job sweeps that intentionally fetch the entire set
- `Repo.one(query)` / `Repo.one!(query)` — for COUNT-1 lookups when the call site invariant guarantees uniqueness (`unique_constraint` covers it)
- `Repo.update_all(query, ...)` / `Repo.delete_all(query)` — bulk mutations on Query-built pipelines
- `Repo.aggregate(query, ...)`, `Repo.exists?(query)` — on Query-built pipelines

**Mutations + composition** in any context:
- `Repo.fetch_and_update(query, query_module, with: &Changeset.fun/1)` — locked read + update, atomic (also takes `:audit`, `:after_commit`, `:filter`, `:preload`)
- `Repo.insert(changeset)` / `Repo.update(changeset)` / `Repo.delete(struct)` — on a struct/changeset
- `Repo.transaction(fun)` / `Repo.commit_multi(multi)` — composing the above

**The hard line: the *queryable* must come from a Query module.** `Repo.all(Schema.Query.not_deleted())` is fine. `Repo.all(from s in Schema, ...)` is not — write `Schema.Query.matching(...)` and use that instead.

**Soft-delete default:** start every read pipeline at `Schema.Query.not_deleted()`, not `all()` — tombstoned rows are excluded unless you *explicitly* need them (use `all()` then, with a why-comment). `not_deleted/1` defaults its first arg to `all()`, so it's the natural chain head (`Membership.Query.not_deleted() |> Membership.Query.by_account_id(id)`). A schema with no `deleted_at` has no `not_deleted/1` — start at `all()` there.

Canonical context-function shape:

```elixir
def list_widgets(%Subject{} = subject, opts \\ []) do
  with :ok <-
         Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_widgets_permission()) do
    Widget.Query.not_deleted()
    |> Widget.Query.ordered_by_name()
    |> Authorizer.for_subject(subject)
    |> Repo.list(Widget.Query, opts)
  end
end
```

<a id="12-auth-subject-flows-through-every-public-read--write"></a>

#### 1.2 `%Auth.Subject{}` flows through every public read + write (IL-3, IL-4)

- Every public function takes a `%Subject{}` argument and calls `Auth.Authorizer.ensure_has_permissions/2` before touching the DB.
- `Subject` is the **last required positional argument**. `opts \\ []` may follow as a trailing default.
  - ✅ `fetch_runbook_by_id(id, %Subject{} = subject)`
  - ✅ `list_events(%Subject{} = subject, opts \\ [])` (subject is the only required arg)
  - ✅ `update_rules(%Policy{} = policy, rules, %Subject{} = subject)`
  - ❌ `fetch_event_by_id(%Subject{} = subject, id)` — id is required and comes after subject
- This holds for **side-effect actions too**, not just row reads/writes — a `!`/no-row-returned helper an authed user triggers still takes the `%Subject{}` and the subject flows down the call chain.
- For a **self-service** action (a user acting on their own data — profile/email/password edits, session revocation), read the user from `subject.actor`; don't also accept it as a separate arg. `change_user_password(current, new, %Subject{actor: %User{} = user})`, not `(user, current, new, subject)`. The `%Subject{actor: %User{} = user}` match *is* the authorization (you can only act as your own subject) — no separate same-user check, and no admin/override bypass on a self-service path (that's a credential-editing footgun; admin-driven edits have their own functions).
- The `subject.actor` you read on a self-service path is a **long-lived socket snapshot** and can be stale. A self-service *mutation* must re-fetch the row before writing — `Repo.fetch_and_update/3` locks `FOR NO KEY UPDATE`, re-reads, and runs your `:with` changeset on the fresh row (scope by `by_id(subject.actor.id)` — self-service needs no `for_subject`). This is load-bearing for current-password challenges: `User.valid_password?(subject.actor, given)` checks a possibly-**stale** `hashed_password`, so a password rotated away in another session could still pass the gate; validate against the freshly-fetched row instead.
- A deliberate **cross-account self-read** (the account picker's `list_accounts_for_user/2` — every tenant the user belongs to) scopes by the subject's actor id and intentionally omits `Authorizer.for_subject/2`, which would wrongly narrow to a single account. It's the rare, documented exception to IL-4 — say so at the call site.
- Internal helpers called from sibling contexts that have already authorized may take an account_id / actor_id instead. Name them so it's obvious (`fetch_policy_for_account!/1`, `dispatch_runbook/4`), keep them private or moduledoc-marked "internal", and never expose them to LiveView/controllers/MCP.
- `Authorizer.for_subject(query, subject)` is **always** in the pipeline immediately before `Repo.fetch/list/fetch_and_update`. It is the second authorization gate (permission check + row scoping).
- **Subject + entity ⇒ two gates.** When a function takes a domain entity *and* a `%Subject{}`, run BOTH: `ensure_has_permissions/2` (does the role allow this action?) **and** an ownership gate that the entity lives in the subject's account (`Subject.ensure_in_account/3`, or `ensure_subject_owns_account/2`). Permission alone is insufficient — an admin of account A holding account B's struct must be rejected.
- **Subject + explicit account ⇒ scope by both.** When you build a query from an explicit account (or account-bearing entity) *and* a subject, filter by BOTH the explicit account (`Schema.Query.by_account_id(account_id)`) **and** `Authorizer.for_subject(subject)`. Belt-and-suspenders against accidental cross-account leaks: a wrong subject would scope to the wrong account, so the explicit account filter is the backstop (this is what `list_memberships_for_account` does).
- `Auth.Authorizer.ensure_has_permissions/2` accepts a single permission, a list (all required), or `{:one_of, [perms]}` (any one).

<a id="13-return-shapes"></a>

#### 1.3 Return shapes (IL-5)

- Reads: `{:ok, row} | {:error, :not_found | :unauthorized}` for single; `{:ok, [row], %Paginator.Metadata{}} | {:error, ...}` for list.
- Writes: `{:ok, struct} | {:error, %Ecto.Changeset{} | :unauthorized | :not_found}`.
- Never return a bare struct or `nil`. Tagged tuples only.

<a id="14-internal-sweepers--job-only-helpers"></a>

#### 1.4 Internal sweepers + job-only helpers (IL-10)

A small set of context functions never take a `%Subject{}`: the runner socket process's state advertisers (`Runners.connect_runner/3`, `Runners.disconnect_runner/5`, `Runners.enforce_runner_version/2`, `Runners.record_heartbeat/5`), the catalog observer (`Catalog.observe_state/2`), recurrent job sweepers (`Approvals.expire_overdue_requests/1`), `Runs.create_run/1` / `Runs.dispatch_to_runner/1` / `Runs.mark_*` transition helpers, and the **inbound SCIM lifecycle** (`SSO.authenticate_scim_token/1` + the `SSO.scim_*` family — `scim_provision_user`, `scim_update_user`, `scim_fetch_user`, `scim_list_users`, `scim_upsert_group`, `scim_patch_group_members` — and `SSO.recompute_role_for_identity/2`). They run inside processes that have already authenticated (the runner socket authenticates the runner token before any of them run; recurrent jobs operate on explicit account ids through named internal helpers; the SCIM web boundary resolves the per-provider `ems-` bearer first, so the returned `%IdentityProvider{}`'s provider-scope IS the authz, and every read scopes by `provider.id`/`provider.account_id`). Mark these `@doc "Internal …"` and never expose them to LiveView/controllers/MCP.

`:preload` opts route through the per-Query `preloads/0` callback first; never call `Repo.preload/2` in a Subject-gated context read. An internal, no-Subject, already-authorized path holding a struct may preload its parent association directly: post-commit email helpers and the runner-register billing check are examples. This exception does not authorize bypassing a public context boundary.

<a id="2-query-modules"></a>

### 2. Query modules (`lib/emisar/<context>/<schema>/query.ex`)

```elixir
defmodule Emisar.Widgets.Widget.Query do
  # imports Ecto.Query, attaches @behaviour Emisar.Repo.Query
  use Emisar, :query
  alias Emisar.Widgets.Widget

  def all, do: from(widgets in Widget, as: :widgets)

  # The Authorizer's fail-closed fallback returns this; every query module whose
  # schema has an Authorizer defines it. `use Emisar, :query` does NOT supply it.
  def none(queryable), do: where(queryable, false)

  def not_deleted(queryable \\ all()), do: where(queryable, [widgets: w], is_nil(w.deleted_at))
  def by_id(queryable \\ all(), id), do: where(queryable, [widgets: w], w.id == ^id)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [widgets: w], w.account_id == ^account_id)

  def by_status(queryable \\ all(), status),
    do: where(queryable, [widgets: w], w.status == ^status)

  def ordered_by_name(queryable), do: order_by(queryable, [widgets: w], asc: w.name)

  @impl Emisar.Repo.Query
  def cursor_fields, do: [{:widgets, :asc, :name}, {:widgets, :asc, :id}]

  # Label-batcher for Audit.resolve_references/2 — the query module owns the binding.
  def select_labels(queryable, ids, field) do
    queryable
    |> where([widgets: w], w.id in ^ids)
    |> select([widgets: w], {w.id, field(w, ^field)})
  end
end
```

Rules:
- **`use Emisar, :query`** — never `import Ecto.Query` directly.
- Every helper is composable: takes `Ecto.Queryable.t()`, returns `Ecto.Queryable.t()`. First arg defaults to `all()` so you can either start a chain or extend one. Name that first argument **`queryable`**, not `q`.
- Use **named bindings** (`as: :widgets`, `as: :requests`) so later helpers don't break when an upstream caller already added a `join`. Reference by `[widgets: w]`, not positionally.
- `not_deleted/1` is the standard partial-index-friendly soft-delete filter; pair it with the changeset's `delete/1` (`deleted_at`).
- `none/1` is the fail-closed target the Authorizer's `_` fallback returns (§5) — a binding-free `where(queryable, false)`. **`use Emisar, :query` does NOT supply it** (it injects only `import Ecto.Query` + the `@behaviour`), so every query module whose schema has an Authorizer declares its own. Miss it and the fallback is an undefined function on the one path that exists to stop a leak.
- `cursor_fields/0` and `filters/0` are `Emisar.Repo.Query` callbacks; declare them when the context paginates or filters via `Repo.list/3`.
- `preloads/0` entries use the `{scope_query, nested_preloads}` tuple — `account: {Account.Query.not_deleted(), Account.Query.preloads()}` — so the associated schema's own `preloads/0` cascades and deep nesting composes. Any query module reachable as a preload declares its own `preloads/0` (even `do: []`) so callers can compose that tuple.
- For an association a list pipeline always loads, expose **two** helpers, not one: `with_joined_X/1` (idempotent `with_named_binding/3` + join scoped to the assoc's `not_deleted/0`) and `with_preloaded_X/1` (`queryable |> with_joined_X() |> preload(...)`). Keeping the join separate lets it be reused to filter on the joined columns; putting `preload` *outside* the idempotency block means it still applies when the join already exists. **Once the helpers exist, context pipelines call them** — `|> Membership.Query.with_preloaded_account()` in the chain, not a `preload: [:account]` opt on `Repo.fetch/list`. The join-based helper also subsumes a separate active-assoc filter (it inner-joins `not_deleted/0`), so a bespoke `for_active_X` filter next to it is dead weight.
- **Join direction follows the association's cardinality/optionality:** `:inner` for a required belongs_to (a row whose assoc is missing or deleted shouldn't appear — e.g. a membership's account/user); `:left` for a has_many or optional assoc (keep the parent even with zero children — e.g. an account preloading its memberships still shows when it has none). **Either way the join is scoped to `not_deleted/0`** — soft-deleted records never leak into the preload regardless of direction.
- Cross-table label helpers belong here too: `select_labels(queryable, ids, field)` (used by Audit).
- A helper whose name implies a position (`latest`, `oldest`, `top_n`) owns both its `order_by` and its `limit` — callers shouldn't have to remember to order first for the limit to mean anything.
- Name order helpers after the columns they sort by — `ordered_by_type_and_value`, `ordered_by_group_name`, not a bare `ordered`. The ordering is then visible at the call site and flags where a matching DB index (incl. its direction) is needed.
- Match a helper's name to its argument: a name ending in `_id` (`by_user_id`, `by_membership_user_id`) takes an **id**; without that suffix it takes the **struct** (`by_user(user)`). For a value reached through a nested association, name by the **path** to it — `by_membership_user_id` (accounts → `membership.user_id`), not an opaque `with_active_member`. Reserve the `with_*` prefix for join/preload helpers (`with_joined_*`, `with_preloaded_*`), never a plain filter. (Edge cases exist — a helper bundling an extra constraint, like excluding suspended members; document the extra filter in the `@doc`.)
- No `Repo.*` calls in Query modules. They build queryables; the context calls Repo.

<a id="3-schema-modules"></a>

### 3. Schema modules

```elixir
defmodule Emisar.Widgets.Widget do
  # UUIDv7 PK, binary_id FKs, utc_datetime_usec timestamps
  use Emisar, :schema

  schema "widgets" do
    field :name, :string
    field :slug, :string
    field :status, Ecto.Enum, values: [:draft, :active, :retired]

    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :created_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end
```

- No business logic, no changeset functions in the schema module — those live in `Schema.Changeset`.
- Field declarations only. Associations only. That's it.
- Separate logical field groups with a blank line (identity / credentials / feature-X / flags) so a long schema scans at a glance. Keep associations and `timestamps()` in their own trailing groups.
- Use `Ecto.Enum` (`field :kind, Ecto.Enum, values: [:a, :b]`) for any fixed string-set field — never `:string` + a `@valid_types` list + a `validate_inclusion` in the changeset. The enum casts to atoms, validates inclusion on cast for free, and keeps the DB value as the string form. Match on the atoms (`:group`), not strings. **Five `:string` exceptions stay (no `Ecto.Enum`), each with a why-comment at the field — all on the `subscriptions` Paddle mirror, whose value space is vendor-owned:** `Subscription.status` (Paddle can mint statuses we've never seen, and they must persist rather than 500 the webhook), `Subscription.plan` (a renamed/legacy/sales-led plan name must still load and degrade gracefully), `Subscription.billing_interval` (Paddle may add a cadence and billing summary must still load), `Subscription.collection_mode` (an unknown collection policy is an unresolved lifecycle, not a schema crash), and `Subscription.scheduled_change_action` (known cancel/pause values have owned semantics while an unknown action fails closed). Wire boundaries don't block the enum: inbound strings cast fine (changeset `cast`, query `^param`s, `update_all` sets), Jason encodes the atoms back to the same strings, and shared components normalize via `to_string` (`status_badge`, `risk_pill`).
- Natural keys compared case-insensitively — emails, slugs — are **`:citext`** columns at the DB level (the extension is enabled in the first migration). The citext column + its unique index IS the guarantee — **no app-side `String.downcase` anywhere**: not on lookup params (`u.email == ^email` already compares case-insensitively), not before writes (store the typed casing; registration does, so every other write path must match). `String.trim` at the entry point stays — citext doesn't strip whitespace. (Downcasing a *recovery code* before hashing is a different thing — that's case-insensitive code entry, not a citext column.)
- **Soft-deletes never leak through preloads.** EVERY association whose target schema has `deleted_at` carries `where: [deleted_at: nil]` — `belongs_to` as much as `has_many` (`belongs_to :account, Account, where: [deleted_at: nil]`; `has_many :memberships, Membership, where: [deleted_at: nil]`). When adding an assoc, check the target schema for `deleted_at` and add the where in the same edit. `through:` associations can't take `:where` — they filter via the associations they traverse. Mirror it in the Query module's `preloads/0`: declare the assoc as the `Schema.Query.not_deleted()` query, not a bare `[]`, so the filter is explicit at the preload site too (`Emisar.Repo.Preloader` hands both the bare-preload and query-override paths to `Ecto.Repo.preload`, which honors the association `:where`).

<a id="4-changeset-modules"></a>

### 4. Changeset modules (`lib/emisar/<context>/<schema>/changeset.ex`)

```elixir
defmodule Emisar.Widgets.Widget.Changeset do
  use Emisar, :changeset
  alias Emisar.Widgets.Widget

  @fields ~w[name slug status]a

  def create(account_id, user_id, attrs) do
    %Widget{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> changeset()
  end

  def update(%Widget{} = widget, attrs), do: widget |> cast(attrs, @fields) |> changeset()

  def delete(%Widget{} = widget), do: change(widget, deleted_at: DateTime.utc_now())

  defp changeset(changeset) do
    changeset
    |> validate_required([:account_id, :name, :slug])
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_-]{0,79}$/)
    |> unique_constraint([:account_id, :slug])
  end
end
```

- All `cast`/`validate_*`/`unique_constraint` live here.
- No `Repo.*` calls. Changesets are pure.
- One function per state transition (`create`, `update`, `delete`, `publish`, …). A private `changeset/1` carries the shared validations. Don't overload a single `changeset/2`.
- Cast field lists live in module attributes (`@fields`, or `@create_fields`/`@update_fields` when they diverge), never inline in the `cast/3` call. Inline a list only when a module has so many divergent field sets that named attrs would be noise.
- **No `DateTime.truncate` timestamp helpers.** Every datetime column is `:utc_datetime_usec` and `DateTime.utc_now/0` is already microsecond-precision, so `DateTime.truncate(:microsecond)` is a no-op — write `deleted_at: DateTime.utc_now()` directly; no `defp now` wrapper. (If you ever need a coarser column, that's the exception that gets a why-comment.)

<a id="5-authorizer-modules"></a>

### 5. Authorizer modules (`lib/emisar/<context>/authorizer.ex`)

```elixir
defmodule Emisar.Widgets.Authorizer do
  @moduledoc "Authorization for widgets."
  # attaches @behaviour, imports build/2 + Subject
  use Emisar.Auth.Authorizer

  alias Emisar.Widgets.Widget

  def manage_widgets_permission, do: build(Widget, :manage)
  def view_widgets_permission, do: build(Widget, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [manage_widgets_permission(), view_widgets_permission()]

  def list_permissions_for_role(:operator), do: [view_widgets_permission()]
  def list_permissions_for_role(:viewer), do: [view_widgets_permission()]
  def list_permissions_for_role(:api_client), do: [view_widgets_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Widget.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: Widget.Query.none(queryable)
end
```

- Permissions are built with **`build(Schema, :verb)`** and exposed via per-permission accessor functions (`view_widgets_permission/0`) so callers never construct a permission inline.
- Roles in this codebase: `:owner`, `:admin`, `:operator`, `:viewer`, `:api_client`, `:runner` — each authorizer clauses the ones it grants, with a `_ -> []` catch-all for the rest.
- The five **membership** roles (`:owner`/`:admin`/`:billing_manager`/`:operator`/`:viewer`) are defined once in `Emisar.Auth.Role` — the single source for the `Membership` `Ecto.Enum` and the team UI's role list. Roles are capability sets, not a hierarchy; permission checks decide what a member can do. Never re-list roles in a schema, changeset, or LiveView.
- **Authorize by permission, not role name.** A context must never branch on `subject.role` to gate an action (`subject.role != :owner` is a smell) — add a permission (e.g. `manage_owners_permission`, held by owners only) and check `Auth.Authorizer.has_permission?/2`. Comparing a *data* role value (`target.role == :owner`) is fine; gating the *actor's* capability by role name is not.
- `for_subject/2` is the **row-scoping** authorizer — it composes onto whatever query the context built. Use the Query module helpers; do not write raw `where` here. Keep the account-scoped clause (plus any actor-specific clause, e.g. the runner-only scoping in `Runs.Authorizer`), and the `_` fallback **fails closed**: it returns the schema's `Query.none(queryable)` (a binding-free `where(queryable, false)` helper), never the unscoped queryable. The fallback is unreachable for authenticated callers — every `Subject` constructor requires an account — so this is pure defense-in-depth: a future path that skips the permission gate leaks nothing. **Credo-enforced** (`Emisar.Checks.AuthorizerFallbackFailClosed`).
- **Background/system-side reads take an explicit `account_id`, not a forged subject.** There is no `:system` god-subject. A read with no user in scope (a recurrent job, the approval fan-out, a dispatch-payload enrichment) is a named internal function that scopes via `Schema.Query.by_account_id/2` directly — e.g. `Accounts.list_account_memberships/2` and `Catalog.fetch_action_for_account/3`. This is the IL-1.4 internal-helper pattern; it's why removing `:system` couldn't reintroduce the cross-account fan-out leak.
- `Emisar.Auth.Authorizer.permissions_for/1` unions every per-context Authorizer's role list — that union builds the `%Subject{}.permissions` MapSet.

### 6. Web layer

- LiveView mount + handle_params **assigns the Subject once** via `on_mount(:require_authenticated_user)` (already wired in `UserAuth`).
- Every context call uses `socket.assigns.current_subject` — never re-derive role inside the LV. (IL-15: still re-check permission semantics in each `handle_event` — the context call does this for you when you pass the subject.)
- **"Can this subject do X?" is a domain question.** Each context exposes `subject_can_<verb>?(%Subject{})` predicates (e.g. `Billing.subject_can_manage_billing?/1`, `Runs.subject_can_dispatch_run?/1`) — one-liners over `Auth.Authorizer.has_permission?/2`. The web calls them directly: templates do `:if={Runs.subject_can_dispatch_run?(@current_subject)}`, handlers wrap them in `EmisarWeb.Permissions.gated(socket, <predicate>, fun)` (a thin flash-on-denial helper, no authz of its own). The web never maps a UI action to a permission and never branches on `current_role` / `current_membership.role` for authorization (`role == :owner ->` is the smell); rendering the role *label* is fine.
- **The web is an adapter — it calls the top-level context and nothing below it.** Stated in full in the [Portal rule index](README.md); behaviour the web needs becomes a facade function on the owning context, named for what the caller wants (`Accounts.create_account_with_owner_from_name/2`). The legal carriers, the Credo checks, and `Emisar.WebBoundaryChecksTest` are in `.agent/kb/rules/elixir-web-is-an-adapter.md`.
- **Forms are a web concern.** A context exposes plain `change_*(struct, attrs)` changeset builders (the Phoenix convention — `change_user`, `change_account`, `change_password`); it never has a `*_form` function or a changeset doc'd "for the LiveView form." The form *orchestration* — `to_form`, `phx-change`, `Map.put(:action, :validate)`, rendering inline field errors, and read-only inspection (`get_field`, `traverse_errors`) — lives in the LiveView, built on top of those `change_*` builders.
- **Typed confirmation inputs submit on Enter; plain confirmation modals do not.** A `<.confirm_dialog>` with a non-nil `confirm_token` is a real form whose disabled/enabled Confirm button is its submitter, so Enter after an exact token match runs the same `on_confirm` command as a click. A plain dialog has no confirmation input and stays click-only — never give it a form-level Enter binding. Sweep: typed-confirm forms whose `phx-submit` only re-stores the token, submit buttons not associated with their confirmation form, and plain dialogs that bind submit. Enforced by `confirm_dialog_test.exs`.
- **A form's own submission error is shown INLINE at the form, never via a redirect + top-of-page flash.** An error the operator can fix by editing what they just typed — a wrong code, a rejected field — renders at the input (a field-level `<.error>`, the `code_input` `error` attr, or a form-level error region beside the inputs), so the *what-went-wrong* sits where the *what-to-fix* is. If the value is only knowable after a server check, verify it in a LiveView `handle_event` and `assign` the error — do NOT round-trip a controller that `put_flash(:error, …) |> redirect(…)`, which throws the error to the top of a reloaded page, far from the field, where a flash auto-dismiss then eats it. `put_flash(:error, …) |> redirect(…)` is right only for what ISN'T a fixable form error and has no input to return to — an auth denial, a dead / rate-limited link, a cross-account 404. The smell (what the magic-link code path did before it moved into `MagicLinkLive`): type into a field → submit → the error appears far away and vanishes on the reload. Worked example: `.agent/kb/rules/elixir-inline-form-errors.md`.
- **Shared interactive components work in both JavaScript bundles.** A component rendered by both LiveView and controller pages cannot put its only behavior in an `app.js` hook: keep the LiveView-owned state path in `app.js`, wire the equivalent local behavior through `marketing.js`, and verify the controller-rendered path in a browser. Sweep shared layout components for `phx-hook`/`phx-click` behavior whose static-page bundle has no handler.
- `EmisarWeb.LiveTable` is stateless and URL-driven. Use `LiveTable.params_to_opts(params, Runs.run_filters())`-style calls — the owning context exposes its Query module's `filters/0` as `<schema>_filters/0`; the web never calls a Query module — to translate URL params into `[filter:, page:]` for `Repo.list/3`.
- Reach for `EmisarWeb.CoreComponents` before writing markup; reach for `stream/3` before assigning a list (IL-18). **One shared component per UI shape — never hand-roll a card / chip / banner / button / empty-state / page-width, and pick the right member of the pair (`stat` tile vs `meta_strip`).** Worked map: `.agent/kb/rules/design-ui-shared-components.md`.
- **A label on a solid accent fill is near-black, never white.** Our accents are LIGHT surfaces: `<.button>` ships `bg-brand-500 text-zinc-950` and its amber twin `text-amber-950`; white on `brand-500` is ~1.9:1 and unreadable. Hand-rolling the face is what lets this drift, so the fix is `<.button>` (`class="w-full"` for a narrow card), not a corrected copy — the consent cards had forked all eight of their buttons. **Enforced** by `EmisarWeb.TemplateHygieneTest`. Sweep: a solid `bg-{brand,amber,emerald}-[456]00` in the same class string as `text-white`, and any `<button>`/`<.link>` wearing a hand-written filled or bordered button face.
- **Load-bearing "why locked/limited" copy is reachable on touch AND keyboard, never hover-only.** The reason a control is disabled/gated goes through the shared `<.tooltip>` (a focusable trigger + `aria-describedby` to a `role="tooltip"` bubble that reveals on `focus-within`, not just `group-hover`) or an always-visible inline note — never a raw `title=` or a CSS hover reveal on a non-focusable element, where a touch/keyboard/screen-reader operator can never discover it (WCAG 1.4.13). `<.tooltip>` is a FULL 1.4.13 pass: the revealed bubble is pointer-interactive with a `before` hover-bridge across the gap (so the pointer can move onto it — "hoverable"), and the `Tooltip` JS hook dismisses it on `Escape` while keeping focus on the trigger ("dismissable"); don't hand-roll a hover-only bubble that reintroduces either gap. When the same tip renders per row (a per-membership/per-tier lock), pass `<.tooltip>` an explicit unique `id` so the trigger + bubble ids stay unique.
- **The visual language — tokens, type, brand/logo, components, the marketing↔console register split, and the plan to bring the console into line with the redesigned marketing site — lives in `.agent/kb/rules/design-system.md` ("The Gate"). Read it before any visual change to `emisar_web` (marketing or console).** The one accent is the emerald `brand` scale; semantic pass/pending/deny = brand/amber/rose; calm console, expressive marketing.
- Controllers / channels / MCP follow the same pattern: build a `%Subject{}` via `Subject.for_user/4` or `Subject.for_api_key/3` at the auth boundary, then pass it through. The marketing site (`controllers/marketing_html/`) is the only unauthenticated, server-rendered surface — keep it that way for SEO (see `/content-seo`).

### 7. Tests

- `use Emisar.DataCase, async: true` — sandboxed concurrent runs. Anything that spawns DB-touching processes must inherit `$callers` or be made synchronous in test env (see `notify_approvers_async?` config flag).
- Fixtures build a real Subject when one is needed: `subject_for(user, account)` or `owner_subject_fixture/1` in `test/support/fixtures.ex`.
- **Fixtures and tests never depend on a context function that exists only for them.** Build rows the fixture way (`Schema.Changeset.fun() |> Repo.insert`) or via the real Subject-gated API; put test-only inspectors in `test/support`, not the production context. A `defp` used by an internal flow stays private — don't promote it to public just so a test can reach it. Fixture code leaking into a context's public namespace is a smell.
- Regression tests drive the domain API that failed, not database catalog introspection. For a migration/backstop, prove the relevant context operation succeeds or rejects correctly (`Runs.dispatch_run/2`, `Approvals.create_request/3`, etc.); only inspect schema catalogs when no meaningful domain path exists.
- Every context change covers three paths: **happy path**, **denial path** (wrong role → `{:error, :unauthorized}`), **cross-account isolation** (account A subject cannot see account B rows → `{:error, :not_found}`). A write isn't done without the denial test.
- No `Process.sleep` for synchronization. Use `assert_receive` with an explicit timeout (default 500ms) when crossing process boundaries.
- Capture expected warning/error logs at the ExUnit app boundary (`ExUnit.start(capture_log: true)`), not by sprinkling `with_log` through ordinary tests just to keep output quiet. Use `capture_log/with_log` locally only when the log text itself is the assertion under test.
- When a test action emits a PubSub event, subscribe before the action and `assert_receive` the exact broadcast before the test exits. For LiveView tests where the open view also receives that broadcast, follow the assertion with a render/flush of the view so its queued `handle_info` runs while the sandbox owner is still alive. This proves the event contract and prevents late async DB work from surfacing as teardown noise.
- Test output must stay boring. `./run gate portal` fails if ExUnit output contains compiler warnings, Logger warning/error lines, Postgrex/DBConnection disconnect noise, or other warning/error markers. Treat a failure as a real defect or missing synchronization point; do not lower log levels, broaden capture, or add an allowlist unless the log text is itself the behavior under test.

**Test-writing taste — the house style for an ExUnit body:**

- **Rig setup *state* through a named fixture — never inline `Ecto.Changeset`/`Repo` in a test body, and never a real Subject-gated context fn used *only to arrange*.** A soft-delete / suspension / any setup transition (not the thing under test) gets a fixture verb writing via the schema's own `Changeset` — `Fixtures.Accounts.mark_account_as_deleted/1`, `Fixtures.Memberships.suspend_membership/1`. A hand-built `%Subject{}` goes through `Fixtures.Subjects.build_subject/1` (bare/partial caller) or `membership_subject/1` (backed by a real membership), never a raw `%Emisar.Auth.Subject{actor: user}`. Calling the real `Accounts.suspend_membership/3` *just to arrange* drags in an `owner_subject` and couples the test to an unrelated function's authz — right only when that function IS under test. Sweep: `Ecto.Changeset.change(` / `Repo.update`/`Repo.insert` and raw `%Subject{` in `test/**/*_test.exs`.
- **Build attrs through a `Fixtures.<Domain>.<schema>_attrs(overrides)` factory** — valid defaults + per-key override, not a literal map re-typed per test. `account_attrs()` for a success case, `account_attrs(slug: "x")` for a validation test (override *only* the field under test — the salient invalid key is explicit, the boilerplate DRY). The row fixture builds on it (`create_account/1` merges over `account_attrs/1`, defaults in one place). Add the factory the moment a second test re-types the default map.
- **Create each entity explicitly; never harvest one as a throwaway side effect of a compound fixture.** `{_owner, account, _subject} = Fixtures.Subjects.owner_subject()` just to get `account` → `account = Fixtures.Accounts.create_account()` (+ `subject_for(Fixtures.Users.create_user(), account)` when a caller is needed; role defaults `:owner`). A `_`-prefixed element of a destructured fixture tuple is the tell the helper builds more than the test wants. (For a caller that must be a *persisted* member — last-owner / role-count guards — create the membership explicitly: `create_membership(role: "owner")` + `membership_subject/1`.)
- **Bias EXPLICIT over DRY (DAMP).** A test reads top-to-bottom on its own; never push the *salient* state (which account is suspended, who owns what) into a `setup` block, shared helper, or pre-wired-graph fixture. This **bounds the shared-`setup` rule above**: `setup` is only for scaffolding identical across the describe AND incidental to what each test proves; the moment the entities/relationships ARE the point, inline per test. `user = Fixtures.Users.create_user()` repeated across five tests is fine; an abstraction that hides what a test exercises is not.
- **No historic/narrative comments in a test body — the `describe "fun/arity"` + test name carry the intent.** Delete comments explaining *why a function exists*, *where it's used*, or backstory; keep one **only** for a non-obvious *invariant the assertion turns on* ("both `:not_found` — a tombstoned account is indistinguishable from one that never existed"). The why-not-what rule, stricter in tests.
- **Assert a fully-known result with `==`, not a pattern-match `=`.** `assert fetch(id) == {:error, :not_found}` states the value and gives a left/right diff; reserve `assert pat = expr` for binding or a partial-struct match (`{:ok, %Account{id: id}} = …`). Know the id up front → bind + pin: `account_id = account.id; assert {:ok, %Account{id: ^account_id}} = …`, not extract-then-`assert id == …`.
- **Assert a changeset error by its CONTENT via `errors_on/1`, not by matching `%Ecto.Changeset{}`.** Bind the changeset and check the field's message — `assert {:error, changeset} = …` then `assert "must …" in errors_on(changeset).slug`. Verify WHICH field actually errors (`name: "x"` is valid under `validate_length min: 1` — the real error is on `slug`; `errors_on(changeset).name` would `KeyError`). This is also the **split-assert**: a wrapped `assert {:error, %Ecto.Changeset{}} =⏎  call(…)` → `assert {:error, changeset} = call(…)` (shorter pattern fits one line) + an `errors_on` line — same line count, two flat assertions; generalize to any long `assert pat = expr` that wraps AND binds.
- **Bind a long inline map/attrs argument** above the call so the call fits one line, instead of letting the formatter break the call across lines — the test analog of the production "bind a transformed argument, don't nest it" rule.
- **Lean on the `async` sandbox — read the whole table.** Each test sees only its own rows, so `assert x = Repo.one(Schema)` reads the row AND asserts exactly one (`Repo.one` raises on >1); `refute Repo.one(Schema)` proves a transaction rolled back. Prefer over building a `%Subject{}` + a list read just to prove presence/absence. (Bare `Repo.one`/`Repo.exists?` on a schema is a test inspector — fine in `test/`, never the IL-2 `Repo.get` ban, which is `lib/`.)
- **Field-validation boundary tests live in the `<Schema>.Changeset` test, not a context integration test that inserts rows.** Test `Account.Changeset.create/1` directly — `valid?` + `errors_on` at the boundary (1, 80) and just past it (0, 81) — in `test/emisar/accounts/account/changeset_test.exs`; the context describe keeps the happy path + ONE rollback case (an invalid changeset aborts the whole transaction).
- **Assert on a changeset by its struct fields + a whole-map `==` on `.changes`; assert ERRORS by message via `errors_on/1`.** For a `change_*` form builder: `assert changeset.valid?` and `assert changeset.changes == %{name: "Renamed"}` — direct `.valid?`/`.changes` access, NOT `Ecto.Changeset.get_change(cs, :field) == val` or a `%Ecto.Changeset{valid?: true} = cs` match. The whole-`changes`-map `==` proves ONLY the expected keys changed (a single-field `get_change` silently misses an unexpected extra change). For errors, `assert "can't be blank" in errors_on(changeset).name` — the **message**, never `changeset.errors[:name]`, which only checks a raw `{msg, opts}` tuple is present (presence, not content). When a test needs the APPLIED struct (not the change set), `Ecto.Changeset.apply_action(cs, :update)` returns `{:ok, struct} | {:error, cs}` — use that, still no per-field helper.
- **Don't re-read the DB to prove a pure builder didn't write.** A `change_*` builder (the Phoenix changeset convention) is side-effect-free by construction; `assert Repo.reload!(account) == account` after it — plus a comment narrating "the row is untouched" — is defensive noise. The test name + the changeset assertions are the contract.

<a id="8-greenfield-no-legacy"></a>

### 8. Greenfield, no legacy (IL-11)

This codebase is MVP, pre-release — for **code** there is no legacy to preserve. Do not:
- Keep deprecated functions "for compatibility" — delete them and update the callers.
- Add feature flags / shims for behavior nobody depends on yet.
- Write doc comments explaining "this is the new version" — just write the new version.

When refactoring: rip out the old shape, update every caller in the same change, run tests.

The production release runs `/app/bin/migrate` before each instance boots, and each migration applies once. Never edit or delete a migration that production ran; add a forward migration. If production did not run it, fix or delete the original instead of preserving a mistake with repair migrations.

**A concurrent index must recover interrupted DDL.** `IF NOT EXISTS` checks only the name: it can skip an INVALID index and incorrectly finish the migration. `Emisar.Release.migrate/0` holds one Postgres advisory lock across the whole run and uses finite guarded bodies for the historical nontransactional migrations. Recovery keeps a matching valid index, creates a missing one, or uses `REINDEX INDEX CONCURRENTLY` for a matching invalid index; it rejects unexpected definitions and dependencies. Unique replacements become valid before their predecessors are dropped. New concurrent-index migrations use the same exact-definition checks and cover every successful operation prefix, including an all-DDL-complete body with no version row. Never edit an applied or production-unknown migration to add recovery; Ecto remains the owner of version recording.

Git history is not the boundary because `main` publishes plans and a founder applies them later. Establish the production fact before changing an existing migration. Keep the migration proportional to the actual data: use batching, concurrent indexes, or expand/contract only when current table size or a real rolling-version overlap requires them. See `.agent/kb/rules/elixir-migrations-frozen.md`.

A table RENAME must sweep five surfaces in the same change (constraint/index renames, the schema string, explicit `name:` options, `for_subject` `query_source` atom clauses, raw-SQL strings) or IL-4 row scoping silently breaks: `.agent/kb/rules/elixir-table-rename-sweep.md`.

---

## Enforcement

Two layers — mechanical rules run by machines, judgment rules by review:

1. **Credo is the single mechanical source of truth *for Elixir AST*.** The
   Iron-Law and house-rule checks are custom AST checks in `credo/checks/`
   (`Emisar.Checks.*`), wired into `.credo.exs` alongside the stock checks
   (including `UnsafeToAtom` for IL-14 and `StrictModuleLayout` for the
   directive order).

   **Credo cannot parse `.heex`** — it reports the file as unparseable and drops
   it, and `.credo.exs`'s directory globs expand to `**/*.{ex,exs}` anyway. So a
   markup rule decidable from template SOURCE TEXT belongs in
   `EmisarWeb.TemplateHygieneTest` (which walks `.heex` and `.ex` alike and runs
   inside `mix test`, hence inside the gate), not in a Credo check that would
   silently cover only the `~H` sigils embedded in `.ex`. The anchor-glue rule
   shipped 8 violations while documented-but-unrun, 6 of them in `.heex`.
   **Routing: Elixir AST → `Emisar.Checks.*`; template source text →
   `EmisarWeb.TemplateHygieneTest`.**

   Run focused Credo checks after coherent `.ex`/`.exs` edits, before building
   dependent work on them. The full Credo check remains inside the final
   `./run gate portal`; it must report zero before committing.

   **What is covered mechanically is `.credo.exs` — read it there, not here.**
   The rules with a check say so at the rule (**Credo-enforced**
   (`Emisar.Checks.<Name>`)), each check's own `explanations:` block states the
   why with ✅/❌ examples, and `mix credo explain` prints it. A prose list in
   this file is a fourth copy that drifts the moment a check is added — this
   paragraph had already gone stale against three of them.

   A documented exception gets `# credo:disable-for-next-line
   Emisar.Checks.<Name>` (or `-for-lines:<n>`) directly under its
   why-comment — never a bare disable. Current sanctioned disables: the
   runner socket's directed `deliver_to_runner` publish, the MCP
   long-poll/recheck-timer tests' writer-side delay injections, and the
   `NoProcessDictionary` disables on `Emisar.Config` + `EmisarWeb.Sandbox`
   (the test-only per-process config-override seam — `Process.put` there
   is a config override that dies with the test process, never ambient
   request/audit state), plus the `ContextPublicFnSubject` disable on
   `Emisar.Admin.search_accounts/2` (the staff console reads ACROSS
   tenants, so there is no `%Subject{}` to gate with and no query for
   `for_subject/2` to narrow — its `ensure_staff/1` gate is the boundary,
   and it is public API, not an `@doc "Internal"` helper).

2. **`/elixir-iron-review`** carries the judgment laws a static check can't
   decide (their safety depends on where a value came from): IL-3/4/5
   (authz shape + return shapes), IL-10 (internal preload exceptions),
   IL-15 (per-event authz), IL-16 (`raw/1` on attacker-influenced text),
   IL-17/18 (OTP/LiveView discipline), IL-19 (vendor seams).

**Adding a rule = adding its check.** When the user states a new
mechanical rule (or corrects the same shape twice), the SAME change adds
an `Emisar.Checks.*` module under `credo/checks/`, wires it into
`.credo.exs`, and **fixture-verifies it fires**: write a temp violation
file (e.g. `apps/emisar/lib/emisar/zz_probe.ex`), run
`mix credo <that file>`, see the finding, delete the file. A check never
seen firing is a check that may not work — the old grep battery is
retired precisely because every one of its rules now has a
fixture-verified AST check.

Not every rule earns a check. A candidate that fires mostly on correct code trains people to ignore it or sprinkle `# credo:disable`, which is worse than no check — that belongs to `/elixir-iron-review` judgment. The candidates that were spiked, measured, and deliberately **not** wired are recorded with their false-positive evidence in [`.agent/kb/rules/elixir-rejected-credo-checks.md`](elixir-rejected-credo-checks.md); read it before proposing one of them again. The same applies to a proposed CONTEXT SPLIT: one that was measured and deliberately not carried out is recorded in [`.agent/kb/rules/elixir-rejected-context-splits.md`](elixir-rejected-context-splits.md), with the shared-helper counts that decided it — a long context module is a smell, not a seam, and the measurement is what tells them apart.

Then run the [Portal gate](../../../AGENTS.md#verification) (IL-20).
