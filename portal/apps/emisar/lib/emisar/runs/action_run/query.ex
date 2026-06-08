defmodule Emisar.Runs.ActionRun.Query do
  use Emisar, :query

  alias Emisar.Repo.Filter

  def all,
    do: from(runs in Emisar.Runs.ActionRun, as: :runs)

  def by_id(q, id),
    do: where(q, [runs: r], r.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [runs: r], r.account_id == ^account_id)

  def by_runner_id(q, runner_id),
    do: where(q, [runs: r], r.runner_id == ^runner_id)

  def by_request_id(q, request_id),
    do: where(q, [runs: r], r.request_id == ^request_id)

  def by_api_key_id(q, api_key_id),
    do: where(q, [runs: r], r.api_key_id == ^api_key_id)

  def by_idempotency_key(q, key),
    do: where(q, [runs: r], r.idempotency_key == ^key)

  def by_status(q, status),
    do: where(q, [runs: r], r.status == ^status)

  def status_in(q, statuses),
    do: where(q, [runs: r], r.status in ^statuses)

  def inserted_after(q, %DateTime{} = ts),
    do: where(q, [runs: r], r.inserted_at >= ^ts)

  def queued_before(q, %DateTime{} = ts),
    do: where(q, [runs: r], r.queued_at < ^ts)

  def by_action_id(q, action_id),
    do: where(q, [runs: r], r.action_id == ^action_id)

  def ordered_by_recent(q \\ all()),
    do: order_by(q, [runs: r], desc: r.inserted_at)

  def limit_to(q, n), do: limit(q, ^n)

  @doc "Audit label-lookup helper. See Accounts.User.Query.select_labels/3."
  def select_labels(q, ids, field) do
    q
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
