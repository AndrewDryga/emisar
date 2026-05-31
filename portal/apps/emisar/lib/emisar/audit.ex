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
      |> Map.take([:ip_address, :user_agent, :request_id])
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    Process.put(@meta_key, cleaned)
    :ok
  end

  @doc "Returns the current process's audit request metadata (or %{} if unset)."
  def get_request_metadata, do: Process.get(@meta_key, %{})

  @doc "Wipes any audit metadata set for the current process."
  def clear_request_metadata, do: Process.delete(@meta_key)

  # -- Recording (internal helper called by sibling contexts) ----------

  @doc """
  Append an audit event. Called by sibling contexts inside their
  already-authorized mutation paths — `actor_kind` / `actor_id` are
  derived from the caller's `%Subject{}`.
  """
  def log(account_id, event_type, attrs \\ %{}) do
    base = %{
      account_id: account_id,
      event_type: to_string(event_type),
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    # base < process metadata < explicit attrs.
    merged =
      base
      |> Map.merge(get_request_metadata())
      |> Map.merge(normalize(attrs))

    Event.Changeset.create(merged)
    |> Repo.insert()
  end

  @doc """
  Convenience: log a state-transition event for an ActionRun. Called
  by `Runs.transition/3` so every run state change leaves a trace.
  """
  def log_run_event(%ActionRun{} = run) do
    log(run.account_id, "action_run.#{run.status}",
      subject_kind: "action_run",
      subject_id: run.id,
      subject_label: run.action_id,
      actor_kind: actor_kind(run),
      actor_id: run.requested_by_id || run.api_key_id,
      payload:
        compact(%{
          request_id: run.request_id,
          runner_id: run.runner_id,
          runbook_id: run.runbook_id,
          exit_code: run.exit_code,
          duration_ms: run.duration_ms,
          reason: run.reason_text
        })
    )
  end

  # Drop nil-valued keys so audit rows for pending/sent runs don't
  # bloat with fields that are still being filled in.
  defp compact(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)

  defp actor_kind(%ActionRun{requested_by_id: id}) when not is_nil(id), do: "user"
  defp actor_kind(%ActionRun{api_key_id: id}) when not is_nil(id), do: "api_key"
  defp actor_kind(%ActionRun{source: "runbook"}), do: "runbook"
  defp actor_kind(%ActionRun{source: "scheduled"}), do: "scheduler"
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

  # -- Reads (Subject-gated) -------------------------------------------

  @doc """
  Paginated + filterable list for the Audit page. Returns
  `{:ok, [event], %Paginator.Metadata{}} | {:error, ...}`. Honors
  `Emisar.Repo.list/3` options (`:filter`, `:page`, `:preload`).
  """
  def list_events(%Subject{} = subject, opts \\ []) do
    with :ok <- Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()) do
      Event.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Event.Query, opts)
    end
  end

  @doc """
  Fetch a single event scoped to the subject's account. Returns
  `{:ok, event} | {:error, :not_found}`.
  """
  def fetch_event_by_id(id, %Subject{} = subject) do
    with :ok <- Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()),
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
  """
  def resolve_references(events) when is_list(events) do
    ids_by_kind =
      events
      |> Enum.flat_map(fn ev ->
        [{ev.actor_kind, ev.actor_id}, {ev.subject_kind, ev.subject_id}]
      end)
      |> Enum.reject(fn {_, id} -> is_nil(id) end)
      |> Enum.uniq()
      |> Enum.group_by(fn {kind, _} -> kind end, fn {_, id} -> id end)

    %{
      "user" => fetch_labels(Emisar.Accounts.User.Query, ids_by_kind, "user", :email),
      "runner" => fetch_labels(Emisar.Runners.Runner.Query, ids_by_kind, "runner", :name),
      "api_key" => fetch_labels(Emisar.ApiKeys.ApiKey.Query, ids_by_kind, "api_key", :name),
      "auth_key" =>
        fetch_labels(Emisar.Runners.AuthKey.Query, ids_by_kind, "auth_key", :description),
      "action_run" =>
        fetch_labels(Emisar.Runs.ActionRun.Query, ids_by_kind, "action_run", :action_id),
      "approval_request" =>
        fetch_labels(Emisar.Approvals.Request.Query, ids_by_kind, "approval_request", :id)
    }
  end

  defp fetch_labels(query_module, ids_by_kind, kind, field) do
    case Map.get(ids_by_kind, kind, []) do
      [] ->
        %{}

      ids ->
        query_module.all()
        |> query_module.select_labels(ids, field)
        |> Repo.all()
        |> Map.new()
    end
  end
end
