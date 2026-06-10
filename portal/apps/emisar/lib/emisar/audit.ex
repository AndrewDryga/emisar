defmodule Emisar.Audit do
  @moduledoc """
  System-of-record audit log. Append-only; queryable by time, type,
  actor, subject. Distinct from `Runs.RunEvent` (progress chunks for
  one run) — `Audit.Event` is the human-facing "what happened?" log.

  ## Public read API

  Every read takes an `%Auth.Subject{}`. The Authorizer scopes the
  queryable to events the caller's account is allowed to see and gates
  on `view_audit_permission`.

  ## Write API

  `log/3` is an internal helper called from sibling contexts that have
  already authorized the parent action. It accepts `actor_kind`,
  `actor_id`, etc. as data rather than a subject because the caller
  already has the subject in hand and can derive those fields.

  ## Request metadata

  IP, user agent, and request id are cross-cutting context that the
  business contexts have no conn-level visibility into. To avoid
  threading a conn through every audited operation, callers near the
  edge stash this metadata in the current process dictionary via
  `put_request_metadata/1`. `log/3` reads from there and merges into
  the event row. Explicit `:ip_address` / `:user_agent` / `:request_id`
  keys in the `attrs` map always win over the process dict.
  """
  alias Emisar.{Auth, Repo}
  alias Emisar.Audit.{Authorizer, Event}
  alias Emisar.Auth.Subject
  alias Emisar.Runs.ActionRun

  @meta_key :emisar_audit_request_metadata

  # -- Request metadata (process-dict cross-cutting context) -----------

  @doc """
  Stash `{ip_address, user_agent, request_id}` in the current process so
  subsequent `Audit.log/3` calls pick them up without each caller having
  to thread them through. Pass `nil` values to clear.
  """
  def put_request_metadata(%{} = meta) do
    cleaned =
      meta
      |> Map.take([:ip_address, :user_agent, :request_id, :mcp_session_id])
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    Process.put(@meta_key, cleaned)
    :ok
  end

  @doc """
  Returns the audit request metadata visible to the current process. Looks
  in the local dict first, then walks `$callers` (the chain Task and
  Task.Supervisor stamp so spawned tasks inherit context). The first
  non-empty entry wins, matching how Logger / Phoenix propagate metadata
  across async fan-outs.
  """
  def get_request_metadata do
    case Process.get(@meta_key) do
      %{} = local when map_size(local) > 0 ->
        local

      _ ->
        # Tasks spawned via Task / Task.Supervisor inherit the parent's
        # pid in `:"$callers"` — newest first. Walk it until we find a
        # caller that has audit metadata set, otherwise return %{}.
        walk_caller_metadata(Process.get(:"$callers", []))
    end
  end

  defp walk_caller_metadata([]), do: %{}

  defp walk_caller_metadata([pid | rest]) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, @meta_key) do
          %{} = meta when map_size(meta) > 0 -> meta
          _ -> walk_caller_metadata(rest)
        end

      # Caller exited between spawn and lookup — skip and try the next.
      _ ->
        walk_caller_metadata(rest)
    end
  end

  @doc "Wipes any audit metadata set for the current process."
  def clear_request_metadata, do: Process.delete(@meta_key)

  # -- Recording (internal helper called by sibling contexts) ----------

  @doc """
  Append an audit event. Called by sibling contexts inside their
  already-authorized mutation paths — `actor_kind` / `actor_id` are
  derived from the caller's `%Subject{}`.

  Use `changeset/3` instead when the audit row needs to commit
  atomically with a parent mutation (an `Ecto.Multi.insert/3` step).
  `log/3` is for fire-and-forget standalone events that have no parent
  transaction — sign-out, failed sign-in, runner heartbeat, etc.
  """
  def log(account_id, event_type, attrs \\ %{}) do
    Repo.insert(changeset(account_id, event_type, attrs))
  end

  @doc """
  Build the audit-event changeset without inserting it — the low-level
  primitive the `Audit.Events` per-event builders sit on. Context
  mutations never call this directly: they go through an
  `Audit.Events.<event>/n` builder inside their `Multi` so the row
  commits or rolls back with the parent mutation and the actor fields
  derive from the `%Subject{}`:

      Multi.new()
      |> Multi.update(:policy, changeset)
      |> Multi.insert(:audit, fn %{policy: updated} ->
        Audit.Events.policy_updated(subject, updated)
      end)
      |> Repo.commit_multi()

  Field merge order is identical to `log/3`: base < process metadata
  < explicit attrs.
  """
  def changeset(account_id, event_type, attrs \\ %{}) do
    base = %{
      account_id: account_id,
      event_type: to_string(event_type),
      occurred_at: DateTime.utc_now()
    }

    merged =
      base
      |> Map.merge(get_request_metadata())
      |> Map.merge(normalize(attrs))

    Event.Changeset.create(merged)
  end

  @doc """
  Audit-log a user-scoped security event (sign-in, MFA, password
  change, profile edit). The user might not have a direct `account_id`
  in hand — most auth flows operate pre-Subject — so we look up the
  user's primary membership and stamp the event onto that account.

  Multi-account users only get the event on their primary membership
  in v0.1; widening to fan-out across every membership is a future
  call once we see whether it's needed.

  Silently no-ops when the user has no active membership (brand-new
  signup mid-account-creation, fully-suspended user) — the parent
  action either already audited, or there's no admin yet who could
  read it.

  `attrs` accepts the same shape as `log/3` and overrides the defaults
  (`actor_kind: "user", actor_id: user.id, subject_kind: "user",
   subject_id: user.id, subject_label: user.email`).
  """
  def log_for_user(%Emisar.Users.User{} = user, event_type, attrs \\ %{}) do
    case user_changeset(user, event_type, attrs) do
      %Ecto.Changeset{} = changeset -> Repo.insert(changeset)
      nil -> :ok
    end
  end

  @doc """
  Audit-event changeset for a user-scoped event, with the user's primary
  membership resolved to `account_id`. Build-only (no insert) so it
  composes into a parent transaction — `Repo.fetch_and_update`'s `:audit`
  and the `Audit.Multi` helpers insert it atomically with the mutation.
  Returns `nil` (treated as "skip") when the user has no active membership.
  Same defaults + override semantics as `log_for_user/3`.
  """
  def user_changeset(%Emisar.Users.User{} = user, event_type, attrs \\ %{}) do
    case Emisar.Accounts.fetch_membership_for_session(user, nil) do
      {:ok, membership} ->
        defaults = %{
          actor_kind: "user",
          actor_id: user.id,
          subject_kind: "user",
          subject_id: user.id,
          subject_label: user.email
        }

        changeset(membership.account_id, event_type, Map.merge(defaults, normalize(attrs)))

      {:error, :not_found} ->
        nil
    end
  end

  @doc """
  Build the audit-event changeset for a run state transition. Use
  inside an `Ecto.Multi` so the audit row commits together with the
  parent `run` update — see `Runs.transition/3`.
  """
  def run_event_changeset(%ActionRun{} = run) do
    changeset(run.account_id, "action_run.#{run.status}",
      subject_kind: "action_run",
      subject_id: run.id,
      subject_label: run.action_id,
      actor_kind: actor_kind(run),
      actor_id: run.requested_by_id || run.api_key_id,
      # Authoritative for the run's own events, including the terminal ones
      # logged from the runner-socket process (no request metadata there).
      # request_id is the action-dispatch id (req_…) — the meaningful
      # "request" for a run — promoted to a first-class field instead of
      # being buried in (and duplicated by) the payload.
      request_id: run.request_id,
      mcp_session_id: run.mcp_session_id,
      payload:
        compact(%{
          runner_id: run.runner_id,
          runbook_id: run.runbook_id,
          exit_code: run.exit_code,
          duration_ms: run.duration_ms,
          executed_command: run.executed_command,
          reason: run.reason_text
        })
    )
  end

  # Drop nil-valued keys so audit rows for pending/sent runs don't
  # bloat with fields that are still being filled in.
  defp compact(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)

  defp actor_kind(%ActionRun{requested_by_id: id}) when not is_nil(id), do: "user"
  defp actor_kind(%ActionRun{api_key_id: id}) when not is_nil(id), do: "api_key"
  defp actor_kind(%ActionRun{source: :runbook}), do: "runbook"
  defp actor_kind(%ActionRun{source: :scheduled}), do: "scheduler"
  defp actor_kind(_), do: "system"

  # Internal helper — `log/3` accepts both atom and string keys to match
  # the loose Phoenix-form / API-payload shape callers happen to have.
  # `String.to_existing_atom/1` blows up loudly if a caller invents a
  # field name; sibling contexts only ever pass keys the Event
  # changeset already declares.
  defp normalize(attrs) do
    Enum.into(attrs, %{}, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  end

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account-wide audit fan-out (`{:audit_event, event}` per row)."
  def subscribe_account_audit(account_id),
    do: Emisar.PubSub.subscribe(account_audit_topic(account_id))

  defp account_audit_topic(account_id), do: "account:#{account_id}:audit"

  @doc """
  Internal — `Repo.commit_multi` auto-fans every committed `Audit.Event`
  to the account-wide audit topic, so AuditLive stays current without
  each context having to remember to broadcast.
  """
  def broadcast_event(%Event{} = event),
    do: Emisar.PubSub.broadcast(account_audit_topic(event.account_id), {:audit_event, event})

  # -- Reads (Subject-gated) -------------------------------------------

  @doc """
  Paginated + filterable list for the Audit page. Returns
  `{:ok, [event], %Paginator.Metadata{}} | {:error, ...}`. Honors
  `Emisar.Repo.list/3` options (`:filter`, `:page`, `:preload`).
  """
  def list_events(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()) do
      Event.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Event.Query, opts)
    end
  end

  @doc """
  SIEM export — cursor-paginated forward sweep of every event the
  subject can see, sorted ascending by `(occurred_at, id)`. This is the
  deterministic shape SIEMs need: they checkpoint the last `(occurred_at,
  id)` they've ingested and ask for everything strictly after.

  Why a separate function from `list_events/2`:

    * Forward (oldest-first) ordering — SIEMs replay history once then
      poll forward; the LV's reverse order would force them to discover
      new rows by binary-searching the timeline.
    * Hard upper bound on the page size — keeps an aggressive consumer
      from issuing a billion-row scan that would page the audit table
      out of buffer pool.
    * No `%Paginator.Metadata{}` count round-trip — SIEM ingestors don't
      need totals and computing them on every poll kills the index.

  Options:

    * `:since` — `%DateTime{}` lower bound for the first page (inclusive)
    * `:after` — `{%DateTime{}, id}` cursor (strict `>`), takes precedence
      over `:since`
    * `:event_types` — list of event_type strings to include (empty list
      = all types)
    * `:limit` — page size, default #{100}, hard-capped at #{1_000}

  Returns `{:ok, events}` — a plain list of `%Audit.Event{}` rows in
  ascending order. The controller projects to NDJSON; the context just
  hands back rows.
  """
  @default_export_limit 100
  @max_export_limit 1_000

  def list_for_export(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()) do
      types = Keyword.get(opts, :event_types, [])
      limit = clamp_export_limit(Keyword.get(opts, :limit, @default_export_limit))

      events =
        Event.Query.all()
        |> apply_export_cursor(opts)
        |> Event.Query.by_event_types(types)
        |> Event.Query.ordered_for_export()
        |> Event.Query.limit_to(limit)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, events}
    end
  end

  @doc "Public — the controller uses this to ack-clamp a user-supplied `limit` param."
  def max_export_limit, do: @max_export_limit
  @doc "Public — the controller uses this for the default page size."
  def default_export_limit, do: @default_export_limit

  defp clamp_export_limit(n) when is_integer(n) and n > 0,
    do: min(n, @max_export_limit)

  defp clamp_export_limit(_), do: @default_export_limit

  defp apply_export_cursor(query, opts) do
    case Keyword.get(opts, :after) do
      {%DateTime{} = ts, id} when is_binary(id) ->
        Event.Query.occurred_strictly_after(query, ts, id)

      _ ->
        case Keyword.get(opts, :since) do
          %DateTime{} = ts -> Event.Query.occurred_at_or_after(query, ts)
          _ -> query
        end
    end
  end

  @doc """
  Fetch a single event scoped to the subject's account. Returns
  `{:ok, event} | {:error, :not_found}`.
  """
  def fetch_event_by_id(id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()),
         true <- Repo.valid_uuid?(id) do
      Event.Query.all()
      |> Event.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Event.Query)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Bulk-resolves the labels for every actor + subject referenced by the
  given events. Returns a nested map: `%{kind => %{id => label}}`. The
  ids are trusted (they were stamped on the audit row at write time
  inside an already-authorized parent transaction); we only project
  display labels.

  Both call sites pass an already-account-scoped, single-account event
  list (one page of the audit log, or one event). Label lookups are
  therefore additionally scoped to that account: a mis-stamped id can't
  resolve a name/email belonging to another account (defense-in-depth).
  Correctly-scoped ids are unaffected. Mixed-account input degrades to
  the first account's scope rather than leaking, but isn't a supported
  shape.
  """
  def resolve_references(events) when is_list(events) do
    account_id = events |> Enum.map(& &1.account_id) |> List.first()

    ids_by_kind =
      events
      |> Enum.flat_map(fn ev ->
        [{ev.actor_kind, ev.actor_id}, {ev.subject_kind, ev.subject_id}]
      end)
      |> Enum.reject(fn {_, id} -> is_nil(id) end)
      |> Enum.uniq()
      |> Enum.group_by(fn {kind, _} -> kind end, fn {_, id} -> id end)

    %{
      # Users belong to accounts via memberships, not a column, so they
      # scope through the membership join rather than `by_account_id`.
      "user" =>
        fetch_labels(Emisar.Users.User.Query, ids_by_kind, "user", :email, fn q ->
          Emisar.Users.User.Query.members_of_account(q, account_id)
        end),
      "runner" =>
        fetch_labels(Emisar.Runners.Runner.Query, ids_by_kind, "runner", :name, fn q ->
          Emisar.Runners.Runner.Query.by_account_id(q, account_id)
        end),
      "api_key" =>
        fetch_labels(Emisar.ApiKeys.ApiKey.Query, ids_by_kind, "api_key", :name, fn q ->
          Emisar.ApiKeys.ApiKey.Query.by_account_id(q, account_id)
        end),
      "auth_key" =>
        fetch_labels(Emisar.Runners.AuthKey.Query, ids_by_kind, "auth_key", :description, fn q ->
          Emisar.Runners.AuthKey.Query.by_account_id(q, account_id)
        end),
      "action_run" =>
        fetch_labels(Emisar.Runs.ActionRun.Query, ids_by_kind, "action_run", :action_id, fn q ->
          Emisar.Runs.ActionRun.Query.by_account_id(q, account_id)
        end),
      "approval_request" =>
        fetch_labels(Emisar.Approvals.Request.Query, ids_by_kind, "approval_request", :id, fn q ->
          Emisar.Approvals.Request.Query.by_account_id(q, account_id)
        end),
      "runbook" =>
        fetch_labels(Emisar.Runbooks.Runbook.Query, ids_by_kind, "runbook", :title, fn q ->
          Emisar.Runbooks.Runbook.Query.by_account_id(q, account_id)
        end)
    }
  end

  defp fetch_labels(query_module, ids_by_kind, kind, field, scope) do
    case Map.get(ids_by_kind, kind, []) do
      [] ->
        %{}

      ids ->
        query_module.all()
        |> scope.()
        |> query_module.select_labels(ids, field)
        |> Repo.all()
        |> Map.new()
    end
  end
end
