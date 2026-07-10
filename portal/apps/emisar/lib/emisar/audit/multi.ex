defmodule Emisar.Audit.Multi do
  @moduledoc """
  `Ecto.Multi` helper for inserting a user-scoped audit-log row inside a
  parent transaction. Use it in place of `Emisar.Audit.log_for_user/3`
  whenever the audit row must commit together with a parent state
  transition — otherwise a downstream constraint failure or rollback can
  leave the audit row orphaned (or vice versa, a state change without an
  audit trail).

  Pair with `Emisar.Repo.commit_multi/2` so any `after_commit:`
  callback (PubSub broadcasts, emails, session-kill broadcasts) only
  fires once the DB actually commits.
  """
  alias Ecto.Multi
  alias Emisar.Audit
  alias Emisar.Users

  @doc """
  Adds an audit step that logs an event for a `%Users.User{}`, looking up
  the user's primary membership to derive `account_id` — the same
  shape as `Audit.log_for_user/3` but transactional.

  `user` may be `nil` when the user is only known mid-transaction (an
  earlier step resolved it) — then `:user_fn` is required.

  Options:

    * `:payload_fn` — `(changes -> map)` to compute the payload from
      the multi's changes (default: `nil` → no payload)
    * `:extra` — keyword of additional audit attrs (override defaults)
    * `:user_fn` — `(changes -> %Users.User{} | nil)` if the user is a
      multi-step result rather than a captured variable (defaults to
      the passed user struct). Returning `nil` skips the audit step —
      for events conditional on an earlier step's outcome (e.g. "only
      log when rows were actually revoked").

  Silently no-ops if the user has no active membership — matching the
  semantics of `Audit.log_for_user/3`.
  """
  def log_for_user(multi, name, user, event_type, opts \\ []) do
    payload_fn = Keyword.get(opts, :payload_fn)
    extra = Keyword.get(opts, :extra, [])
    user_fn = Keyword.get(opts, :user_fn) || default_user_fn(user)

    Multi.run(multi, name, fn repo, changes ->
      case user_fn.(changes) do
        %Users.User{} = resolved_user ->
          attrs = extra |> maybe_put_payload(payload_fn, changes) |> Map.new()
          resolved_user |> Audit.user_changesets(event_type, attrs) |> insert_each(repo)

        nil ->
          {:ok, nil}
      end
    end)
  end

  # One row per active membership, inserted in the parent transaction so they
  # commit atomically with the mutation; the events flow to `changes[name]` and
  # `commit_multi` broadcasts each. A deliberate per-row insert (N = the user's
  # membership count). `[]` (no membership) → {:ok, []}, the skip.
  defp insert_each(changesets, repo) do
    Enum.reduce_while(changesets, {:ok, []}, fn changeset, {:ok, acc} ->
      case repo.insert(changeset) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp default_user_fn(%Users.User{} = user), do: fn _ -> user end

  defp default_user_fn(nil),
    do: raise(ArgumentError, "log_for_user/5 needs a %Users.User{} or a :user_fn resolving one")

  defp maybe_put_payload(attrs, nil, _changes), do: attrs

  defp maybe_put_payload(attrs, payload_fn, changes) when is_function(payload_fn, 1) do
    case payload_fn.(changes) do
      nil -> attrs
      payload -> Keyword.put(attrs, :payload, payload)
    end
  end
end
