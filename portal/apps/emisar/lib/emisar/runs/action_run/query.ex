defmodule Emisar.Runs.ActionRun.Query do
  use Emisar, :query
  alias Emisar.Repo.Filter

  def all,
    do: from(runs in Emisar.Runs.ActionRun, as: :runs)

  def by_id(queryable, id),
    do: where(queryable, [runs: r], r.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [runs: r], r.account_id == ^account_id)

  def by_runner_id(queryable, runner_id),
    do: where(queryable, [runs: r], r.runner_id == ^runner_id)

  def by_request_id(queryable, request_id),
    do: where(queryable, [runs: r], r.request_id == ^request_id)

  def by_api_key_id(queryable, api_key_id),
    do: where(queryable, [runs: r], r.api_key_id == ^api_key_id)

  def by_idempotency_key(queryable, key),
    do: where(queryable, [runs: r], r.idempotency_key == ^key)

  def by_runbook_execution_id(queryable, execution_id),
    do: where(queryable, [runs: r], r.runbook_execution_id == ^execution_id)

  def by_status(queryable, status),
    do: where(queryable, [runs: r], r.status == ^status)

  def status_in(queryable, statuses),
    do: where(queryable, [runs: r], r.status in ^statuses)

  def inserted_after(queryable, %DateTime{} = ts),
    do: where(queryable, [runs: r], r.inserted_at >= ^ts)

  def queued_before(queryable, %DateTime{} = ts),
    do: where(queryable, [runs: r], r.queued_at < ^ts)

  @doc """
  Id-only projection of runs that reached a terminal state before `ts`.
  Built for use as a subquery by `RunEvent.Query.with_run_finished_before/2`
  (the action-run-event retention sweep) — `finished_at` is the
  authoritative "this run is old" signal, so still-running / never-
  finished runs (null `finished_at`) are excluded.
  """
  def finished_before_ids(queryable \\ all(), %DateTime{} = ts) do
    queryable
    |> where([runs: r], not is_nil(r.finished_at) and r.finished_at < ^ts)
    |> select([runs: r], r.id)
  end

  def by_action_id(queryable, action_id),
    do: where(queryable, [runs: r], r.action_id == ^action_id)

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [runs: r], desc: r.inserted_at)

  def ordered_by_oldest(queryable \\ all()),
    do: order_by(queryable, [runs: r], asc: r.inserted_at)

  def limit_to(queryable, n), do: limit(queryable, ^n)

  @doc "Audit label-lookup helper. See Users.User.Query.select_labels/3."
  def select_labels(queryable, ids, field) do
    queryable
    |> where([runs: r], r.id in ^ids)
    |> select([runs: r], {r.id, field(r, ^field)})
  end

  # -- Pagination / filters --------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runs, :desc, :inserted_at}, {:runs, :asc, :id}]

  @impl Emisar.Repo.Query
  def preloads,
    do: [runner: [], api_key: []]

  @impl Emisar.Repo.Query
  def filters,
    do: [
      %Filter{
        name: :status,
        title: "Status",
        type: {:list, :string},
        values: [
          {"pending", "Pending"},
          {"pending_approval", "Pending approval"},
          {"sent", "Sent"},
          {"running", "Running"},
          {"success", "Success"},
          {"failed", "Failed"},
          {"error", "Error"},
          {"cancelled", "Cancelled"},
          {"timed_out", "Timed out"}
        ],
        fun: fn q, statuses -> {q, dynamic([runs: r], r.status in ^statuses)} end
      },
      %Filter{
        name: :action_id,
        title: "Action",
        type: :string,
        # Substring search: typing "postgres" matches "postgres.vacuum"
        # and "postgres.uptime". Anchored to action_id only; doesn't
        # leak across to other columns. ILIKE for case-insensitive
        # match — most operators don't bother shift-keying.
        fun: fn q, action ->
          pattern = "%" <> action <> "%"
          {q, dynamic([runs: r], ilike(r.action_id, ^pattern))}
        end
      },
      %Filter{
        name: :source,
        title: "Source",
        type: {:list, :string},
        values: [
          {"operator", "Operator"},
          {"mcp", "MCP / LLM"},
          {"runbook", "Runbook"}
        ],
        fun: fn q, sources -> {q, dynamic([runs: r], r.source in ^sources)} end
      }
    ]
end
