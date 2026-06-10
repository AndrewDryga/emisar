defmodule Emisar.Audit.Multi do
  @moduledoc """
  `Ecto.Multi` helpers for inserting audit-log rows inside a parent
  transaction. Use these in place of `Emisar.Audit.log/3` whenever
  the audit row must commit together with a parent state transition —
  otherwise a downstream constraint failure or rollback can leave the
  audit row orphaned (or vice versa, a state change without an audit
  trail).

  Pair with `Emisar.Repo.commit_multi/2` so any `after_commit:`
  callback (PubSub broadcasts, emails, session-kill broadcasts) only
  fires once the DB actually commits.
  """
  alias Ecto.Multi
  alias Emisar.Audit
  alias Emisar.Users.User

  @doc """
  Adds an `Audit.Event` insert step to `multi`. `attrs_fn` receives
  the multi's current `changes` map so the audit row can reference
  freshly-inserted rows by their auto-generated ids:

      Multi.new()
      |> Multi.update(:policy, changeset)
      |> Audit.Multi.log(:audit, fn %{policy: p} ->
        {p.account_id, "policy.updated",
         actor_id: subject.actor.id, subject_id: p.id, payload: %{...}}
      end)
      |> Repo.commit_multi()

  `attrs_fn` returns either:
    * `{account_id, event_type, attrs_keyword}` — the common case
    * `nil` — skip the audit step (e.g. when a downstream condition
      means there's nothing to log)
  """
  def log(multi, name, attrs_fn) when is_function(attrs_fn, 1) do
    Multi.run(multi, name, fn _repo, changes ->
      case attrs_fn.(changes) do
        nil ->
          {:ok, nil}

        {account_id, event_type, attrs} ->
          Audit.changeset(account_id, event_type, attrs) |> Emisar.Repo.insert()
      end
    end)
  end

  @doc """
  Adds an audit step that logs an event for a `%User{}`, looking up
  the user's primary membership to derive `account_id` — the same
  shape as `Audit.log_for_user/3` but transactional.

  `user` may be `nil` when the user is only known mid-transaction (an
  earlier step resolved it) — then `:user_fn` is required.

  Options:

    * `:payload_fn` — `(changes -> map)` to compute the payload from
      the multi's changes (default: `nil` → no payload)
    * `:extra` — keyword of additional audit attrs (override defaults)
    * `:user_fn` — `(changes -> %User{} | nil)` if the user is a
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

    Multi.run(multi, name, fn _repo, changes ->
      case user_fn.(changes) do
        %User{} = resolved_user ->
          attrs = extra |> maybe_put_payload(payload_fn, changes) |> Map.new()

          case Audit.user_changeset(resolved_user, event_type, attrs) do
            %Ecto.Changeset{} = changeset -> Emisar.Repo.insert(changeset)
            nil -> {:ok, nil}
          end

        nil ->
          {:ok, nil}
      end
    end)
  end

  defp default_user_fn(%User{} = user), do: fn _ -> user end

  defp default_user_fn(nil),
    do: raise(ArgumentError, "log_for_user/5 needs a %User{} or a :user_fn resolving one")

  defp maybe_put_payload(attrs, nil, _changes), do: attrs

  defp maybe_put_payload(attrs, payload_fn, changes) when is_function(payload_fn, 1) do
    case payload_fn.(changes) do
      nil -> attrs
      payload -> Keyword.put(attrs, :payload, payload)
    end
  end
end
