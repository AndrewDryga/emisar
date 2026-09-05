# Portal — agent instructions

Read the [root manual](../AGENTS.md) and this file before editing Portal.
The control plane uses layered contexts; authorization belongs at that boundary.
For concrete production examples, inspect Runbooks and Policies. Use the fictional
Widgets templates in the reference to learn the shape without copying incidental
production complexity.

Emisar.Users owns cross-account identity and self-service through the Subject actor.
Emisar.Accounts owns tenancy, memberships, invitations, permission semantics, and audit.

## Required reading by task

Search the [Portal rule index](.agent/kb/rules/README.md) for the feature and code
shape you are touching. Read matching entries and linked rules. Search the
[shared rule index](../.agent/kb/rules/README.md) for cross-project requirements.
Neither index is an instruction to load every rule or sweep unrelated code.

## Iron Laws (non-negotiable)

Numbered so Credo, `/elixir-iron-review`, and code review can cite them. **Architecture laws (IL-1…IL-11)** are the layered-context shape — the part the user repeats most. **Phoenix-safety laws (IL-12…IL-19)** are the generally-applicable Elixir/Phoenix guardrails. **IL-20** is process. Read the linked reference section before changing that layer.

### Architecture laws (the layered-context shape)

| # | Law | Why | Detect |
|---|-----|-----|--------|
| **IL-1** | **No `Ecto.Query` / `from`/`where`/`order_by`/`join`/`select`/`preload`/`limit`/`lock` in `lib/emisar/<context>.ex` or context-owned `jobs/*.ex`.** Every queryable starts at `Schema.Query.fun()`. | The Query module is the single place a table's shape is defined; inline DSL forks it. | `import Ecto.Query` outside `*/query.ex`, `*/repo*`; bare `from(`/`where(` in a context/job. → [§1](.agent/kb/rules/elixir-layered-contexts.md#1-context-modules) |
| **IL-2** | **Never `Repo.get` / `get!` / `get_by`.** | They bypass the Query module and its row-scoping entirely. | `\bRepo\.(get|get!|get_by)\b` anywhere in `lib/emisar`. → [§1](.agent/kb/rules/elixir-layered-contexts.md#1-context-modules) |
| **IL-3** | **`%Auth.Subject{}` is the last required positional arg of every public read and write,** and `Auth.Authorizer.ensure_has_permissions/2` runs before any DB touch. | The context is the authorization boundary. No subject = no gate. | Public context fn with no `%Subject{}` param, or DB call before the permission check. → [§1.2](.agent/kb/rules/elixir-layered-contexts.md#12-auth-subject-flows-through-every-public-read--write) |
| **IL-4** | **`Authorizer.for_subject(query, subject)` sits immediately before `Repo.fetch` / `list` / `fetch_and_update`.** | Second gate: it scopes rows to the subject's account. Skipping it leaks cross-account data. | `Repo.fetch`/`list` in a context with no `for_subject` directly above. → [§1.2](.agent/kb/rules/elixir-layered-contexts.md#12-auth-subject-flows-through-every-public-read--write) |
| **IL-5** | **Tagged tuples only.** Reads: `{:ok, row}` / `{:error, :not_found \| :unauthorized}`. Lists: `{:ok, rows, %Metadata{}}`. Writes: `{:ok, struct}` / `{:error, %Changeset{} \| :unauthorized \| :not_found}`. Never a bare struct or `nil`. | Callers pattern-match one shape. A bare struct or `nil` breaks every `with`. | Public context fn returning a struct/`nil` directly. → [§1.3](.agent/kb/rules/elixir-layered-contexts.md#13-return-shapes) |
| **IL-6** | **Query modules: `use Emisar, :query`, composable helpers (`(queryable) -> queryable`, first arg defaults to `all()`), named bindings (`as: :runbooks`), zero `Repo.*`.** | Composability + named bindings keep helpers safe to chain in any order. | `import Ecto.Query` instead of `use Emisar, :query`; positional bindings; `Repo.` in a query module. → [§2](.agent/kb/rules/elixir-layered-contexts.md#2-query-modules) |
| **IL-7** | **Schema modules are fields + associations only.** No changeset, no business logic. | A schema is a data shape. Logic in it can't be tested or reused in isolation. | `def create`/`cast`/`validate_` in a `*.ex` schema file. → [§3](.agent/kb/rules/elixir-layered-contexts.md#3-schema-modules) |
| **IL-8** | **Changeset modules are pure** — `use Emisar, :changeset`, no `Repo.*`, one function per state transition (`create`, `update`, `delete`, `publish`…). | Pure changesets are unit-testable and composable into `Multi`. One overloaded `changeset/2` hides transitions. | `Repo.` in a `*/changeset.ex`; a single `changeset/2` doing everything. → [§4](.agent/kb/rules/elixir-layered-contexts.md#4-changeset-modules) |
| **IL-9** | **Authorizers define permissions via `build(Schema, :verb)` exposed through accessor fns.** | One union of these role lists builds every `%Subject{}.permissions`. Reaching past the accessor desyncs them. | Raw permission tuples at call sites. → [§5](.agent/kb/rules/elixir-layered-contexts.md#5-authorizer-modules) |
| **IL-10** | **`:preload` routes through the Query module's `preloads/0`; never `Repo.preload/2` in a context's Subject-gated reads.** | Keeps preload shapes defined in one place per query. (Exception: an *internal* — no-Subject, already-authorized — path that holds a struct and needs its parent assoc uses `Repo.preload(struct, :assoc)` rather than a cross-context `fetch_*_by_id!`: post-commit email helpers, the runner-register billing check.) | `Repo.preload(` inside a Subject-gated read in `lib/emisar/<context>.ex`. → [§1.4](.agent/kb/rules/elixir-layered-contexts.md#14-internal-sweepers--job-only-helpers) |
| **IL-11** | **Greenfield. No legacy — for CODE.** Delete deprecated code and update every caller in the same change; no shims/flags/"this is the new version" comments. **A migration that ran in production is the exception: never edit or delete it; add a NEW migration. A confirmed-unrun migration stays greenfield.** | For code, every compatibility layer is debt for behavior nobody depends on yet. But prod runs applied migrations exactly once, so editing one never re-applies — prod's schema silently drifts from the code. | A `_v2`/`_old` or a one-value flag in code; editing or deleting a migration known to have run. → [§8](.agent/kb/rules/elixir-layered-contexts.md#8-greenfield-no-legacy) |

> **The migration boundary is whether production ran it.** Git history is not deployment history because production applies are manual. Confirmed-unrun migrations should be corrected in place; `.agent/kb/rules/elixir-migrations-frozen.md` explains the rule.

### Phoenix-safety laws

| # | Law | Why | Detect |
|---|-----|-----|--------|
| **IL-12** | **Never `:float` for money.** Use `:decimal` or `:integer` (cents). | Floats lose cents. Billing is real money (Paddle). | `field :amount, :float`, `add :price, :float` (money-ish names). |
| **IL-13** | **Recurrent jobs are idempotent and derive work from durable rows, never scheduler memory.** | A tick can repeat after restarts, failover, or crashes. Durable rows plus idempotent transitions make repeats safe. | Job `execute/1` that depends on in-memory cursor state or performs a non-idempotent side effect. |
| **IL-14** | **No `String.to_atom/1` on user/runner/LLM input.** Use `String.to_existing_atom/1` or a whitelist map. | Atom table never GCs → DoS. emisar takes input from runners and LLMs. | `String.to_atom(` outside tests. |
| **IL-15** | **Authorize in EVERY LiveView `handle_event` and EVERY MCP/controller action** — don't trust mount/connect. | `mount` auth doesn't cover later events; a crafted event can act beyond the rendered UI. | A `handle_event`/MCP action mutating state with no `ensure_has_permissions`/subject check. |
| **IL-16** | **Never `raw/1` (or `Phoenix.HTML.raw`) with untrusted content.** | Stored XSS — runner output, runbook text, and pack metadata are attacker-influenced. | `raw(` with a variable (not a literal/`~s`). |
| **IL-17** | **Supervise all long-lived processes.** No bare `GenServer.start_link`/`Agent.start_link` in app code — put them under a supervisor. | Unsupervised processes leak and don't restart. | `GenServer.start_link`/`Agent.start_link` outside a `child_spec`/`start_link`/supervision tree. |
| **IL-18** | **LiveView discipline:** `assign_async` (or `connected?/1` + cached branch) — no unconditional DB query in `mount` (it runs twice); **streams** for lists that can exceed ~100 rows; `connected?/1` guard before any PubSub `subscribe`; never `assign_new` for per-mount values (`current_user`, locale). | Doubles DB load, blows up socket memory, double-subscribes, or serves stale per-mount state. | `Repo`/context read in `mount` with no `connected?`/`assign_async`; collection `assign` with no `stream`; `subscribe` with no `connected?` guard. |
| **IL-19** | **Wrap third-party library APIs behind a project-owned module.** (Paddle, mailer, MCP transport…) | One seam to swap, stub in tests, and rate-limit. Vendor calls scattered across contexts can't be mocked or replaced. | A vendor module (`Paddle.`, raw HTTP client) called directly from a context/LiveView. |

### Process law

| # | Law | Why | Detect |
|---|-----|-----|--------|
| **IL-20** | **Verify before claiming done.** Run `./run gate portal` and show output. If you can't run it, say so explicitly. | "Should work" has burned us. Generated code that doesn't pass cleanly — including warning/error/log-free test output — doesn't get committed. | A "done" claim with no command output in the transcript. |


## Reference — module by module

Read each relevant section in [elixir-layered-contexts.md](.agent/kb/rules/elixir-layered-contexts.md)
before editing that layer. Section numbers remain stable for source comments and skills.

### 1. Context modules

[§1 and §1.1](.agent/kb/rules/elixir-layered-contexts.md#1-context-modules) cover
Query-built reads, mutation composition, return contracts, and soft-delete defaults.

#### 1.2 Subject and authorization

[§1.2](.agent/kb/rules/elixir-layered-contexts.md#12-auth-subject-flows-through-every-public-read--write)
covers permission, entity ownership, account scope, self-service, and internal exceptions.

#### 1.3 Return shapes

[§1.3](.agent/kb/rules/elixir-layered-contexts.md#13-return-shapes) defines tagged reads and writes.

#### 1.4 Internal helpers

[§1.4](.agent/kb/rules/elixir-layered-contexts.md#14-internal-sweepers--job-only-helpers)
defines already-authenticated internal paths, explicit account scope, and preload exceptions.

### 2. Query modules

[§2](.agent/kb/rules/elixir-layered-contexts.md#2-query-modules) owns composable queries,
bindings, joins, preloads, filters, and the fail-closed `none/1` helper.

### 3. Schema modules

[§3](.agent/kb/rules/elixir-layered-contexts.md#3-schema-modules) covers enums, associations,
soft-delete filtering, and case-insensitive natural keys.

### 4. Changeset modules

[§4](.agent/kb/rules/elixir-layered-contexts.md#4-changeset-modules) covers pure,
transition-specific validation and field whitelists.

### 5. Authorizer modules

[§5](.agent/kb/rules/elixir-layered-contexts.md#5-authorizer-modules) covers permission
accessors, row scope, and fail-closed fallbacks.

### 6. Web layer

[§6](.agent/kb/rules/elixir-layered-contexts.md#6-web-layer) covers context-only adapters,
forms, per-event authorization, LiveTable, shared components, and accessible states.
Before visual changes, read [design-system.md](.agent/kb/rules/design-system.md).
Operator UI uses the UX/frontend skills; public marketing work uses the content
and creative-direction skills as relevant to the request.

### 7. Tests

[§7](.agent/kb/rules/elixir-layered-contexts.md#7-tests) owns fixture and ExUnit conventions.
Changed context behavior needs happy, denial, and cross-account coverage. Keep
tests proportional to the behavior; preserve concurrency and failure evidence.

### 8. Migrations

[§8](.agent/kb/rules/elixir-layered-contexts.md#8-greenfield-no-legacy) and
[elixir-migrations-frozen.md](.agent/kb/rules/elixir-migrations-frozen.md) own the
production-applied boundary. Confirm deployment state before editing an existing
migration; a merged commit alone is not evidence.

## Verification

Use focused `./run test portal <path or selector>` checks and focused Credo after
coherent edits. Finish with `./run gate portal` from the root. It includes
compile, formatting, Credo, audits, Sobelow, tests, and the test-output guard.
Fix failures without suppressing warning/error output or weakening checks.
Never pipe a check through head/tail and lose its exit status.

The [enforcement reference](.agent/kb/rules/elixir-layered-contexts.md#enforcement)
routes Elixir AST rules to Credo and appropriate template checks to
EmisarWeb.TemplateHygieneTest. Read it before changing a checker.

A Coop box already receives its database through Compose and PGHOST/PGPORT.
If it is unavailable, diagnose the existing sidecar; do not install a second
Postgres. See [box isolation](../.agent/kb/coop-box-builds-are-isolated.md).
Contributor skills live in ../.claude/skills/ and follow the root scope and
verification rules.
