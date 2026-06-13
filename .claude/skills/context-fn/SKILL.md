---
name: context-fn
description: Add one read or write function to an existing Emisar context the canonical way — correct Repo.* call, Subject placement, Authorizer wiring, tagged return, and its denial test. Use when adding a query/fetch/list/create/update/delete/action function to a context in portal/apps/emisar.
effort: medium
argument-hint: "<Context>.<function>  e.g.  Runbooks.archive_runbook"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Add a context function (the standard shape)

Pick the shape by what the function does, then follow it exactly. Full rules:
`portal/AGENTS.md` §1. Read the target context first and **match its existing
functions** — consistency over preference.

Every public function, no exceptions: `%Subject{}` is the **last required
positional arg** (IL-3) → `Auth.Authorizer.ensure_has_permissions/2` before any
DB touch → `Authorizer.for_subject` immediately before the `Repo` call (IL-4) →
**tagged tuple** out, never a bare struct/`nil` (IL-5).

## Choose the shape

### Read one row
```elixir
def fetch_<thing>_by_id(id, %Subject{} = subject, opts \\ []) do
  with :ok <- Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_<ctx>_permission()),
       true <- Repo.valid_uuid?(id) do
    <Schema>.Query.not_deleted()
    |> <Schema>.Query.by_id(id)
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(<Schema>.Query, opts)
  else
    false -> {:error, :not_found}   # only if you guard the uuid
  end
end
```
`Repo.fetch/3` → `{:ok, row} | {:error, :not_found}`. Need a new `by_*`
predicate? Add it to the **Query module**, never inline (IL-1).

### Read a list (paginated/filtered)
```elixir
def list_<things>(%Subject{} = subject, opts \\ []) do
  with :ok <- Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_<ctx>_permission()) do
    <Schema>.Query.not_deleted()
    |> <Schema>.Query.ordered_by_...()
    |> Authorizer.for_subject(subject)
    |> Repo.list(<Schema>.Query, opts)
  end
end
```
`Repo.list/3` → `{:ok, rows, %Metadata{}}`. LiveTable passes `opts` from
`LiveTable.params_to_opts/2`.

### Create
```elixir
def create_<thing>(attrs, %Subject{} = subject) do
  with :ok <- Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_<ctx>_permission()) do
    attrs
    |> <Schema>.Changeset.create(subject.account.id, subject.actor.id, ...)  # match the changeset's arity
    |> Repo.insert()
  end
end
```

### Update / delete (locked, atomic — the standard mutation)
```elixir
def archive_<thing>(id, %Subject{} = subject) do
  with :ok <- Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_<ctx>_permission()) do
    <Schema>.Query.not_deleted()
    |> <Schema>.Query.by_id(id)
    |> Authorizer.for_subject(subject)
    |> Repo.fetch_and_update(<Schema>.Query,
         with: &<Schema>.Changeset.archive/1,
         after_commit: &broadcast_event(:archived, &1))   # broadcasts/audit go here, post-commit
  end
end
```
`fetch_and_update/3` locks `FOR NO KEY UPDATE`, runs the changeset, and fires
`:after_commit` only on success. Use `:audit` to insert an audit row in the same
transaction. Need a new transition? Add `archive/1` to the **Changeset** module
(IL-8), don't build the changeset inline.

### Internal / worker / socket helper (no Subject)
Only for code already inside an authenticated process (runner socket, Oban
sweeper, scheduler). Take `account_id`/`actor_id`, name it obviously
(`dispatch_runbook/4`), `@doc "Internal …"`, never expose to web/MCP (§1.4).

## Permissions

Reuse the context's existing `view_<ctx>_permission/0` / `manage_<ctx>_permission/0`.
A genuinely new capability → add a `build(<Schema>, :verb)` accessor + grant it in
`list_permissions_for_role/1` (IL-9). Use `{:one_of, [a, b]}` when either of two
permissions suffices (see `Policies.fetch_policy_by_id`).

## Finish

1. Add the **denial test** (wrong role → `{:error, :unauthorized}`) and, for
   reads, the **cross-account** test (`{:error, :not_found}`). A write without a
   denial test isn't done (§7).
2. `cd portal && mix compile --warnings-as-errors && mix format && mix test <file>` (IL-20).
3. Sanity grep / `/iron-review` if you touched queries.
