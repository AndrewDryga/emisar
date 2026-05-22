defmodule Emisar.Audit do
  @moduledoc """
  System-of-record audit log. Append-only; queryable by time, type,
  actor, subject. Distinct from `Runs.RunEvent` (progress chunks for
  one run) — `Audit.Event` is the human-facing "what happened?" log.
  """

  import Ecto.Query
  alias Emisar.Repo
  alias Emisar.Audit.Event
  alias Emisar.Runs.ActionRun

  # -- Recording --------------------------------------------------------

  def log(account_id, event_type, attrs \\ %{}) do
    base = %{
      account_id: account_id,
      event_type: to_string(event_type),
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    %Event{}
    |> Event.changeset(Map.merge(base, normalize(attrs)))
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
      payload: %{
        request_id: run.request_id,
        runner_id: run.runner_id,
        runbook_id: run.runbook_id,
        exit_code: run.exit_code,
        duration_ms: run.duration_ms,
        reason: run.reason_text
      }
    )
  end

  defp actor_kind(%ActionRun{requested_by_id: id}) when not is_nil(id), do: "user"
  defp actor_kind(%ActionRun{api_key_id: id}) when not is_nil(id), do: "api_key"
  defp actor_kind(%ActionRun{source: "runbook"}), do: "runbook"
  defp actor_kind(%ActionRun{source: "scheduled"}), do: "scheduler"
  defp actor_kind(_), do: "system"

  defp normalize(attrs) do
    Enum.into(attrs, %{}, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
    end)
  end

  # -- Querying ---------------------------------------------------------

  def list_events_for_account(account_id, opts \\ []) do
    query =
      from e in Event,
        where: e.account_id == ^account_id,
        order_by: [desc: e.occurred_at]

    query =
      query
      |> maybe(opts[:event_type], fn q, v -> where(q, [e], e.event_type == ^v) end)
      |> maybe(opts[:subject_kind], fn q, v -> where(q, [e], e.subject_kind == ^v) end)
      |> maybe(opts[:subject_id], fn q, v -> where(q, [e], e.subject_id == ^v) end)
      |> maybe(opts[:actor_kind], fn q, v -> where(q, [e], e.actor_kind == ^v) end)
      |> maybe(opts[:after], fn q, v -> where(q, [e], e.occurred_at > ^v) end)
      |> maybe(opts[:before], fn q, v -> where(q, [e], e.occurred_at < ^v) end)
      |> limit(^(opts[:limit] || 100))

    Repo.all(query)
  end

  defp maybe(q, nil, _), do: q
  defp maybe(q, v, fun), do: fun.(q, v)
end
