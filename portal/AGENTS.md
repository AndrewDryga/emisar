# Portal — how we build (Iron Laws + skills)

**Read this before touching any context, schema, query, changeset, LiveView, controller, or MCP handler in `portal/`.** The architecture is a strict layered-context pattern. When unsure, copy the shape verbatim from an existing context — `Runbooks` and `Policies` are the cleanest references.

> **Identity vs tenancy:** `Emisar.Users` owns identity (the User schema, registration, profile/credential self-service, sign-in recording, and the user-row internals Auth/Accounts compose) — deliberately **cross-account**, so nothing in it scopes by account and it has no Authorizer (self-service authz is the `%Subject{actor: …}` match). `Emisar.Accounts` owns tenancy: accounts, memberships, invitations, and team administration (which calls `Users` internals for the user-row mechanics while keeping the permission + audit semantics).

The **Iron Laws** below are non-negotiable. The user has had to call out the same violations repeatedly; the mechanical subset is now enforced by **Credo** — custom AST checks YOU run after every portal edit (`mix credo <file>`) and that gate every commit (see [Enforcement](#enforcement)). Treat every law as a hard requirement, not a suggestion.

---

## How we build (prime directive)

The repo-wide **creed** — pragmatic & boring, opinionated (this codebase's existing shape wins), wear every hat (PM / UX / security / frontend / maintainer / marketing), ship great maintainable products, readable & no-bloat, done-means-verified, greenfield — lives in the **root `AGENTS.md`**. Read it there; it is not repeated here. This file is the **portal-specific** layer: the Iron Laws and House opinions below, plus two process specifics the creed leaves to portal:

- **The gate (IL-20).** Run `mix compile --warnings-as-errors && mix format --check-formatted && mix credo && mix test` and show the result — never say "should work". **Never pipe `mix format --check-formatted` (or `mix compile`) through `head`/`tail`** — the pipe's exit code replaces the tool's, so a formatting/compile failure passes silently. Run them as standalone commands (or `&&`-chain without a pipe) and read the real exit code.
- **Verify APIs before you call them — don't invent (`/verify-api`).** Never call a function, pass an arg/option, or use a CLI flag you're not certain exists with that signature. Look it up *first*: the code in this repo → the `deps/` source → `mix help` / IEx `h` → version-matched HexDocs → `--help`. `mix compile --warnings-as-errors` (it flags undefined/private functions and wrong arity) is the backstop, not the first line. If you still can't confirm it, say so and ask — don't guess.

### House opinions (extend freely)

Lower-stakes taste calls. Not Iron Laws, but the defaults. **The user adds to this list over time — append, don't rewrite.** Every correction the user gives — a review nit, a naming call, a "use X instead" — is a new rule, not a one-off fix: append it here (or the matching section) **in the same change that applies it**, then sweep the codebase for other instances of the old shape. A correction that only fixes the flagged line will be repeated; that's the failure mode this file exists to prevent. This list is the index; a rule that needs worked code gets a `.agent/rules/<slug>.md` (rule · why · ✅ good · ❌ bad · enforced) — see `.agent/rules/` (e.g. `no-pipe-in-branch-head.md`, `dispatch-on-pattern.md`).

- Pipe into the data; don't nest calls. A function reads top-to-bottom as a pipeline (`Query.not_deleted() |> Authorizer.for_subject(subject) |> Repo.list(...)`).
- Keep a pipeline's anonymous-function steps visually uniform: if any step's `fn` must wrap (body and `end` on their own lines, because it's too long to inline), hand-wrap the short ones too rather than leaving them inline. `mix format` preserves a hand-wrapped short `fn`, so the whole `Multi`/pipeline reads as one shape instead of a ragged mix of inline and block closures.
- `with` for the happy path; let the `else` carry the error shapes. Don't pyramid `case`. Prefer one flat `with` over a `case` whose branch opens another `with` — fold the inner steps up as more `<-` clauses.
- No multiline pipe in the *head* of a `with`/`case`/`if` clause (the expression being matched). If it needs `a |> b |> c` across lines, bind it first — a `name = expr` step inside the `with`, or a line above — and match the short name. `with {:ok, u} <- %X{} |> Changeset.f(attrs) |> Repo.insert() do` spanning three lines is a readability tax; `with cs = Changeset.f(%X{}, attrs), {:ok, u} <- Repo.insert(cs) do` reads flat. The same goes for a multiline pipe **as a function-call argument** (`Multi.delete_all(:tokens, A.x() |> A.y())`) — bind `queryable = …` before the call or pass a `fn changes -> … end` whose *body* pipes.
- A `, do:` one-liner is for bodies that FIT on one line. If the formatter would wrap `do:` onto its own line (the body spills over 98 cols), write a regular `do … end` block instead — `def f(x),\n  do:\n    long_call(…)` is never acceptable output. **Credo-enforced** (`Emisar.Checks.MultilineDoColon` flags any source line that is a bare wrapped `do:` — `def`/`defp` bodies and inline `if/unless` alike).
- Never bind a literal tuple just to re-return it (`{:error, :invalid} = err -> …; err`). Restate the literal at the end (`{:error, :invalid} -> …; {:error, :invalid}`), or for a wildcard pass-through re-wrap the bound reason (`{:error, reason} -> {:error, reason}`). The binding hides what the function returns.
- Name by intent, not by type. `expire_overdue_requests`, not `update_requests`. Boolean-returning fns end in `?`.
- Return only the shape callers consume. Don't carry an extra map field or a `{entity, flag}` tuple (e.g. fetch-or-create's `{user, created?}`) that no caller branches on — it's noise every caller and test must destructure, and it complicates the function. Confirm a real consumer exists before adding a return field; drop it when the last one goes.
- Spell variables out: `changeset`, not `cs`. A struct-typed binding takes the schema's own name — `%Membership{} = membership`, not `m`/`target`. Reach for a qualified name (`target_membership`) only to disambiguate two bindings of the same type.
- Pattern-match struct arguments by their struct in the function head — `create_request(%Runs.ActionRun{} = run, …)`, not a bare `run`. The head documents the contract and guards the type.
- Reference **another** context's modules through its top-level alias — `alias Emisar.Runs` then `Runs.ActionRun`, never `alias Emisar.Runs.ActionRun`. It keeps obvious which context a schema belongs to. (Aliasing your *own* context's submodules — `Grant`, `Request` — directly is fine. `Emisar.Auth.Subject`, the universal auth carrier, is the one cross-context exception we alias directly everywhere; `Emisar.Repo.*` is infra, not a context.) Applies to the web app too — a LiveView aliases the context, not its schemas. **Credo-enforced**, path-aware (`Emisar.Checks.CrossContextDeepAlias` derives the file's own context from its directory and flags any other `alias Emisar.<Ctx>.<Sub>`).
- **A context's `<Schema>.Changeset` modules are write-internals — no sibling context builds them.** Another context never does `User.Changeset.x(...) |> Repo.update()` or `Multi.update(:user, User.Changeset.x(...))`: it calls a (possibly `@doc "Internal"`) function on the owning context, composing it into its transaction via `Multi.run(:user, fn _repo, _ -> Users.mark_user_confirmed(user) end)` — same atomicity, internals stay private (this is how Auth's token flows write user rows). **The same goes for cross-context READS**: a sibling never builds a full pipeline on another context's `<Schema>.Query` + `Repo` (billing counting memberships, approvals fetching a run) — the owning context exposes the (often `@doc "Internal"`) function (`Accounts.count_memberships/1`, `Runs.peek_run_by_id/1`, `Runners.runner_active_in_account?/2`). The **sanctioned exceptions**, all documented elsewhere in this file: struct pattern-matches and pure schema helpers (`User.valid_password?/2`); Query-module *composition* — joins (`with_joined_user`), the audit label/scope resolvers (§2's `select_labels` + `Audit.resolve_references`); `workers/*` consuming Query-built pipelines (IL-1 prescribes it); the web reading Query-module **UI metadata** — `filters/0` for LiveTable (§6) and known-value lists like `Event.Query.known_event_type_values/0` for labels; fixtures/seeds building rows directly (§7). When a query module joins another context's table, it composes that schema's `Query.not_deleted()` (`m in ^Membership.Query.not_deleted()`), never the raw schema module — a raw join leaks soft-deleted rows.
- One public function = one job. If a context function has an `opts` flag that changes *what it does* (not just filtering), it's two functions.
- Small modules over big ones, but never a module per function. Follow the standard split (context / schema / query / changeset / authorizer) and stop there.
- Comments explain *why*, never *what*. The code says what. If you're tempted to narrate the what, the code isn't readable enough yet.
- All `use` / `import` / `alias` / `require` go at the very top of the module, **in that order** (`use` → `import` → `alias` → `require`) — never inside a function body or partway down the file. No blank line between `@moduledoc` and that block, **and none between the directives** — the module header is one contiguous block (`require Logger` sits at the bottom of it, after the aliases, not up by the moduledoc). **Credo-enforced** — the order is `StrictModuleLayout`; `Emisar.Checks.NoBlankBetweenDirectives` flags a blank line sandwiched between two directives, with ONE exception it skips: the blank `mix format` itself inserts before a multi-line directive whose options wrap (`use Phoenix.VerifiedRoutes,` ⏎ `  endpoint: …`) — don't fight the formatter there.
- **A grouped alias (`alias X.{A, B, C}`) stays on ONE line.** When the group is too long to fit on one line, **split it into multiple single-line grouped aliases** — never the formatter's one-module-per-line expansion (`alias X.{\n A,\n B,\n ...\n}`). E.g. `alias Emisar.SSO.{Authorizer, DirectoryGroupMember, GroupRoleMapping}` then `alias Emisar.SSO.{IdentityProvider, OIDC, UserIdentity}`, not the six-line block. Each split line fits, so `mix format` leaves it alone. **Credo-enforced** (`Emisar.Checks.MultilineAliasGroup`).
- Existence checks use `Repo.exists?(query)`, never `Repo.aggregate(query, :count, :id) > 0` — and never a fetch used only to test presence (`case fetch_x(…) do {:ok, _} -> taken` is the same violation: it pulls the whole row to answer a boolean). `exists?` stops at the first matching row.
- Enforce uniqueness with a DB unique index + `unique_constraint` in the changeset + error mapping — not a read-before-write check (`peek`/`exists?`-then-insert) inside the transaction. SELECT-then-INSERT races under concurrent callers (TOCTOU); the (partial, soft-delete-aware `WHERE deleted_at IS NULL`) index is the source of truth. Let the insert hit it, then map the constraint changeset back to the domain error (`%Ecto.Changeset{data: %Membership{}}` + a `:unique` error → `{:error, :already_member}`) — the unique-error test is the shared `Emisar.Repo.Changeset.unique_constraint_error?/1`, never a per-context private copy.
- Writing N rows? Use **one** `Repo.insert_all`/`Multi.insert_all`, not a `Multi.insert` (or `Repo.insert`) per row — especially for simple join tables. `insert_all` skips changesets, so validate first (build the changesets, bail on the first `not valid?`, then `insert_all` their `.changes`) and supply what it won't autogenerate: `:id` via `Repo.generate_id/0` (UUIDv7) and `:inserted_at`. The DB still backstops (`CHECK`, `varchar` length, unique index). The exception is a *deliberate* per-row insert/upsert for error isolation (one bad row mustn't abort the batch, e.g. the catalog action observe) — document why.
- `Repo.valid_uuid?/1` already returns false for `nil` and non-binaries — gate an id-fetch with a bare `if Repo.valid_uuid?(id)`, no `is_binary` guard (or nil clause) in front of it.
- **A single-row read returns `{:ok, row} | {:error, :not_found}` via `Repo.fetch(query, Query)`** — or `repo.fetch(query, Query)` inside a `Multi.run` — **never** `Repo.one()`/`repo.one()` followed by a hand-rolled `if row, do: {:ok, row}, else: {:error, :not_found}`. That nil→tuple is exactly what `Repo.fetch/2` replaces; reach for `Repo.peek/1` only where `nil` is itself the answer (§1.1). And **name a function for what it returns, not one side effect along the way**: a row-returning read is `fetch_*` (the prefix IS that tagged-tuple contract), one that mutates *and* hands the row back spells out both jobs (`fetch_and_lock_*`), and a side-effect-only name (`lock_*`, `touch_*`) must never secretly return a row a caller consumes. Sweep: any `one()`/`peek` paired with a `{:ok, _}` / `{:error, :not_found}` nil-check, and any side-effect-named fn returning `{:ok, struct}`.
- **A read/lock/write helper built to compose into a caller's `Ecto.Multi`/transaction takes the transaction repo as an optional** — `Keyword.get(opts, :repo, Repo)`, passed `repo: repo` from a `Multi.run` so it joins the open transaction, defaulting to `Repo` for standalone use. `repo` is genuinely optional, so it lives in `opts`, never as a positional (cf. *always-present arguments are positional*). Such a shared helper also **can't require a `%Subject{}`** if any caller is a subject-less system path (Oban sweeper, runner self-registration) — scope by the explicit, already-authorized `account_id` per §5, not `Authorizer.for_subject/2`.
- **A `Multi.run` callback's `repo` is a *variable*, so every `repo.fetch/one/update/insert/delete/all(...)` is a dynamic call `mix compile --warnings-as-errors` can NOT arity- or existence-check** — a wrong-arity `repo.fetch(query)` (missing the `Query`-module arg) compiles clean and crashes only at runtime. Match `Repo.<fn>`'s real signature by hand, exactly as a direct call would, and `/verify-api` the arity even when the compiler stays silent. Sweep: every `repo.<fn>(` call site. (Review+grep — not cleanly Credo-checkable.)
- All crypto goes through `Emisar.Crypto` (`random_secret/1`, `hash/1`, `mint/2`, `secure_compare/2`) — never inline `:crypto.*` or `Base.url_encode64` for a secret/digest in a context. One module keeps the RNG, encoding, and hash algorithm auditable in a single place (a security product wants exactly one crypto review surface). A token's byte **length** is a crypto concern too: expose a named minter (`Crypto.user_invite_token/0`) instead of calling `random_secret(24)` with a literal length in the context.
- Seed data never enrolls MFA/2FA and never mints TOTP secrets or recovery-code digests. Seeds may confirm demo users and may clean up a previously-seeded MFA enrollment through `Auth.disable_mfa/1`, but screenshot data must not fake possession of a user's second factor. 
- Field whitelisting is the changeset's `cast/3`, never a `Map.take`/`Map.drop` in the context. A mutation that may only touch a subset of fields gets its own changeset function (e.g. `User.Changeset.profile/2` casts only `full_name`); the context calls that, it doesn't pre-filter attrs.
- **A group of operator-tunable settings goes in ONE embedded `settings` jsonb value, not a column-per-toggle.** When a schema accumulates admin-flippable toggles/caps (booleans, limits, small enums), make them an embedded value object — `embeds_one :settings, <Schema>.Settings, on_replace: :update` over a `settings :map` column — that owns its own `changeset/2` (the embed is a plain `use Ecto.Schema` + `@primary_key false` module — the one place `use Emisar, :schema` doesn't apply, since it has no table/PK/timestamps). Read it through ONE accessor returning the embed (`fetch_account_settings/1`), **never a `fetch_<schema>_<field>/1` per setting**; keep the embed non-nil by construction (DB `default: %{}` + a create-time default) so `x.settings.<field>` is always safe; the field-aware permission/audit gate inspects the **nested** embed changeset (`changeset.changes.settings`), not top-level keys. The Nth setting is then a field on the embed + its UI — not a migration + a column + a context fn. Worked example: `.agent/rules/embedded-settings.md`.
- **Cast user input through the changeset FIRST, then read the cast value back for guards** — `changeset = X.Changeset.update(row, %{role: new_role}); new_role = Ecto.Changeset.get_field(changeset, :role)`. The Ecto.Enum cast hands you the atom (or an invalid changeset); a hand-rolled `normalize_role`/`cast_*` in the context duplicates the changeset's job and drifts from it.
- A read a transaction depends on goes *inside* the `Multi` as a `Multi.run` step (later steps read it from `changes`), not eagerly before `Multi.new()`. It stays in the transaction's snapshot and a missing row becomes `{:error, …}` instead of a raise.
- **Fetch-then-mutate holds the row lock.** Any function that looks a row up and then writes it (admin profile edits, forced password resets — not just self-service) goes through `Repo.fetch_and_update/3` (locked re-read + `:with` changeset + `:audit` + `:after_commit`), or fetches inside the `Multi`. Fetching with `fetch_user_by_id/1` *outside* the transaction and `Multi.update`-ing the stale struct loses concurrent writes between the read and the lock.
- A **fetch-or-create** must survive the insert race: insert with `on_conflict: :nothing` and re-fetch the winning row. A raw unique violation can't be rescued-and-continued inside the surrounding transaction (Postgres aborts it), so SELECT-miss → INSERT → re-SELECT is the race-safe shape.
- Compose transactions with `Ecto.Multi` + `Repo.commit_multi`, not `Repo.transaction(fn … end)` with imperative `case` / `{:ok, _} =` matches / `Repo.rollback`. A **fetch-or-create** is a single `Multi.run` that returns `{:ok, {row, created?}}`; later steps read it from `changes`. A reject condition (e.g. "already a member") is `{:error, reason}` from a `Multi.run`, not `Repo.rollback`.
- When one update path spans fields with different permission levels, build the (side-effect-free) changeset first, inspect `changeset.changes`, and require the permission matching the fields that actually changed — don't split into near-duplicate functions, and don't gate the whole path at the most-privileged level (that needlessly blocks low-privilege edits). The same shape applies when the required permission depends on a **value being granted** rather than a changeset field: inviting/assigning the `:owner` role needs `manage_owners` on top of `invite_member`, so pick the permission *list* from the role and run **one** `ensure_has_permissions/2` — not a permission check plus a separate role guard.
- Audit rows are built by **per-event helpers** in `Emisar.Audit.Events` (e.g. `account_created/2`, `membership_role_changed/3`) that take the domain structs + the acting `%Subject{}` and derive the actor (`Subject.actor_kind/1`, `Subject.actor_id/1`). Context mutations call those inside their `Multi.insert(:audit, …)`; they never hand-assemble `actor_kind`/`subject_kind`/`payload`. Add a builder per newly-audited event. **Audit is a domain concern: controllers/LiveViews never call `Audit.log*` — the domain function that performs the mutation writes its own audit row** (e.g. `Accounts.record_sign_in/2` owns `user.signed_in`; the session controller just calls it).
- **Request metadata (ip/ua/request_id/mcp_session) is an `%Emisar.RequestContext{}` struct, threaded explicitly — never the process dictionary.** It rides on `%Auth.Subject{}.context` for authenticated callers (every `Audit.Events` builder pulls it via `actor/1`, so the 20-plus builders inherit it free) and is passed as an explicit, defaulted `context \\ %RequestContext{}` last positional argument on the pre-auth paths that have no subject yet (sign-in/out, failed sign-in, magic link, password reset, email confirm, MFA verify). The web boundary builds it once — `EmisarWeb.RequestContext.from_conn/1` in a controller, `from_socket/1` in a LiveView (captured at **mount** into an assign, because `get_connect_info/2` is mount-only, then read in `handle_event`). An event with no context (system / engine origin) carries no request metadata by construction. **Never reintroduce a `Process.put` / `$callers` ambient channel for it** — that coupling is exactly what let a runner socket's connect UA bleed onto engine audit rows in the same process. Credo-enforced (`Emisar.Checks.NoProcessDictionary` flags `Process.put` in `lib/`).
- Errors are values (`{:error, reason}`), not exceptions, on any path a caller can hit. `!`-raising variants only behind a proven invariant.
- Don't wrap a single delegating call in its own named function — inline it. A `defp foo(a, b), do: Bar.foo(a, b)` earns a name only when it adds meaning the call site lacks; otherwise the indirection just costs a jump. Keep the *why* comment at the call site.
- A pure helper used in more than one place is its own small module with unit tests (e.g. `Emisar.Slug`), not a `defp` copy-pasted between call sites. Take options for the per-caller differences instead of forking the logic.
- **A guarded single-row mutation goes through `Repo.fetch_and_update/3`, not a hand-rolled lock-Multi.** Its `:with` runs inside the transaction on the locked row — bind that row `loaded_<schema>` (`loaded_account`, `loaded_membership`), never a vague `fresh` — so domain guards that must judge CURRENT state (hierarchy checks, field-aware escalations) live there — returning any non-changeset value aborts as `{:error, that_value}`, and an invariant query a guard needs (the locked last-owner re-count) is a plain `Repo` call, which joins the same transaction. `:audit` takes `(updated)` or `(updated, changeset)` — `changeset.data` is the locked pre-update row when the audit payload needs before-state (e.g. role changes). Hand-roll a `Multi` only when the mutation writes OTHER rows after judging the locked target (Accounts' `lock_target_membership/3` prefix) or spans multiple tables. **Composing `fetch_and_update` inside such a Multi is the intended shape** — its nested transaction JOINS the outer one, so both row locks + the audit insert commit atomically — but the nested call carries `:audit` ONLY: an `:after_commit` there would fire when the inner transaction returns, i.e. while the outer is still open, letting side effects escape a commit-time rollback. Side effects belong on the outer `Repo.commit_multi(after_commit: …)`; `fetch_and_update` raises on the nested misuse.
- `Authorizer.for_subject/2` is the **last** queryable transform in a pipeline: filters, ordering, preload helpers, and `lock_for_update` come before it, and the `Repo.*` call follows immediately. IL-4 says "immediately before" — that's the letter, not approximately.
- **Upserts are preferred.** When the row's identity is a unique key, write it with ONE statement — `Repo.insert(changeset, on_conflict: {:replace, [...]}, conflict_target: ..., returning: true)` — not peek-then-insert-or-update and not insert-rescue-refetch. The upsert is atomic under concurrency where the read-then-write shape races. When an audit payload needs the before-state, read it as a step in the same `Multi` — still a single write. (Exception: a state machine where the conflict path must *judge* the existing row — e.g. pack trust — keeps its explicit branches; say why at the call site.)
- **Use RETURNING instead of a follow-up read.** Data the write itself can hand back is never re-fetched: `returning: true` on insert/upsert, `select` on `update_all`/`delete_all`. A write immediately followed by a fetch of the same row(s) is the smell.
- **Dispatch on a pattern, not an inner `if`.** A closure or function whose body is one `if`/`case` testing a pattern-matchable property of its argument (field nil-ness/truthiness, a literal value, struct shape) becomes clause heads instead: a `:with` callback like "skip when already linked" turns into a named two-clause defp (`link_paddle_customer_unless_linked(%Account{paddle_customer_id: nil}, id)` / catch-all) passed by capture; a bare-arg `case` with literal branches (`client_config("cursor", url, key)`) turns into multi-clause heads. `if` stays for genuinely computed conditions (comparisons, function-call results) and `case` stays for matching something *other than* the argument itself (e.g. `conn.assigns[:x]` Access on optional keys).
- **`match?/2` is for a SHAPE check, never to test a field's VALUE.** `match?({:ok, %{require_sso: true}}, fetch())` or `match?(%{provider_id: id} when id == x, token)` buries the real question — *is the flag true? does the id match?* — inside a pattern and conflates "the result has this shape" with "this field holds this value": it reads as a puzzle AND breaks **silently** when the field moves (this exact shape disabled the `require_sso` last-provider guard when the field moved into the settings embed — the match just went always-false). Destructure with a `case` and read/compare the field explicitly — `case fetch() do {:ok, s} -> s.require_sso; {:error, _} -> false end`, or a pin/guard clause (`%{provider_id: ^id, token: token} -> token`). Keep `match?` for genuine shape tests only (`match?({:ok, _}, x)`, `match?(%User{}, x)`). Sweep: any `match?(` whose pattern binds a field to a literal or compares one in a `when`.
- **Any closure whose body is a single call uses capture syntax** — `&disconnect_user_sessions/1`, `&do_revoke(&1, id)`, `&save(&1, publish?: true)`, `audit: &Audit.Events.policy_updated(subject, policy, &1)`, `& &1.group` — so long as it stays one readable line. `fn` earns its keep only for: multi-step bodies, pattern-matching heads, multi-clause closures, a zero-arity closure that passes scope values (a capture needs at least one `&N` placeholder — `fn -> count_for(subject) end` can't convert; bare `fn -> f() end` becomes `&f/0`), a closure nested inside an outer capture (capture-in-capture won't compile), and when the argument is used several times and naming it genuinely reads better than repeated `&1`s.
- **Every PubSub publish goes through a named per-event function** — `broadcast_auth_key_revoked(%AuthKey{} = key)`, not a shared `broadcast_x_change(struct, "event.string")` that takes the event name as data. The function head documents the message; the literal topic + tuple live inside it. All `subscribe_*` and `broadcast_*` functions sit together in one `# -- PubSub ----` section per context so the context's topics and message shapes read in one place. No inline `Emisar.PubSub.broadcast/2` at mutation sites.
- **No pipe anywhere in a `with`/`case`/`for` head — single-line included.** `{:ok, x} <- a() |> b()` hides the operation being matched; bind first (`queryable = Token.Query.all() |> Token.Query.by_prefix(prefix)`) and match the short call (`<- Repo.peek(queryable)`). Credo-enforced (`Emisar.Checks.NoPipeInBranchHead` matches the AST, so every form — one-line, wrapped, `case` heads — is caught).
- **Preloads that exist for rendering are the CALLER's concern.** A context read whose associations are only consumed by a page exposes a `preload:` option — the caller passes exactly the assoc atoms it renders (`Accounts.list_memberships_for_account(account, subject, preload: [:user])`), and a counting/existence caller omits it and pays for no joins. Inside the context the option maps to the Query's `with_preloaded_*` helpers through a whitelist reducer (`apply_membership_preloads/2` — unknown atoms raise), popped off `opts` before the Repo call. Preloads that are the function's CONTRACT — every caller needs them (the session membership feeding `current_account`/`current_user`, an internal single-consumer like the approval notifier's `user`) — stay unconditionally chained with a why-comment. What remains banned (Credo-enforced, `Emisar.Checks.NoPreloadInRepoOpts`): the context smuggling preloads INTO the Repo opts — `Keyword.put_new(opts, :preload, …)` / a literal `preload:` in the `Repo.fetch`/`Repo.list` argument list — because that bypasses the `with_preloaded_*` helpers and their soft-delete scoping.
- Don't build an argument with a nested transform call inline — `Repo.fetch(query, Query, Keyword.put_new(opts, …))` makes the reader parse two calls at once. Bind the transformed value on its own line above, then pass the name. (Same family as the multiline-pipe-as-argument rule.)
- LiveTable `filters/0` callbacks bind their queryable as **`queryable`** — `fun: fn queryable, statuses -> …` — never `q`. (The `[runs: r]`-style DSL bindings inside `dynamic`/`where` stay the documented §2 idiom.)
- **A query DSL binding is a SINGLE letter** — `[group_members: g]`, not `[group_members: gm]`. The binding atom already names the table, so the variable is just a one-letter handle (the §2 idiom: `[runbooks: r]`, `[memberships: m]`); a multi-letter abbreviation is the same smell as `cs`/`q`. **Credo-enforced** (`Emisar.Checks.ShortBindings` flags multi-letter bindings in the 3-arg `where`/`order_by`/`select`/… forms).
- **`@doc`/`@moduledoc` state the contract, never narrate the body.** A public function's `@doc`: one line on what it does, the `%Subject{}`/permission it requires, and the return-shape tuple — matching the real code. A context module's `@moduledoc` is one paragraph naming it the public/authorization boundary for its domain; Query/Changeset/Schema get one line. §1.4 internal helpers get `@doc "Internal — <who calls it>"`; truly-private fns get `@doc false` or nothing — never a paragraph for a one-liner, never a "new/refactored version" note (IL-11), never an untested example. Document **as you write** (`/context-fn`, `/new-context`), not in a later pass. Worked example: `.agent/rules/doc-contract.md`.
- **Compare an `Ecto.Enum` field on its atoms, never a string literal.** An enum field loads as an atom (`:sent`), so `@run.status in ["sent", "running"]` is *always false* and fails silently — it shipped a costly dead-UI bug (`69d9871`: cancel button + approval banner + output-hiding all dead, nothing flagged it). Compare atoms (`in [:sent, :running]`), or normalize at the edge with `to_string`. The two deliberate `:string` look-alikes are `Subscription.status` and `Subscription.plan` (§3). Not reliably Credo-checkable — an AST check can't tell an enum `.status` from a string one without type inference — so it's a review+grep rule. Worked example: `.agent/rules/ecto-enum-atom-compare.md`.
- **An acronym is all-caps in a module name.** `EmisarWeb.SCIM.UserController`, `Emisar.SSO.OIDC`, `EmisarWeb.MCP.*` — not `Scim`/`Oidc`/`Mcp`. CamelCase capitalizes each *word*; an initialism is one all-caps unit. (snake_case identifiers stay lowercase — `scim_token`, `oidc_state`, the `/scim/v2` path — the rule is module/alias names only.)
- **Always-present arguments are positional, not buried in `opts`.** `opts` is for the genuinely per-call-optional. A value every caller must supply — a session's `auth_method` — is a required positional argument that forces the caller to decide it, not a `Keyword.get(opts, :auth_method)` that silently defaults to `nil`. Keep in `opts` only what is actually optional (the SSO-only `:user_identity_id`).
- **Don't invent a custom select-result shape; carry the struct.** A read that needs a row's fields returns the **whole struct** — or a tuple of structs (`{user, token}`), preloading what it renders — never a bespoke `select(q, [...], %{a: t.a, b: t.b})` map that every caller and test must learn. A new shape is new surface to maintain; a struct (or `{entity, entity}` tuple) is one callers already know, and it carries new fields for free. Name the function for what it returns (`fetch_user_and_token_by_session_token`, not `fetch_user_…` returning a third element).
- **A test's context is an explicit `%{...}` pattern in the head, never a bare `ctx`/`context`.** `test "…", %{account: account, subject: subject} do` — the entities the test uses read at a glance, and an unused setup key is a warning. Never `test "…", ctx do` then `ctx.account`: it hides the test's real dependencies and silences the unused checks. (See §7.)
- **A test file's `describe` blocks follow the SAME order as the functions in the module under test.** `accounts_test.exs` opens with `fetch_account_by_id/1` because that's the first function in `accounts.ex`; the describes then track the module top-to-bottom, so a reader pairs test↔function by position and spots an untested function by its gap. A new test slots in at its function's position, never appended at the end.
- **Every PUBLIC function in a context has a function-named `describe "fun/arity"` with real tests** — and a concept-named describe (`"MFA lifecycle"`) doesn't count; rename it to the function it exercises. The describe-order rule above exists precisely so a missing function is a visible *gap*; this rule says that gap must be zero. **Enforced** by `Emisar.ContextCoverageTest`, which reads each context's public `def`s and fails the suite if any has no `describe` anywhere in the test tree (add a new context to its `@contexts` list when you create one). Add the describe in module order with §7's happy / denial / cross-account paths — never silence the check.
- **Tests `alias Emisar.Fixtures` and call domain-namespaced fixtures — `Fixtures.Accounts.create_account/1`, `Fixtures.Users.create_user/1`, `Fixtures.Memberships.create_membership/1` — never `import Emisar.Fixtures`.** An `import` dumps every fixture into scope unqualified, so a reader can't tell `account_fixture()` from a local helper and two fixtures can't share a verb; the namespaced call (`Fixtures.<Domain>.<verb>`) reads as what it builds. Fixtures live in per-domain submodules under `Emisar.Fixtures.*`.
- **Shared per-`describe` fixtures go in a `setup` block that returns the context map, not repeated inline in every test.** When a describe's tests all need the same `user` + `account`, build them once — `setup do … %{user: user, account: account} end` — and each test pattern-matches what it uses in its head (`test "…", %{user: user, account: account} do`); only rows a single test needs (and varies) stay inline. Re-calling the same fixtures at the top of every test is the "fixture abuse" smell. (Pairs with the explicit-`%{...}`-head rule above.)
- **Product analytics (Mixpanel) goes through ONE seam — `Emisar.Analytics` — server-side only, scoped to MARKETING + GROWTH.** We ship **no** client-side SDK (strict CSP + the "no third-party trackers" brand promise on /trust). **Scope is deliberately narrow:** pageviews + lead capture (funnel), sign-up / sign-in / sign-out (acquisition + retention), and plan (`subscription_changed`). **NEVER send operational telemetry we can read from our own database** — runs, runner connects, approvals, policy edits, pack trust, team changes, runbooks — to a third-party tool (data minimization for a security product). `subscription_changed` is the ONE deliberately-kept domain builder in `Emisar.Analytics.Events`; don't add more, and never an inline `Analytics.track` at a call site or a client `track()`. Pageviews/funnel/identity live in `EmisarWeb.Analytics`: **marketing** pages via the `:browser`-pipeline plug, **console** (LiveView) pages via the `:track_pageviews` `on_mount` hook (`handle_params`, connected-only) since console nav is over the websocket with no controller hit. Console pageviews are `page_viewed` (engagement), NOT a special event — but the operational *domain* events above stay out. Tracking is **cookieless**: an anonymous visitor is a **weekly**-rotating salted IP+UA hash (`Emisar.Crypto.anonymous_visitor_id/1`, `$device:`-prefixed — the Plausible model), an identified visitor is `user.id` from the auth session; the only cookie is the functional login/CSRF session cookie — never reintroduce a session/cookie-stored analytics id. We do **NOT** honor DNT/GPC (cookieless first-party analytics isn't a "sale/share", so the headers don't apply — and our audience is GPC-heavy, so honoring it blinded the funnel). Disclose any new processor on `/privacy` + `/trust` + `/dpa` (one list, three templates + the marketing test). A no-op unless `MIXPANEL_TOKEN` is set (off in dev/test). User profiles (`$name`/`$email`) are set at login; account-level **Group Analytics** (group key `account_id`, set on console events + `subscription_changed`) is wired but gated by `MIXPANEL_GROUPS=1` (paid add-on). Full tracking plan: `.agent/specs/mixpanel-analytics.md`.

---

## Iron Laws (non-negotiable)

Numbered so Credo, `/iron-review`, and code review can cite them. **Architecture laws (IL-1…IL-11)** are the layered-context shape — the part the user repeats most. **Phoenix-safety laws (IL-12…IL-19)** are the generally-applicable Elixir/Phoenix guardrails. **IL-20** is process. Detail + code for each architecture law is in the [Reference](#reference--module-by-module) section it points to.

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
| **IL-9** | **Authorizers define permissions via `build(Schema, :verb)` exposed through accessor fns.** | One union of these role lists builds every `%Subject{}.permissions`. Reaching past the accessor desyncs them. | Raw permission tuples at call sites. → [§5](#5-authorizer-modules) |
| **IL-10** | **`:preload` routes through the Query module's `preloads/0`; never `Repo.preload/2` in a context's Subject-gated reads.** | Keeps preload shapes defined in one place per query. (Exception: an *internal* — no-Subject, already-authorized — path that holds a struct and needs its parent assoc uses `Repo.preload(struct, :assoc)` rather than a cross-context `fetch_*_by_id!`: post-commit email helpers, the runner-register billing check.) | `Repo.preload(` inside a Subject-gated read in `lib/emisar/<context>.ex`. → [§1.4](#14-internal-sweepers--worker-only-helpers) |
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
| **IL-20** | **Verify before claiming done.** Run `mix compile --warnings-as-errors && mix format --check-formatted && mix credo && mix test` and show output. If you can't run it, say so explicitly. | "Should work" has burned us. Generated code that doesn't pass `mix test` doesn't get committed. | A "done" claim with no command output in the transcript. |

---

## Skills

Project skills live in **`../.claude/skills/`** (repo root, so they're found from anywhere in the monorepo). Each is scoped to `portal/` Elixir. Invoke with `/<name>`.

| Skill | Use when |
|-------|----------|
| `/spec` | Designing a change that spans more than one file/context. Produces an opinionated, boring-by-default plan in the layered-context shape. |
| `/work` | Executing a plan step-by-step with compile/test gates between steps. |
| `/ship-review` | Reviewing a diff before merge through the product hats **and** the Iron Laws, in parallel. The product-level companion to `/code-review` (bugs) and `/iron-review` (laws). |
| `/review-board` | The full pre-merge review — convenes a panel of expert hats (staff eng, domain, security, UX, UI, PM, marketing, sales) as parallel subagents, then synthesizes one ranked verdict + a prioritized fix plan (queueable into `.agent/tasks/00_todo/` for `/sweep`). Supersedes running `/security-review` + `/code-review` + `/ship-review` separately. |
| `/new-context` | Scaffolding a whole new context (context + authorizer + schema + query + changeset + tests) in the standard shape. |
| `/context-fn` | Adding one read or write function to an existing context the canonical way. |
| `/iron-review` | Checking a diff (or the working tree) against IL-1…IL-20. The judgment-side complement to the Credo checks. |
| `/verify-api` | In doubt whether a function/arg/option/CLI flag exists with that signature — check the repo, `deps/`, `mix help`/IEx, HexDocs, or `--help` before writing it (prime directive #7). |
| `/investigate` | Root-causing a crash, exception, stacktrace, failing test, or wrong behavior — find the cause, not a symptom. |
| `/perf` | A slow page/list/query, hot DB, or heavy socket — N+1, missing preloads/indexes, `stream` vs `assign`. |
| `/boundaries` | Auditing context coupling/layering via `mix xref` — web bypassing contexts, cross-context reach-ins, cycles. |
| `/oban` | Building or reviewing a background job / scheduled sweep in `workers/` (idempotent, string-key args — IL-13). |
| `/testing` | Writing ExUnit tests the house way — `DataCase`, `fixtures.ex`, the happy/denial/cross-account paths (§7). |
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

**Arrangement.** Order a context top-to-bottom as: moduledoc → aliases/`require`/module attributes → the domain API in `# -- Section ----` blocks (reads, then mutations/actions, then any specialized sections) → a trailing **`# -- Authorization ----`** section for the `subject_can_<verb>?/1` capability predicates → internal/private helpers last. The capability predicates are a *supporting* surface (the web calls them to show/hide UI) — they belong in their own near-the-end section, **never crammed at the very top before the domain API**.

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

**Soft-delete default:** start every read pipeline at `Schema.Query.not_deleted()`, not `all()` — tombstoned rows are excluded unless you *explicitly* need them (use `all()` then, with a why-comment). `not_deleted/1` defaults its first arg to `all()`, so it's the natural chain head (`Membership.Query.not_deleted() |> Membership.Query.by_account_id(id)`). A schema with no `deleted_at` has no `not_deleted/1` — start at `all()` there.

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
- This holds for **side-effect actions too**, not just row reads/writes — a `!`/no-row-returned helper an authed user triggers still takes the `%Subject{}` and the subject flows down the call chain.
- For a **self-service** action (a user acting on their own data — profile/email/password edits, session revocation), read the user from `subject.actor`; don't also accept it as a separate arg. `change_user_password(current, new, %Subject{actor: %User{} = user})`, not `(user, current, new, subject)`. The `%Subject{actor: %User{} = user}` match *is* the authorization (you can only act as your own subject) — no separate same-user check, and no admin/override bypass on a self-service path (that's a credential-editing footgun; admin-driven edits have their own functions).
- The `subject.actor` you read on a self-service path is a **long-lived socket snapshot** and can be stale. A self-service *mutation* must re-fetch the row before writing — `Repo.fetch_and_update/3` locks `FOR NO KEY UPDATE`, re-reads, and runs your `:with` changeset on the fresh row (scope by `by_id(subject.actor.id)` — self-service needs no `for_subject`). This is load-bearing for current-password challenges: `User.valid_password?(subject.actor, given)` checks a possibly-**stale** `hashed_password`, so a password rotated away in another session could still pass the gate; validate against the freshly-fetched row instead.
- A deliberate **cross-account self-read** (the account picker's `list_accounts_for_user/2` — every tenant the user belongs to) scopes by the subject's actor id and intentionally omits `Authorizer.for_subject/2`, which would wrongly narrow to a single account. It's the rare, documented exception to IL-4 — say so at the call site.
- Internal helpers called from sibling contexts that have already authorized may take an account_id / actor_id instead. Name them so it's obvious (`fetch_policy_for_account!/1`, `dispatch_runbook/4`), keep them private or moduledoc-marked "internal", and never expose them to LiveView/controllers/MCP.
- `Authorizer.for_subject(query, subject)` is **always** in the pipeline immediately before `Repo.fetch/list/fetch_and_update`. It is the second authorization gate (permission check + row scoping).
- **Subject + entity ⇒ two gates.** When a function takes a domain entity *and* a `%Subject{}`, run BOTH: `ensure_has_permissions/2` (does the role allow this action?) **and** an ownership gate that the entity lives in the subject's account (`Subject.ensure_in_account/3`, or `ensure_subject_owns_account/2`). Permission alone is insufficient — an admin of account A holding account B's struct must be rejected.
- **Subject + explicit account ⇒ scope by both.** When you build a query from an explicit account (or account-bearing entity) *and* a subject, filter by BOTH the explicit account (`Schema.Query.by_account_id(account_id)`) **and** `Authorizer.for_subject(subject)`. Belt-and-suspenders against accidental cross-account leaks: a wrong subject would scope to the wrong account, so the explicit account filter is the backstop (this is what `list_memberships_for_account` does).
- `Auth.Authorizer.ensure_has_permissions/2` accepts a single permission, a list (all required), or `{:one_of, [perms]}` (any one).

#### 1.3 Return shapes (IL-5)

- Reads: `{:ok, row} | {:error, :not_found | :unauthorized}` for single; `{:ok, [row], %Paginator.Metadata{}} | {:error, ...}` for list.
- Writes: `{:ok, struct} | {:error, %Ecto.Changeset{} | :unauthorized | :not_found}`.
- Never return a bare struct or `nil`. Tagged tuples only.

#### 1.4 Internal sweepers + worker-only helpers (IL-10)

A small set of context functions never take a `%Subject{}`: the runner socket process's state advertisers (`Runners.apply_state/2`, `Runners.mark_connected/1`, `Runners.mark_disconnected/2`, `Runners.record_heartbeat/2`), the catalog observer (`Catalog.observe_state/2`), Oban sweepers (`Approvals.expire_overdue_requests/1`), `Runs.create_run/1` / `Runs.dispatch_to_runner/1` / `Runs.mark_*` transition helpers, and the **inbound SCIM lifecycle** (`SSO.authenticate_scim_token/1` + the `SSO.scim_*` family — `scim_provision_user`, `scim_deactivate_user`, `scim_reactivate_user`, `scim_fetch_user`, `scim_list_users`, `scim_upsert_group`, `scim_patch_group_members` — and `SSO.recompute_role_for_identity/2`). They run inside processes that have already authenticated (runner socket carries `Subject.for_runner` upstream; Oban sweepers operate on explicit account ids through named internal helpers; the SCIM web boundary resolves the per-provider `ems-` bearer first, so the returned `%IdentityProvider{}`'s provider-scope IS the authz, and every read scopes by `provider.id`/`provider.account_id`). Mark these `@doc "Internal …"` and never expose them to LiveView/controllers/MCP.

`:preload` opts route through the per-Query `preloads/0` callback first; never call `Repo.preload/2` from a context module. The lone allowed exception is an internal mutation-side helper that's preloading an already-fetched struct for email rendering or a similar post-commit side effect.

### 2. Query modules (`lib/emisar/<context>/<schema>/query.ex`)

```elixir
defmodule Emisar.Runbooks.Runbook.Query do
  use Emisar, :query        # imports Ecto.Query, attaches @behaviour Emisar.Repo.Query
  alias Emisar.Runbooks.Runbook

  def all, do: from(runbooks in Runbook, as: :runbooks)
  def not_deleted(queryable \\ all()), do: where(queryable, [runbooks: r], is_nil(r.deleted_at))
  def by_id(queryable \\ all(), id), do: where(queryable, [runbooks: r], r.id == ^id)
  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [runbooks: r], r.account_id == ^account_id)
  def by_status(queryable \\ all(), status), do: where(queryable, [runbooks: r], r.status == ^status)
  def ordered_by_title_version(queryable),
    do: order_by(queryable, [runbooks: r], asc: r.title, desc: r.version)

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runbooks, :asc, :title}, {:runbooks, :desc, :version}, {:runbooks, :asc, :id}]

  # Label-batcher for Audit.resolve_references/1 — the query module owns the binding.
  def select_labels(queryable, ids, field) do
    queryable
    |> where([runbooks: r], r.id in ^ids)
    |> select([runbooks: r], {r.id, field(r, ^field)})
  end
end
```

Rules:
- **`use Emisar, :query`** — never `import Ecto.Query` directly.
- Every helper is composable: takes `Ecto.Queryable.t()`, returns `Ecto.Queryable.t()`. First arg defaults to `all()` so you can either start a chain or extend one. Name that first argument **`queryable`**, not `q`.
- Use **named bindings** (`as: :runbooks`, `as: :requests`) so later helpers don't break when an upstream caller already added a `join`. Reference by `[runbooks: r]`, not positionally.
- `not_deleted/1` is the standard partial-index-friendly soft-delete filter; pair it with the changeset's `delete/1` (`deleted_at`).
- `cursor_fields/0` and `filters/0` are `Emisar.Repo.Query` callbacks; declare them when the context paginates or filters via `Repo.list/3`.
- `preloads/0` entries use the `{scope_query, nested_preloads}` tuple — `account: {Account.Query.not_deleted(), Account.Query.preloads()}` — so the associated schema's own `preloads/0` cascades and deep nesting composes. Any query module reachable as a preload declares its own `preloads/0` (even `do: []`) so callers can compose that tuple.
- For an association a list pipeline always loads, expose **two** helpers, not one: `with_joined_X/1` (idempotent `with_named_binding/3` + join scoped to the assoc's `not_deleted/0`) and `with_preloaded_X/1` (`queryable |> with_joined_X() |> preload(...)`). Keeping the join separate lets it be reused to filter on the joined columns; putting `preload` *outside* the idempotency block means it still applies when the join already exists. **Once the helpers exist, context pipelines call them** — `|> Membership.Query.with_preloaded_account()` in the chain, not a `preload: [:account]` opt on `Repo.fetch/list`. The join-based helper also subsumes a separate active-assoc filter (it inner-joins `not_deleted/0`), so a bespoke `for_active_X` filter next to it is dead weight.
- **Join direction follows the association's cardinality/optionality:** `:inner` for a required belongs_to (a row whose assoc is missing or deleted shouldn't appear — e.g. a membership's account/user); `:left` for a has_many or optional assoc (keep the parent even with zero children — e.g. an account preloading its memberships still shows when it has none). **Either way the join is scoped to `not_deleted/0`** — soft-deleted records never leak into the preload regardless of direction.
- Cross-table label helpers belong here too: `select_labels(queryable, ids, field)` (used by Audit).
- A helper whose name implies a position (`latest`, `oldest`, `top_n`) owns both its `order_by` and its `limit` — callers shouldn't have to remember to order first for the limit to mean anything.
- Name order helpers after the columns they sort by — `ordered_by_type_and_value`, `ordered_by_group_name`, not a bare `ordered`. The ordering is then visible at the call site and flags where a matching DB index (incl. its direction) is needed.
- Match a helper's name to its argument: a name ending in `_id` (`by_user_id`, `by_membership_user_id`) takes an **id**; without that suffix it takes the **struct** (`by_user(user)`). For a value reached through a nested association, name by the **path** to it — `by_membership_user_id` (accounts → `membership.user_id`), not an opaque `with_active_member`. Reserve the `with_*` prefix for join/preload helpers (`with_joined_*`, `with_preloaded_*`), never a plain filter. (Edge cases exist — a helper bundling an extra constraint, like excluding suspended members; document the extra filter in the `@doc`.)
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
- Separate logical field groups with a blank line (identity / credentials / feature-X / flags) so a long schema scans at a glance. Keep associations and `timestamps()` in their own trailing groups.
- Use `Ecto.Enum` (`field :kind, Ecto.Enum, values: [:a, :b]`) for any fixed string-set field — never `:string` + a `@valid_types` list + a `validate_inclusion` in the changeset. The enum casts to atoms, validates inclusion on cast for free, and keeps the DB value as the string form. Match on the atoms (`:group`), not strings. **Two `:string` exceptions stay (no `Ecto.Enum`), each with a why-comment at the field — both on the `subscriptions` Paddle mirror, whose value space is vendor-owned:** `Subscription.status` (Paddle can mint statuses we've never seen, and they must persist rather than 500 the webhook — drop the inclusion list entirely) and `Subscription.plan` (a renamed/legacy/sales-led plan name must still LOAD and degrade gracefully — `Billing.account_plan/1` reads it as the single plan-gating source and `Billing.plan/1` maps an unknown name to free-tier limits, whereas an enum would raise on every fetch). Wire boundaries don't block the enum: inbound strings cast fine (changeset `cast`, query `^param`s, `update_all` sets), Jason encodes the atoms back to the same strings, and shared components normalize via `to_string` (`status_badge`, `risk_pill`).
- Natural keys compared case-insensitively — emails, slugs — are **`:citext`** columns at the DB level (the extension is enabled in the first migration). The citext column + its unique index IS the guarantee — **no app-side `String.downcase` anywhere**: not on lookup params (`u.email == ^email` already compares case-insensitively), not before writes (store the typed casing; registration does, so every other write path must match). `String.trim` at the entry point stays — citext doesn't strip whitespace. (Downcasing a *recovery code* before hashing is a different thing — that's case-insensitive code entry, not a citext column.)
- **Soft-deletes never leak through preloads.** EVERY association whose target schema has `deleted_at` carries `where: [deleted_at: nil]` — `belongs_to` as much as `has_many` (`belongs_to :account, Account, where: [deleted_at: nil]`; `has_many :memberships, Membership, where: [deleted_at: nil]`). When adding an assoc, check the target schema for `deleted_at` and add the where in the same edit. `through:` associations can't take `:where` — they filter via the associations they traverse. Mirror it in the Query module's `preloads/0`: declare the assoc as the `Schema.Query.not_deleted()` query, not a bare `[]`, so the filter is explicit at the preload site too (`Emisar.Repo.Preloader` hands both the bare-preload and query-override paths to `Ecto.Repo.preload`, which honors the association `:where`).

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

  def delete(%Runbook{} = runbook), do: change(runbook, deleted_at: DateTime.utc_now())

  defp changeset(changeset) do
    changeset
    |> validate_required([:account_id, :name, :slug, :title, :definition])
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_-]{0,79}$/)
    |> unique_constraint([:account_id, :slug, :version])
  end
end
```

- All `cast`/`validate_*`/`unique_constraint` live here.
- No `Repo.*` calls. Changesets are pure.
- One function per state transition (`create`, `update`, `delete`, `publish`, …). A private `changeset/1` carries the shared validations. Don't overload a single `changeset/2`.
- Cast field lists live in module attributes (`@fields`, or `@create_fields`/`@update_fields` when they diverge), never inline in the `cast/3` call. Inline a list only when a module has so many divergent field sets that named attrs would be noise.
- **No `DateTime.truncate` timestamp helpers.** Every datetime column is `:utc_datetime_usec` and `DateTime.utc_now/0` is already microsecond-precision, so `DateTime.truncate(:microsecond)` is a no-op — write `deleted_at: DateTime.utc_now()` directly; no `defp now` wrapper. (If you ever need a coarser column, that's the exception that gets a why-comment.)

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

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Runbook.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
```

- Permissions are built with **`build(Schema, :verb)`** and exposed via per-permission accessor functions (`view_runbooks_permission/0`) so callers never construct a permission inline.
- Roles in this codebase: `:owner`, `:admin`, `:operator`, `:viewer`, `:api_client`, `:runner` — each authorizer clauses the ones it grants, with a `_ -> []` catch-all for the rest.
- The four **membership** roles (`:owner`/`:admin`/`:operator`/`:viewer`) are defined once in `Emisar.Auth.Role` — the single source for the `Membership` `Ecto.Enum`, the rank/`at_least?` hierarchy, and the team UI's role list. Never re-list them in a schema, changeset, or LiveView.
- **Authorize by permission, not role name.** A context must never branch on `subject.role` to gate an action (`subject.role != :owner` is a smell) — add a permission (e.g. `manage_owners_permission`, held by owners only) and check `Auth.Authorizer.has_permission?/2`. Comparing a *data* role value (`target.role == :owner`) is fine; gating the *actor's* capability by role name is not.
- `for_subject/2` is the **row-scoping** authorizer — it composes onto whatever query the context built. Use the Query module helpers; do not write raw `where` here. Keep the account-scoped clause and the `_` fallback (plus any actor-specific clause, e.g. the runner-only scoping in `Runs.Authorizer`).
- **Background/system-side reads take an explicit `account_id`, not a forged subject.** There is no `:system` god-subject. A read with no user in scope (an Oban sweeper, the approval fan-out, a dispatch-payload enrichment) is a named internal function that scopes via `Schema.Query.by_account_id/2` directly — e.g. `Accounts.list_account_memberships/2` and `Catalog.fetch_action_for_account/3`. This is the IL-1.4 internal-helper pattern; it's why removing `:system` couldn't reintroduce the cross-account fan-out leak.
- `Emisar.Auth.Authorizer.permissions_for/1` unions every per-context Authorizer's role list — that union builds the `%Subject{}.permissions` MapSet.

### 6. Web layer

- LiveView mount + handle_params **assigns the Subject once** via `on_mount(:require_authenticated_user)` (already wired in `UserAuth`).
- Every context call uses `socket.assigns.current_subject` — never re-derive role inside the LV. (IL-15: still re-check permission semantics in each `handle_event` — the context call does this for you when you pass the subject.)
- **"Can this subject do X?" is a domain question.** Each context exposes `subject_can_<verb>?(%Subject{})` predicates (e.g. `Billing.subject_can_manage_billing?/1`, `Runs.subject_can_dispatch_run?/1`) — one-liners over `Auth.Authorizer.has_permission?/2`. The web calls them directly: templates do `:if={Runs.subject_can_dispatch_run?(@current_subject)}`, handlers wrap them in `EmisarWeb.Permissions.gated(socket, <predicate>, fun)` (a thin flash-on-denial helper, no authz of its own). The web never maps a UI action to a permission and never branches on `current_role` / `current_membership.role` for authorization (`role == :owner ->` is the smell); rendering the role *label* is fine.
- **Forms are a web concern.** A context exposes plain `change_*(struct, attrs)` changeset builders (the Phoenix convention — `change_user`, `change_account`, `change_password`); it never has a `*_form` function or a changeset doc'd "for the LiveView form." The form *orchestration* — `to_form`, `phx-change`, `Map.put(:action, :validate)`, rendering inline field errors — lives in the LiveView, built on top of those `change_*` builders.
- `EmisarWeb.LiveTable` is stateless and URL-driven. Use `LiveTable.params_to_opts(params, Query.filters())` to translate URL params into `[filter:, page:]` for `Repo.list/3`.
- Reach for `EmisarWeb.CoreComponents` before writing markup; reach for `stream/3` before assigning a list (IL-18). **One shared component per UI shape — never hand-roll a card / chip / banner / empty-state / page-width, and pick the right stat-trio member (`stat` tile vs `summary_band` strip vs `meta_strip`).** Worked map: `.agent/rules/ui-shared-components.md`.
- **The visual language — tokens, type, brand/logo, components, the marketing↔console register split, and the plan to bring the console into line with the redesigned marketing site — lives in `.agent/rules/design-system.md` ("The Gate"). Read it before any visual change to `emisar_web` (marketing or console).** The one accent is the emerald `brand` scale; semantic pass/pending/deny = brand/amber/rose; calm console, expressive marketing.
- Controllers / channels / MCP follow the same pattern: build a `%Subject{}` via `Subject.for_user/4`, `Subject.for_api_key/3`, or `Subject.for_runner/3` at the auth boundary, then pass it through. The marketing site (`controllers/marketing_html/`) is the only unauthenticated, server-rendered surface — keep it that way for SEO (see `/seo-marketing`).

### 7. Tests

- `use Emisar.DataCase, async: true` — sandboxed concurrent runs. Anything that spawns DB-touching processes must inherit `$callers` or be made synchronous in test env (see `notify_approvers_async?` config flag).
- Fixtures build a real Subject when one is needed: `subject_for(user, account)` or `owner_subject_fixture/1` in `test/support/fixtures.ex`.
- **Fixtures and tests never depend on a context function that exists only for them.** Build rows the fixture way (`Schema.Changeset.fun() |> Repo.insert`) or via the real Subject-gated API; put test-only inspectors in `test/support`, not the production context. A `defp` used by an internal flow stays private — don't promote it to public just so a test can reach it. Fixture code leaking into a context's public namespace is a smell.
- Regression tests drive the domain API that failed, not database catalog introspection. For a migration/backstop, prove the relevant context operation succeeds or rejects correctly (`Runs.dispatch_run/2`, `Approvals.create_request/3`, etc.); only inspect schema catalogs when no meaningful domain path exists.
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

Two layers — mechanical rules run by machines, judgment rules by review:

1. **Credo is the single mechanical source of truth.** The Iron-Law and
   house-rule checks are custom AST checks in `credo/checks/`
   (`Emisar.Checks.*`), wired into `.credo.exs` alongside the stock checks
   (including `UnsafeToAtom` for IL-14 and `StrictModuleLayout` for the
   directive order). Run it twice — there is no hook doing this for you:
   - **after every edit** — when you change a portal `.ex`/`.exs`, run
     `mix credo <file>` from `portal/` (~0.6s) before moving on, and fix
     every finding immediately. Editing without re-checking is how the
     same violations recurred for weeks.
   - **at the gate** — the full `mix credo` is part of the IL-20 verify
     loop and must report zero before any commit.

   Covered mechanically: IL-1, IL-2, IL-6, IL-7, IL-8, IL-12 (schemas AND
   migrations), IL-13 (perform-head args), IL-14, plus the house rules —
   with/case/for-head pipes, preloads smuggled into Repo opts,
   cross-context deep aliases (path-aware), capture syntax for
   single-call closures, clause heads over if-on-arg-field, `q`/`cs`
   bindings, per-event broadcast functions (inline `PubSub.broadcast` AND
   event-strings-as-data), `Repo.exists?` over count-compares, the
   `Emisar.Crypto` boundary, `DateTime.truncate` no-ops, no
   `Process.sleep` in tests, the audit request-metadata
   `%RequestContext{}` rule (no `Process.put` ambient state in `lib/`),
   the multi-line `, do:` block-form rule (`MultilineDoColon`), the
   module-header directive order, and its no-blank-between-directives
   contiguity (`NoBlankBetweenDirectives`). Plus the **layer boundaries**:
   the web layer never calls `Repo`, builds a context `<Schema>.Changeset`,
   or writes audit (`Audit.log*` / `Audit.Events.*`); one context never
   reaches another's `.Query`/`.Changeset` (the call-site companion to the
   deep-alias check); and IL-3's subject rule — a `Repo`-touching public
   context fn takes a `%Subject{}` unless it's `@doc "Internal …"` (an
   already-authorized helper) or threads a `%RequestContext{}` (a pre-auth
   path).

   A documented exception gets `# credo:disable-for-next-line
   Emisar.Checks.<Name>` (or `-for-lines:<n>`) directly under its
   why-comment — never a bare disable. Current sanctioned disables: the
   runner socket's directed `deliver_to_runner` publish, and the two
   long-poll tests' writer-side delay injections.

2. **`/iron-review`** carries the judgment laws a static check can't
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

Then run the [verify loop](#how-we-build-prime-directive) (IL-20).
