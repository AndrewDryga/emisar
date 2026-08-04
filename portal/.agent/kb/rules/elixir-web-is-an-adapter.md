---
name: elixir-web-is-an-adapter
description: EmisarWeb calls top-level contexts only — no nested domain modules, no changeset construction; carriers and Auth.Subject are the named exceptions
subsystem: portal
sources: [portal/credo/checks/web_no_nested_domain_calls.ex, portal/credo/checks/web_no_changeset_construction.ex, portal/apps/emisar/test/emisar/web_boundary_checks_test.exs]
updated: 2026-08-04
---

# Rule: the web is an adapter — top-level contexts only

**Rule.** Every call `apps/emisar_web` makes into the domain lands on a
**top-level context module** — `Emisar.Catalog`, `Emisar.Accounts`,
`Emisar.Runbooks`, `Emisar.Mail`, `Emisar.Runs`. It never calls a module
*below* one (`Catalog.PublishedRegistry`, `Accounts.RunnerAccess`,
`Accounts.Membership`, `Runbooks.Authoring`, `Runbooks.Naming`,
`Mail.DeliverabilityEvent`, `Runs.RunnerError`, any `<Schema>.Query` or
`<Schema>.Changeset`), and it never **builds or mutates** an
`Ecto.Changeset`. When the web needs one of those behaviours, the owning
context grows a facade function and the web calls that.

## Why — the abuse case

A nested module is a context's internal, so a call to one is domain behaviour
executing **outside the authorization boundary**, where no context test and no
`%Subject{}` gate covers it. The failure is quiet and cumulative:

- `Ecto.Changeset.add_error/4` in `OnboardingLive` was real domain validation —
  "a name whose derived slug is rejected must say so on `:name`" — living in a
  LiveView. Nothing in `Emisar.Accounts`' test suite could hold that rule, and
  the next caller of `create_account_with_owner/2` (MCP, an importer, a
  seeding script) silently inherited the broken behaviour the LiveView had
  patched over.
- Once the web reaches one level down, the next reach is cheap. A page that
  already calls `Catalog.PublishedRegistry.list/0` will just as easily call
  `PackVersion.Query.trusted/0` — and that one leaks other tenants' rows,
  because `Authorizer.for_subject/2` only runs inside the context.
- A context can never refactor its internals while the adapter names them.
  Renaming `PublishedRegistry.get/1` becomes a cross-app change instead of a
  local one.

## Allowed — web concerns

- Calling any public context function, including a pure facade that just
  delegates (`Catalog.get_published_pack/1`, `Accounts.build_runner_access/3`).
- **Form orchestration** on top of the context's `change_*/2` builders:
  `Phoenix.Component.to_form/2`, `phx-change`/`phx-submit` wiring,
  `EmisarWeb.LiveForm.on_change/1`, marking the submit action
  (`Map.put(changeset, :action, :insert)` or a struct update), and rendering
  inline field errors.
- **Read-only** changeset inspection, written as a QUALIFIED call
  (`Ecto.Changeset.get_field/2`): `changed?`, `fetch_change`, `fetch_field`,
  `fetch_field!`, `get_assoc`, `get_change`, `get_embed`, `get_field`,
  `traverse_errors`. `import Ecto.Changeset` is banned even for these — the
  bare `cast(attrs, [:name])` it also opens up is indistinguishable from a
  local call, so the import is the one bypass no AST check can see.
- Reading a Query module's UI metadata through the context's own accessor
  (`Runs.run_filters/0`), never the Query module itself.

## Domain-owned — move it into the context

- Deriving a value the domain owns (a slug from a title, a canonical v1
  definition from editor input, a bounded error envelope from a socket frame).
- Adding, casting, changing, validating, or constraining a changeset —
  `add_error`, `cast`, `change`, `put_change`, `validate_*`, `*_constraint`,
  `apply_action`, `apply_changes`.
- Deciding what a provider payload means, what access a selection grants, or
  whether a row counts as disabled.

Give the facade a name that says what the CALLER wants
(`Accounts.create_account_with_owner_from_name/2`,
`Runbooks.build_definition_v1/1`), not the internal it forwards to.

## Carrier exceptions — data, not behaviour

These are exactly three, and nothing else joins the list without a rule change:

1. **Remote `t/0` type references, in type position only** —
   `@spec f(Catalog.PublishedRegistry.Pack.t())`, and the same inside `@type`,
   `@typep`, or `@opaque`. Anywhere else `Pack.t()` is an ordinary runtime call
   into a nested module and is flagged like any other, capture (`&Pack.t/0`)
   included.
2. **Struct literals and patterns** — `%Accounts.RunnerAccess{mode: :none}` in a
   function head or a `:if`. They carry a shape, they run no domain code.
3. **`Emisar.Auth.Subject`** — the universal auth carrier. The web
   authentication boundary is where a Subject is *minted*
   (`Subject.for_user/4`, `for_api_key/3`, `for_runner/3`), so it may call it
   fully qualified or aliased.

`EmisarWeb.*` is the web's own namespace and is never matched.

## ✅ Good

```elixir
# apps/emisar_web/lib/emisar_web/live/onboarding_live.ex
case Accounts.create_account_with_owner_from_name(name, user) do
  {:ok, account} -> ...
  {:error, %Ecto.Changeset{data: %Accounts.Account{}} = changeset} ->
    {:noreply, assign_form(socket, changeset)}
end
```

```elixir
# apps/emisar/lib/emisar/accounts.ex — the rule lives with the domain that owns it
def create_account_with_owner_from_name(name, %Users.User{} = user) do
  case create_account_with_owner(%{name: name, slug: suggest_unique_slug(name)}, user) do
    {:ok, account} -> {:ok, account}
    {:error, %Ecto.Changeset{data: %Account{}} = changeset} ->
      {:error, surface_slug_error_on_name(changeset)}
    {:error, reason} -> {:error, reason}
  end
end
```

## ❌ Bad

```elixir
# The adapter deriving the slug AND patching the domain's changeset.
case Accounts.create_account_with_owner(%{name: name, slug: Accounts.suggest_unique_slug(name)}, user) do
  {:error, changeset} -> assign_form(socket, surface_slug_error_on_name(changeset))
end

defp surface_slug_error_on_name(changeset) do
  Ecto.Changeset.add_error(changeset, :name, message, opts)
end
```

```elixir
# The adapter reaching past the context for data and behaviour.
packs = Catalog.PublishedRegistry.list()
{:ok, access} = Accounts.RunnerAccess.from_selection(mode, values, runners)
definition = Runbooks.Authoring.build_v1(command)
```

## Sweep

Over `apps/emisar_web/lib` only:

- `rg -n 'Emisar\.[A-Z][A-Za-z]*\.[A-Z]'` and any `<Context>.<Nested>.fun(`
  through a top-level alias — every hit is either a violation or one of the
  three carriers above.
- `rg -n 'Ecto\.Changeset\.'` — anything outside the read-only list.
- `rg -n '^\s*import Ecto\.Changeset'` — banned outright; there is none today
  and none should appear.

## How it's enforced

Two Credo checks, both scoped to `apps/emisar_web/lib/`:

- `Emisar.Checks.WebNoNestedDomainCalls` — resolves fully qualified calls,
  top-level-context aliases, deep aliases (including `as:`), and grouped
  aliases, then rejects any behavioural call through `Emisar.<Top>.<Nested…>`.
  A function capture is such a call; `t/0` is exempt only inside a `@spec` /
  `@type` / `@typep` / `@opaque`, recorded by exact AST position rather than
  exempting the name everywhere or skipping the rest of the type attribute.
- `Emisar.Checks.WebNoChangesetConstruction` — fails closed on every
  `Ecto.Changeset` remote call except the read-only inspection list, and flags
  `import Ecto.Changeset` in every form (`only:`/`except:` included), since a
  bare imported `cast/3` leaves no remote call to see.

Both also read the body of a literal `~H` sigil. HEEx keeps that body as a
**string** in the AST, so `{Catalog.PublishedRegistry.list()}` in a template
reaches no call node — the template is the one place the boundary could
otherwise be crossed unseen. Alias resolution there matches ordinary code, and
the issue lands on the template line that carries the call.

`Emisar.WebBoundaryChecksTest` parses probe sources and runs both checks
directly, so an AST regression in either fails the suite rather than quietly
letting the boundary reopen.
