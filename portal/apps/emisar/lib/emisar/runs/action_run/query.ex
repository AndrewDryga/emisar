defmodule Emisar.Runs.ActionRun.Query do
  use Emisar, :query
  alias Emisar.{ApiKeys, Runners, Users}
  alias Emisar.Repo.{Filter, Like}

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

  def by_runbook_id(queryable, runbook_id),
    do: where(queryable, [runs: r], r.runbook_id == ^runbook_id)

  def status_in(queryable, statuses),
    do: where(queryable, [runs: r], r.status in ^statuses)

  def inserted_after(queryable, %DateTime{} = ts),
    do: where(queryable, [runs: r], r.inserted_at >= ^ts)

  def queued_before(queryable, %DateTime{} = ts),
    do: where(queryable, [runs: r], r.queued_at < ^ts)

  @doc """
  Id-only projection of runs that reached a terminal state before `ts`.
  Built for use as a subquery by `RunEvent.Query.by_run_finished_before/2`
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

  @doc """
  One-row aggregate for the dashboard stats: total runs plus the per-outcome
  splits, counted with SQL FILTER so the context does no app-side summing. The
  caller owns which statuses count as a failure; `:denied`/`:cancelled` are
  counted separately (policy/operator outcomes, not run results), and in-flight
  runs are the remainder (`total - success - failed - denied - cancelled`).
  """
  def outcome_totals(queryable, failed_statuses) do
    select(queryable, [runs: r], %{
      total: count(r.id),
      success: filter(count(r.id), r.status == ^:success),
      failed: filter(count(r.id), r.status in ^failed_statuses),
      denied: filter(count(r.id), r.status == ^:denied),
      cancelled: filter(count(r.id), r.status == ^:cancelled)
    })
  end

  @doc "Left-join + preload the run's (non-deleted) runner, idempotently."
  def with_preloaded_runner(queryable) do
    queryable
    |> with_named_binding(:runner, fn queryable, binding ->
      join(
        queryable,
        :left,
        [runs: r],
        runner in ^Runners.Runner.Query.not_deleted(),
        on: r.runner_id == runner.id,
        as: ^binding
      )
    end)
    |> preload([runner: runner], runner: runner)
  end

  @doc """
  Left-join + preload the run's (non-deleted) API key, idempotently — with the
  key's creator, so an MCP run can name its accountable human ("by
  jordan@… via Claude Code").
  """
  def with_preloaded_api_key(queryable) do
    queryable
    |> with_named_binding(:api_key, fn queryable, binding ->
      join(
        queryable,
        :left,
        [runs: r],
        api_key in ^ApiKeys.ApiKey.Query.not_deleted(),
        on: r.api_key_id == api_key.id,
        as: ^binding
      )
    end)
    |> preload([api_key: api_key], api_key: {api_key, :created_by})
  end

  @doc "Left-join + preload the run's (non-deleted) requesting user, idempotently."
  def with_preloaded_requested_by(queryable) do
    queryable
    |> with_named_binding(:requested_by, fn queryable, binding ->
      join(
        queryable,
        :left,
        [runs: r],
        requested_by in ^Users.User.Query.not_deleted(),
        on: r.requested_by_id == requested_by.id,
        as: ^binding
      )
    end)
    |> preload([requested_by: requested_by], requested_by: requested_by)
  end

  @doc """
  Row lock for the state-transition re-read (`FOR NO KEY UPDATE`, the
  same mode the repo's fetch-and-update path takes), so concurrent
  finishers — runner result vs. operator cancel vs. timeout sweep —
  serialize instead of clobbering a terminal status.
  """
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

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

  # Both targets are soft-delete schemas — scope each preload to
  # `not_deleted()` so the filter is explicit at the preload site, not
  # just on the association's `:where`.
  @impl Emisar.Repo.Query
  def preloads,
    do: [
      runner: {Runners.Runner.Query.not_deleted(), Runners.Runner.Query.preloads()},
      api_key: {ApiKeys.ApiKey.Query.not_deleted(), ApiKeys.ApiKey.Query.preloads()}
    ]

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
          {"denied", "Denied"},
          {"sent", "Sent"},
          {"running", "Running"},
          {"success", "Success"},
          {"failed", "Failed"},
          {"error", "Error"},
          {"validation_failed", "Validation failed"},
          {"unknown_action", "Unknown action"},
          {"cancelled", "Cancelled"},
          {"timed_out", "Timed out"},
          {"refused", "Refused"}
        ],
        fun: fn queryable, statuses -> {queryable, dynamic([runs: r], r.status in ^statuses)} end
      },
      %Filter{
        name: :action_id,
        title: "Action",
        type: :string,
        # Substring search: typing "postgres" matches "postgres.vacuum"
        # and "postgres.uptime". Anchored to action_id only; doesn't
        # leak across to other columns. ILIKE for case-insensitive
        # match — most operators don't bother shift-keying.
        fun: fn queryable, action ->
          {queryable, dynamic([runs: r], ilike(r.action_id, ^Like.contains(action)))}
        end
      },
      # A searchable single-select of the account's runners — independent of
      # the dispatched-by pair (`?runner_id=…` deep-links from a runner's
      # "View all runs").
      %Filter{
        name: :runner_id,
        title: "Runner",
        type: :string,
        search: true,
        values: [],
        fun: fn queryable, runner_id ->
          {queryable, dynamic([runs: r], r.runner_id == ^runner_id)}
        end
      },
      # "Dispatched by" — the run's origin kind. Picking one reveals a WHO
      # picker beside it (the audit actor-kind grammar): LLM agent → Agent,
      # Operator → team member, Runbook → runbook. :row_start so the revealed
      # child pairs in the cell beside it under a :stacked layout.
      %Filter{
        name: :source,
        title: "Dispatched by",
        type: {:list, :string},
        span: :row_start,
        values: [
          {"operator", "Operator"},
          {"mcp", "LLM agent"},
          {"runbook", "Runbook"},
          {"scheduled", "Scheduled"}
        ],
        fun: fn queryable, sources -> {queryable, dynamic([runs: r], r.source in ^sources)} end
      },
      # The three "who exactly" children — searchable single-selects whose
      # options are per-account, so the LiveView fills them in at render and
      # shows each only while its kind is picked (or its own value is set —
      # a deep link like `?api_key_id=…` from an agent's "View activity" must
      # apply AND stay visible, never narrow the list from a hidden control).
      # Declared here regardless: Repo.Filter resolves :filter names against
      # this list, so an undeclared filter could never apply at all.
      %Filter{
        name: :api_key_id,
        title: "Agent",
        type: :string,
        search: true,
        values: [],
        fun: fn queryable, api_key_id ->
          {queryable, dynamic([runs: r], r.api_key_id == ^api_key_id)}
        end
      },
      %Filter{
        name: :requested_by_id,
        title: "Operator",
        type: :string,
        search: true,
        values: [],
        fun: fn queryable, user_id ->
          {queryable, dynamic([runs: r], r.requested_by_id == ^user_id)}
        end
      },
      %Filter{
        name: :runbook_id,
        title: "Runbook",
        type: :string,
        search: true,
        values: [],
        fun: fn queryable, runbook_id ->
          {queryable, dynamic([runs: r], r.runbook_id == ^runbook_id)}
        end
      }
    ]

  @doc """
  Distinct `{user_id, name-or-email}` of the runs' dispatching operators —
  options for the runs page's Operator picker. Compose with `for_subject/2`.
  """
  def operator_options(queryable \\ all()) do
    queryable
    |> join(:inner, [runs: r], u in assoc(r, :requested_by), as: :requested_by)
    |> distinct(true)
    |> select([requested_by: u], {u.id, coalesce(u.full_name, u.email)})
  end

  @doc """
  Distinct `{runbook_id, title}` of the runs' runbooks — options for the runs
  page's Runbook picker. Compose with `for_subject/2`.
  """
  def runbook_options(queryable \\ all()) do
    queryable
    |> join(:inner, [runs: r], b in assoc(r, :runbook), as: :runbook)
    |> distinct(true)
    |> select([runbook: b], {b.id, b.title})
  end
end
