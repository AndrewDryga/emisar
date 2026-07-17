defmodule Emisar.Runs do
  @moduledoc """
  Action run lifecycle. Cloud calls `dispatch_run/2` when an operator
  (or MCP, or a runbook step) wants to invoke an action; this module
  creates the run row, evaluates policy, hands the dispatch to the
  Transport for sending, and tracks progress + final result.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.{ApiKeys, Audit, Auth, Crypto, MCPOperations, Repo, RequestContext, Users}
  alias Emisar.Auth.Subject
  alias Emisar.Runs.{ActionRun, Authorizer, RunEvent}
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      job_module("DispatchTimeout"),
      job_module("EventRetention"),
      job_module("ActionRunRetention"),
      job_module("FleetObservability")
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  # -- Listing / queries ------------------------------------------------

  @doc """
  Paginated + filterable list for the Runs page. Returns
  `{:ok, [run], %Paginator.Metadata{}}` — see `Emisar.Repo.list/3`.
  Preloads the runner for each row so list templates can render names
  without N+1 queries.
  """
  def list_runs(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      # Runner/agent scoping arrives through the DECLARED filters —
      # Query.filters/0 carries :runner_id and :api_key_id, the deep-link
      # targets of "View all runs" / "View activity" — not side-channel opts.
      ActionRun.Query.all()
      |> apply_run_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, opts)
    end
  end

  @doc """
  `{:ok, [{user_id, name-or-email}]}` — the distinct operators who dispatched
  runs in the account, for the runs page's Operator picker (revealed by
  "Dispatched by"). `%Subject{}` needs `view_runs`.
  """
  def list_run_operator_options(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      options =
        ActionRun.Query.all()
        |> ActionRun.Query.operator_options()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, options}
    end
  end

  @doc """
  `{:ok, [{runbook_id, title}]}` — the distinct runbooks that dispatched runs
  in the account, for the runs page's Runbook picker (revealed by
  "Dispatched by"). `%Subject{}` needs `view_runs`.
  """
  def list_run_runbook_options(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      options =
        ActionRun.Query.all()
        |> ActionRun.Query.runbook_options()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, options}
    end
  end

  @doc """
  Paginated top-N most recent runs for the dashboard tile. Default
  page size is 8 — the dashboard renders a short fixed list, not a
  scrolling table. Returns `{:ok, [run], %Paginator.Metadata{}}` per
  the context-function convention.

  Options: `preload:` — associations the caller renders (`:runner`,
  `:api_key`); `limit:` — page size (default 8); `scope:` — `:account`
  (default) for the whole account's runs, or `:own` for just this API
  key's runs (the MCP `recent_runs` recall path).
  """
  def list_recent_runs(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      {preloads, opts} = Keyword.pop(opts, :preload, [])
      {scope, opts} = Keyword.pop(opts, :scope, :account)
      {runner_id, opts} = Keyword.pop(opts, :runner_id)
      {action_id, opts} = Keyword.pop(opts, :action_id)
      limit = Keyword.get(opts, :limit, 8)

      ActionRun.Query.all()
      |> apply_run_scope(scope, subject)
      |> maybe_by_runner_id(runner_id)
      |> maybe_by_action_id(action_id)
      |> apply_run_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, page: [limit: limit])
    end
  end

  @doc "Lists fixed-contract MCP history with lineage scope and keyset pagination."
  def list_recent_mcp_runs(filters, %Subject{} = subject, page_opts)
      when is_map(filters) and is_list(page_opts) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      ActionRun.Query.all()
      |> ActionRun.Query.fixed_mcp_contract()
      |> scope_fixed_mcp_runs_to_membership(subject)
      |> apply_mcp_history_scope(filters[:scope], subject)
      |> maybe_by_operation_id(filters[:operation_id])
      |> maybe_by_runbook_execution_id(filters[:runbook_execution_id])
      |> maybe_by_runbook_step_id(filters[:step_id])
      |> maybe_by_runner_ref(filters[:runner_ref])
      |> maybe_by_action_id(filters[:action_id])
      |> maybe_by_pack_ref(filters[:pack_ref])
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, page: page_opts, count: false)
    end
  end

  defp apply_mcp_history_scope(
         query,
         :own,
         %Subject{actor: %ApiKeys.ApiKey{credential_lineage_id: lineage_id}}
       ),
       do: ActionRun.Query.by_credential_lineage(query, lineage_id)

  defp apply_mcp_history_scope(query, :account, _subject), do: query
  defp apply_mcp_history_scope(query, _scope, _subject), do: ActionRun.Query.none(query)

  defp maybe_by_operation_id(query, nil), do: query
  defp maybe_by_operation_id(query, value), do: ActionRun.Query.by_operation_id(query, value)

  defp maybe_by_runbook_execution_id(query, nil), do: query

  defp maybe_by_runbook_execution_id(query, value),
    do: ActionRun.Query.by_runbook_execution_id(query, value)

  defp maybe_by_runbook_step_id(query, nil), do: query

  defp maybe_by_runbook_step_id(query, value),
    do: ActionRun.Query.by_runbook_step_id(query, value)

  defp maybe_by_runner_ref(query, nil), do: query
  defp maybe_by_runner_ref(query, value), do: ActionRun.Query.by_runner_ref(query, value)

  defp maybe_by_pack_ref(query, nil), do: query
  defp maybe_by_pack_ref(query, value), do: ActionRun.Query.by_pack_ref(query, value)

  defp maybe_by_runner_id(query, nil), do: query
  defp maybe_by_runner_id(query, runner_id), do: ActionRun.Query.by_runner_id(query, runner_id)

  defp maybe_by_action_id(query, nil), do: query
  defp maybe_by_action_id(query, action_id), do: ActionRun.Query.by_action_id(query, action_id)

  # Canonical run-outcome classification for the dashboard headline. A terminal
  # run is a SUCCESS, a FAILURE (attempted/refused and didn't succeed), or
  # neither — `:denied` (policy) and `:cancelled` (operator) are their own
  # outcomes, not run results. The success rate is successes over attempted
  # RESULTS (success + failure); denied / cancelled / in-flight are excluded.
  # `:denied`/`:cancelled` + this list together cover every terminal status
  # (see `ActionRun.terminal?/1`), so in-flight is the counted remainder.
  @failure_statuses [
    :failed,
    :error,
    :timed_out,
    :validation_failed,
    :unknown_action,
    :refused
  ]

  # Run statuses that earn an audit row. The transient lifecycle states —
  # pending, sent, running — stay off the security log (they're visible on the
  # run's own timeline: status + queued/sent/started timestamps + the event
  # stream); duplicating each just buried the signal under five-rows-per-run
  # noise. Audited as run events: every terminal result, the policy denial
  # (`:denied`), AND the approval gating (`:pending_approval`). The gating earns
  # a row because the `require_approval` policy decision no longer writes its own
  # `policy.evaluated` row (audit-logging diet #3) — so `action_run.pending_approval`
  # is the append-only record that a risky action was sent to the approval queue.
  @audited_run_statuses [
    :success,
    :failed,
    :error,
    :validation_failed,
    :unknown_action,
    :timed_out,
    :cancelled,
    :denied,
    :pending_approval,
    :refused
  ]
  @max_mcp_fanout 16

  @doc """
  Rolled-up totals for the dashboard headline: total runs in window, plus the
  canonical outcome split — successes, failures (the `@failure_statuses` set),
  denied, cancelled, and in-flight (the remainder). `success_rate` is successes
  over attempted RESULTS (success + failure), or nil when none have a result
  yet — denied / cancelled / in-flight never count toward it.
  """
  def fetch_run_stats(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      hours = Keyword.get(opts, :hours, 24)
      cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

      # One aggregate row, summed in SQL (FILTER) — no app-side counting.
      %{total: total, success: success, failed: failed, denied: denied, cancelled: cancelled} =
        ActionRun.Query.all()
        |> ActionRun.Query.inserted_after(cutoff)
        |> ActionRun.Query.outcome_totals(@failure_statuses)
        |> Authorizer.for_subject(subject)
        |> Repo.one()

      results = success + failed
      in_progress = total - success - failed - denied - cancelled

      {:ok,
       %{
         window_hours: hours,
         total: total,
         success: success,
         failed: failed,
         denied: denied,
         cancelled: cancelled,
         in_progress: in_progress,
         success_rate: if(results > 0, do: round(success * 100 / results))
       }}
    end
  end

  @doc """
  Internal — monthly report job: run outcome tallies for one account over a
  `[from, to)` window. Subject-less; the job scopes by the explicit, already-
  bounded `account_id`. Returns the `outcome_totals` map
  (`%{total, success, failed, denied, cancelled}`) plus `:distinct_runners` —
  how many distinct runners the account exercised in the window.
  """
  def report_run_stats(account_id, %DateTime{} = from, %DateTime{} = to) do
    window =
      ActionRun.Query.all()
      |> ActionRun.Query.by_account_id(account_id)
      |> ActionRun.Query.inserted_after(from)
      |> ActionRun.Query.inserted_before(to)

    totals = window |> ActionRun.Query.outcome_totals(@failure_statuses) |> Repo.one()
    distinct_runners = window |> ActionRun.Query.distinct_runner_count() |> Repo.one()

    Map.put(totals, :distinct_runners, distinct_runners)
  end

  @doc """
  Paginated list of recent runs for a runner, scoped to the subject's
  account. Caller can pass `page: [limit: n]` to control window size.
  Returns `{:ok, [run], %Paginator.Metadata{}}`.
  """
  def list_recent_runs_for_runner(runner_id, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      ActionRun.Query.all()
      |> ActionRun.Query.by_runner_id(runner_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, opts)
    end
  end

  def fetch_run_by_id(id, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ),
         true <- Repo.valid_uuid?(id) do
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      ActionRun.Query.all()
      |> ActionRun.Query.by_id(id)
      |> apply_run_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(ActionRun.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Fetches one run carrying the complete fixed MCP history contract."
  def fetch_mcp_run_by_id(id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ),
         true <- Repo.valid_uuid?(id) do
      ActionRun.Query.all()
      |> ActionRun.Query.fixed_mcp_contract()
      |> scope_fixed_mcp_runs_to_membership(subject)
      |> ActionRun.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(ActionRun.Query)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Lists one API credential's runs for an exact MCP operation identity."
  def list_runs_by_operation(operation_id, api_key_id, %Subject{} = subject)
      when is_binary(operation_id) and is_binary(api_key_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      runs =
        ActionRun.Query.all()
        |> ActionRun.Query.by_operation_id(operation_id)
        |> ActionRun.Query.by_api_key_id(api_key_id)
        |> ActionRun.Query.with_preloaded_runner()
        |> Authorizer.for_subject(subject)
        |> ActionRun.Query.ordered_by_oldest()
        |> Repo.all()

      {:ok, runs}
    end
  end

  @doc "Lists every run in one runbook execution through the caller's account scope."
  def list_runs_by_runbook_execution(execution_id, %Subject{} = subject)
      when is_binary(execution_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      runs =
        ActionRun.Query.all()
        |> ActionRun.Query.by_runbook_execution_id(execution_id)
        |> ActionRun.Query.with_preloaded_runner()
        |> Authorizer.for_subject(subject)
        |> ActionRun.Query.ordered_by_oldest()
        |> Repo.all()

      {:ok, runs}
    end
  end

  # `:own` narrows to the calling agent's own runs (its API key) — the MCP
  # `recent_runs` "recall what I ran" path; only an API-key subject has "own"
  # runs, so any other actor falls through to `:account` (the for_subject scope).
  defp apply_run_scope(query, :own, %Subject{actor: %ApiKeys.ApiKey{id: api_key_id}}),
    do: ActionRun.Query.by_api_key_id(query, api_key_id)

  defp apply_run_scope(query, _scope, _subject), do: query

  defp scope_fixed_mcp_runs_to_membership(
         query,
         %Subject{membership_id: membership_id}
       )
       when is_binary(membership_id) do
    case Emisar.Runners.runner_scopes_for_membership(membership_id) do
      [] ->
        query

      scopes ->
        runner_ids = for %{scope_type: :runner, scope_value: value} <- scopes, do: value
        groups = for %{scope_type: :group, scope_value: value} <- scopes, do: value
        ActionRun.Query.by_runner_scope_values(query, runner_ids, groups)
    end
  end

  defp scope_fixed_mcp_runs_to_membership(query, %Subject{}),
    do: ActionRun.Query.none(query)

  # Rendering concerns are the caller's: pass `preload:` only for the
  # associations the page actually shows. Unknown atoms raise (caller bug).
  defp apply_run_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :runner, queryable -> ActionRun.Query.with_preloaded_runner(queryable)
      :api_key, queryable -> ActionRun.Query.with_preloaded_api_key(queryable)
      :requested_by, queryable -> ActionRun.Query.with_preloaded_requested_by(queryable)
    end)
  end

  @doc """
  Internal — runner socket: look up a run by `request_id` AND `runner_id`
  (the socket's runner-scope is the gate, no web subject), so a runner can
  only see/mutate runs that were dispatched to it — never another runner's
  runs, even within the same account.
  """
  def fetch_run_by_request_id_for_runner(request_id, runner_id) do
    ActionRun.Query.all()
    |> ActionRun.Query.by_runner_id(runner_id)
    |> ActionRun.Query.by_request_id(request_id)
    |> Repo.fetch(ActionRun.Query)
  end

  @doc """
  Internal — runner socket: return a dispatch refused at the runner's
  concurrency cap to the pending queue. The runner checks its active-run
  count before spawning a handler, so this refusal proves the action never
  started. The runner and account filters keep the request correlation inside
  the authenticated socket's scope.

  Duplicate cap errors are idempotent once the run is pending; a result or a
  terminal transition that won the race is left authoritative.
  """
  def handle_runner_error(
        account_id,
        runner_id,
        %{
          "code" => "concurrency_cap_reached",
          "request_id" => request_id
        }
      )
      when is_binary(account_id) and is_binary(runner_id) and is_binary(request_id) do
    queryable =
      ActionRun.Query.all()
      |> ActionRun.Query.by_account_id(account_id)
      |> ActionRun.Query.by_runner_id(runner_id)
      |> ActionRun.Query.by_request_id(request_id)

    case Repo.fetch(queryable, ActionRun.Query) do
      {:error, :not_found} ->
        {:error, :unknown_request_id}

      {:ok, %ActionRun{status: :pending} = run} ->
        {:ok, run}

      {:ok, %ActionRun{status: :sent} = run} ->
        transition_from(run, :sent, :pending, %{
          queued_at: DateTime.utc_now(),
          sent_at: nil,
          runner_connection_generation: nil
        })

      {:ok, %ActionRun{} = run} ->
        {:error, {:not_dispatchable, run.status}}
    end
  end

  def handle_runner_error(_account_id, _runner_id, _payload), do: :ok

  # -- Creation ---------------------------------------------------------

  @doc """
  Internal — the dispatch pipeline (`dispatch_run/2`'s allow/deny/approval
  paths) and tests: create a run row in :pending state inside the
  already-authorized dispatch (no web subject). Caller is responsible for
  triggering the transport to deliver `run_action` once the row is
  persisted (see Emisar.Transport).

  Returns `{:ok, run}` or `{:error, changeset}`.

  Tests can also call this directly to seed runs without exercising
  policy + dispatch.
  """
  def create_run(attrs, opts \\ []) do
    request_id = attrs[:request_id] || Crypto.run_request_id()
    attrs = attrs |> put_action_arguments_raw() |> Map.put(:request_id, request_id)
    attrs = Map.put(attrs, :queued_at, DateTime.utc_now())

    result =
      Multi.new()
      |> Multi.insert(:run, ActionRun.Changeset.create(attrs))
      |> put_run_audit_event()
      |> put_decision_audit(opts[:audit])
      # `:compose` lets a caller append steps that read `:run` from changes and
      # commit ATOMICALLY with it — the approval path files its request here, so
      # a run + its request can never half-commit (MAJOR-2).
      |> compose_run_steps(opts[:compose])
      |> Repo.commit_multi()

    case result do
      {:ok, %{run: %ActionRun{request_id: ^request_id} = run} = changes} ->
        broadcast_run(run)
        run_on_create(opts[:on_create], changes)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compose_run_steps(multi, nil), do: multi
  defp compose_run_steps(multi, fun) when is_function(fun, 1), do: fun.(multi)

  defp run_on_create(nil, _changes), do: :ok
  defp run_on_create(fun, changes) when is_function(fun, 1), do: fun.(changes)

  @doc """
  End-to-end dispatch: create the run row, evaluate policy, either
  request approval or send the `run_action` envelope to the runner over
  PubSub. Returns:

      {:ok, :running, run}        — sent to runner
      {:ok, :pending_approval, r} — waiting on operator
      {:error, :denied_by_policy, reason}
      {:error, changeset}
  """
  def dispatch_run(attrs, %Subject{account: %{id: account_id}} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.dispatch_run_permission()
           ) do
      attrs
      |> put_dispatcher_context(subject)
      |> put_dispatcher_identity(subject)
      |> dispatch_run_for_account(account_id)
    end
  end

  @doc """
  Atomically reserves one fixed MCP operation and persists every target outcome.

  Catalog trust, runner scope, attestation presence, and policy are re-evaluated
  for every target inside the transaction. No run is broadcast or delivered and
  no approval notification is emitted until the operation row, every run, every
  approval request, and every grant use have committed together.

  An exact replay returns the original target rows without re-dispatching them.
  """
  def dispatch_mcp_fanout(operation_attrs, target_attrs, %Subject{} = subject)
      when is_map(operation_attrs) and is_list(target_attrs) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.dispatch_run_permission()
           ),
         :ok <- validate_mcp_targets(target_attrs) do
      target_attrs =
        Enum.map(target_attrs, fn attrs ->
          attrs
          |> put_dispatcher_context(subject)
          |> put_dispatcher_identity(subject)
        end)

      commit_mcp_fanout(operation_attrs, target_attrs, subject, true)
    end
  end

  def dispatch_mcp_fanout(_operation_attrs, _target_attrs, %Subject{}),
    do: {:error, :invalid_targets}

  defp validate_mcp_targets(target_attrs) do
    runner_ids = Enum.map(target_attrs, &Map.get(&1, :runner_id))

    if length(target_attrs) in 1..@max_mcp_fanout and
         Enum.all?(target_attrs, &is_map/1) and
         Enum.all?(runner_ids, &is_binary/1) and
         MapSet.size(MapSet.new(runner_ids)) == length(runner_ids) do
      :ok
    else
      {:error, :invalid_targets}
    end
  end

  defp commit_mcp_fanout(operation_attrs, target_attrs, subject, use_grants?) do
    with {:ok, multi} <- MCPOperations.reserve_in_multi(Multi.new(), operation_attrs, subject) do
      result =
        multi
        |> Multi.merge(fn
          %{mcp_operation: %{fresh?: false}} ->
            Multi.new()

          %{mcp_operation: %{operation: operation, fresh?: true}} ->
            compose_mcp_fanout(target_attrs, subject.account.id, operation.id, use_grants?)
        end)
        |> Repo.commit_multi(after_commit: &after_mcp_fanout_committed/1)

      case result do
        {:ok, %{mcp_operation: %{operation: operation}}} ->
          list_runs_by_mcp_operation(operation.id, subject)

        {:error, :grant_unusable} when use_grants? ->
          # A grant can expire, be revoked, or exhaust its final use between
          # policy planning and the locked consume. The first transaction has
          # rolled back completely, including the operation reservation, so the
          # retry can safely persist the same fan-out as pending approval.
          commit_mcp_fanout(operation_attrs, target_attrs, subject, false)

        other ->
          other
      end
    end
  end

  defp compose_mcp_fanout(target_attrs, account_id, operation_record_id, use_grants?) do
    target_attrs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, Multi.new()}, fn {attrs, index}, {:ok, multi} ->
      case plan_atomic_run(attrs, account_id, operation_record_id, use_grants?) do
        {:ok, plan} ->
          run_key = {:mcp_run, index}
          {:cont, {:ok, append_atomic_run(multi, plan, run_key, index)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, multi} -> multi
      {:error, reason} -> Multi.error(Multi.new(), :mcp_fanout_preflight, reason)
    end
  end

  @doc """
  Composes a bounded dispatch batch into an existing transaction.

  The caller owns the parent resource and passes a unique `namespace` for the
  Multi keys. Planning runs inside the outer transaction; delivery, broadcasts,
  and approval notifications must be invoked after the outer commit through
  `after_composed_dispatches_committed/1`.
  """
  def compose_dispatch_batch_in_multi(multi, target_attrs, subject, namespace, opts \\ [])

  def compose_dispatch_batch_in_multi(
        %Multi{} = multi,
        target_attrs,
        %Subject{} = subject,
        namespace,
        opts
      )
      when is_list(target_attrs) do
    use_grants? = Keyword.get(opts, :use_grants?, true)

    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.dispatch_run_permission()
           ),
         :ok <- validate_dispatch_batch(target_attrs) do
      target_attrs =
        Enum.map(target_attrs, fn attrs ->
          attrs
          |> put_dispatcher_context(subject)
          |> put_dispatcher_identity(subject)
        end)

      {:ok,
       Multi.merge(multi, fn _changes ->
         compose_dispatch_batch(
           target_attrs,
           subject.account.id,
           namespace,
           use_grants?
         )
       end)}
    end
  end

  def compose_dispatch_batch_in_multi(%Multi{}, _target_attrs, %Subject{}, _namespace, _opts),
    do: {:error, :invalid_targets}

  defp validate_dispatch_batch(target_attrs) do
    if length(target_attrs) in 1..@max_mcp_fanout and
         Enum.all?(target_attrs, &(is_map(&1) and is_binary(Map.get(&1, :runner_id)))) do
      :ok
    else
      {:error, :invalid_targets}
    end
  end

  defp compose_dispatch_batch(target_attrs, account_id, namespace, use_grants?) do
    target_attrs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, Multi.new()}, fn {attrs, index}, {:ok, multi} ->
      case plan_atomic_run(attrs, account_id, nil, use_grants?) do
        {:ok, plan} ->
          run_key = {:composed_run, namespace, index}
          {:cont, {:ok, append_atomic_run(multi, plan, run_key, {namespace, index})}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, multi} -> multi
      {:error, reason} -> Multi.error(Multi.new(), {:dispatch_batch, namespace}, reason)
    end
  end

  defp plan_atomic_run(attrs, account_id, operation_record_id, use_grants?) do
    attrs = Map.put(attrs, :account_id, account_id)
    runner_id = attrs[:runner_id]
    action_id = attrs[:action_id]
    reason = attrs[:reason]
    membership_id = Map.get(attrs, :requested_by_membership_id)

    with :ok <- require_runner(runner_id),
         :ok <- require_action(action_id),
         :ok <- require_reason(reason),
         :ok <- runner_in_account(runner_id, account_id),
         :ok <- check_attestation(attrs, runner_id, account_id),
         :ok <-
           attestation_fresh(attrs[:attestation], Emisar.Runners.peek_runner_by_id(runner_id)),
         :ok <- runner_in_membership_scope(runner_id, account_id, membership_id),
         {:ok, runner_ref} <- public_runner_ref(runner_id),
         {:ok, action} <- fetch_advertised_action(runner_id, action_id, account_id),
         :ok <- check_pack_ref(action, attrs[:pack_ref]),
         {:ok, pack_hash} <- check_pack_trust(action, account_id) do
      attrs =
        attrs
        |> Map.delete(:requested_by_membership_id)
        |> put_action_arguments(action)
        |> Map.put(:runner_ref, runner_ref)
        |> Map.put(:expected_pack_hash, pack_hash)
        |> Map.put(:requires_approval, false)
        |> Map.put(:mcp_operation_record_id, operation_record_id)

      plan_mcp_policy(attrs, account_id, action, use_grants?)
    end
  end

  defp plan_mcp_policy(attrs, account_id, action, use_grants?) do
    eval_attrs = Map.merge(attrs, %{risk: action.risk, kind: action.kind})
    group = runner_group(attrs[:runner_id])

    case Emisar.Policies.evaluate_with_policy(account_id, eval_attrs, group) do
      {:deny, matched, reason, policy} ->
        {:ok,
         %{
           attrs:
             attrs
             |> Map.merge(policy_attrs(policy, "deny", reason, matched))
             |> Map.put(:status, :denied),
           delivery: :none
         }}

      {:allow, matched, reason, policy} ->
        {:ok,
         %{
           attrs: Map.merge(attrs, policy_attrs(policy, "allow", reason, matched)),
           delivery: :runner
         }}

      {:require_approval, matched, reason, policy} ->
        with {:ok, approval} <- Emisar.Policies.approval_settings_for(policy.rules) do
          {:ok, plan_mcp_approval(attrs, policy, reason, matched, use_grants?, approval)}
        end
    end
  end

  defp plan_mcp_approval(attrs, policy, policy_reason, matched, true, approval) do
    case lookup_grant(attrs) do
      {:matched, grant} ->
        %{
          attrs:
            Map.merge(
              attrs,
              policy_attrs(policy, "allow", "matched approval grant", matched)
            ),
          delivery: :runner,
          grant: {grant, policy}
        }

      :none ->
        plan_mcp_approval(attrs, policy, policy_reason, matched, false, approval)
    end
  end

  defp plan_mcp_approval(attrs, policy, policy_reason, matched, false, approval) do
    attrs =
      attrs
      |> Map.merge(policy_attrs(policy, "require_approval", policy_reason, matched))
      |> Map.merge(%{status: :pending_approval, requires_approval: true})

    request_opts = [
      min_approvals: approval.min_approvals,
      allow_self_approval: approval.allow_self_approval,
      expires_at: approval_attestation_deadline(attrs)
    ]

    %{
      attrs: attrs,
      delivery: :approval,
      approval: {attrs[:requested_by_id], attrs[:reason], request_opts}
    }
  end

  defp append_atomic_run(multi, plan, run_key, audit_suffix) do
    request_id = Crypto.run_request_id()

    attrs =
      plan.attrs
      |> Map.put(:request_id, request_id)
      |> Map.put(:queued_at, DateTime.utc_now())

    multi
    |> Multi.insert(run_key, ActionRun.Changeset.create(attrs))
    |> append_atomic_run_audit(run_key, attrs[:status], audit_suffix)
    |> append_mcp_approval(run_key, plan[:approval])
    |> append_atomic_grant(run_key, plan[:grant], audit_suffix)
  end

  defp append_atomic_run_audit(multi, run_key, status, audit_suffix)
       when status in @audited_run_statuses do
    Multi.insert(multi, {:atomic_run_audit, audit_suffix}, fn changes ->
      changes |> Map.fetch!(run_key) |> Audit.run_event_changeset()
    end)
  end

  defp append_atomic_run_audit(multi, _run_key, _status, _audit_suffix), do: multi

  defp append_mcp_approval(multi, _run_key, nil), do: multi

  defp append_mcp_approval(multi, run_key, {requested_by_id, reason, opts}) do
    Emisar.Approvals.create_request_in_multi(
      multi,
      run_key,
      requested_by_id,
      reason,
      opts
    )
  end

  defp append_atomic_grant(multi, _run_key, nil, _audit_suffix), do: multi

  defp append_atomic_grant(multi, run_key, {grant, policy}, audit_suffix) do
    multi
    |> Emisar.Approvals.consume_grant_in_multi(run_key, grant)
    |> Multi.insert({:atomic_grant_audit, audit_suffix}, fn changes ->
      changes |> Map.fetch!(run_key) |> Audit.Events.grant_used(grant, policy)
    end)
  end

  defp after_mcp_fanout_committed(%{mcp_operation: %{fresh?: false}}), do: :ok

  defp after_mcp_fanout_committed(%{mcp_operation: %{fresh?: true}} = changes) do
    after_composed_dispatches_committed(changes)
  end

  @doc "Runs every side effect for dispatch rows after their outer transaction commits."
  def after_composed_dispatches_committed(changes) when is_map(changes) do
    changes
    |> composed_runs_from_changes()
    |> Enum.each(fn {run_key, run} ->
      broadcast_run(run)
      after_mcp_run_committed(changes, run_key, run)
    end)

    :ok
  end

  defp after_mcp_run_committed(_changes, _run_key, %ActionRun{status: :pending} = run) do
    case dispatch_to_runner(run) do
      :ok -> :ok
      {:error, reason} -> Logger.error("MCP run delivery failed: #{inspect(reason)}")
    end
  end

  defp after_mcp_run_committed(changes, run_key, %ActionRun{status: :pending_approval} = run) do
    request_key = {:approval_request, run_key}

    case Map.get(changes, request_key) do
      %Emisar.Approvals.Request{} = request ->
        Emisar.Approvals.notify_request_created(request, run)

      _ ->
        Logger.error("MCP approval request missing after committed run #{run.id}")
    end
  end

  defp after_mcp_run_committed(_changes, _run_key, %ActionRun{}), do: :ok

  defp composed_runs_from_changes(changes) do
    changes
    |> Enum.flat_map(fn
      {{:mcp_run, index} = key, %ActionRun{} = run} ->
        [{{0, index}, key, run}]

      {{:composed_run, namespace, index} = key, %ActionRun{} = run} ->
        [{{1, inspect(namespace), index}, key, run}]

      _ ->
        []
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_sort_key, key, run} -> {key, run} end)
  end

  @doc "Lists the complete target set persisted under one MCP operation row."
  def list_runs_by_mcp_operation(operation_record_id, %Subject{} = subject)
      when is_binary(operation_record_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      runs =
        ActionRun.Query.all()
        |> ActionRun.Query.by_mcp_operation_record_id(operation_record_id)
        |> ActionRun.Query.with_preloaded_runner()
        |> Authorizer.for_subject(subject)
        |> ActionRun.Query.ordered_by_oldest()
        |> Repo.all()

      {:ok, runs}
    end
  end

  # Snapshot the dispatcher's source ip/ua + self-reported MCP client metadata
  # from the request context onto the run attrs, so every run-lifecycle audit
  # event — including the terminal one logged from the runner socket — attributes
  # the action to where it came from and carries the caller's correlation
  # metadata. The subject-less dispatch_run_for_account path (the runbook
  # continuation) carries none, which is correct: no request, no dispatcher.
  defp put_dispatcher_context(attrs, %Subject{context: %RequestContext{} = context}) do
    attrs
    |> Map.put(:ip_address, context.ip_address)
    |> Map.put(:user_agent, context.user_agent)
    |> Map.put(:mcp_client_metadata, context.mcp_client_metadata)
  end

  defp put_dispatcher_context(attrs, _subject), do: attrs

  # The authenticated subject, not wire attrs, owns both dispatch attribution
  # and the runner-scope membership. This keeps a boundary regression from
  # letting a user name another membership (or an API key another credential)
  # to widen its fleet reach or misattribute the run.
  defp put_dispatcher_identity(
         attrs,
         %Subject{actor: %Users.User{id: user_id}, membership_id: membership_id}
       ) do
    attrs
    |> Map.put(:requested_by_id, user_id)
    |> Map.put(:requested_by_membership_id, membership_id)
    |> Map.delete(:api_key_id)
  end

  defp put_dispatcher_identity(
         attrs,
         %Subject{actor: %ApiKeys.ApiKey{id: api_key_id}, membership_id: membership_id}
       ) do
    attrs
    |> Map.put(:api_key_id, api_key_id)
    |> Map.put(:requested_by_membership_id, membership_id)
    |> Map.delete(:requested_by_id)
  end

  defp put_dispatcher_identity(attrs, %Subject{membership_id: membership_id}),
    do: Map.put(attrs, :requested_by_membership_id, membership_id)

  @doc """
  Internal: dispatch a run for an explicit account with no `%Subject{}`.
  Used by the runbook engine to continue a chain after a terminal runner result
  callback, where no user is in scope. The originating dispatch already
  authorized the operator; the continuation re-validates by threading the
  initiating membership through `requested_by_membership_id`, so this path runs
  the same per-membership runner-scope check as the first wave (a scope revoked
  mid-execution stops it). `nil` membership means a genuinely user-less dispatch
  with no per-user scope to enforce — never the runbook continuation.
  """
  def dispatch_run_for_account(attrs, account_id) when is_binary(account_id) do
    attrs = Map.put(attrs, :account_id, account_id)
    runner_id = attrs[:runner_id]
    action_id = attrs[:action_id]
    reason = attrs[:reason]
    membership_id = Map.get(attrs, :requested_by_membership_id)

    with :ok <- require_runner(runner_id),
         :ok <- require_action(action_id),
         :ok <- require_reason(reason),
         :ok <- runner_in_account(runner_id, account_id),
         :ok <- check_attestation(attrs, runner_id, account_id),
         :ok <- runner_in_membership_scope(runner_id, account_id, membership_id),
         {:ok, runner_ref} <- public_runner_ref(runner_id),
         {:ok, action} <- fetch_advertised_action(runner_id, action_id, account_id),
         :ok <- check_pack_ref(action, attrs[:pack_ref]),
         {:ok, pack_hash} <- check_pack_trust(action, account_id) do
      attrs
      |> Map.delete(:requested_by_membership_id)
      |> put_action_arguments(action)
      |> Map.put(:runner_ref, runner_ref)
      # Snapshot the trusted hash as part of the authorization decision (MAJOR-5)
      # so the run ships the exact bytes authorized here, not a send-time re-read.
      |> Map.put(:expected_pack_hash, pack_hash)
      |> Map.put(:requires_approval, false)
      |> evaluate_and_dispatch(account_id, action)
    end
  end

  @doc """
  Internal — re-validate that an already-created run's action pack is STILL
  trusted, for the approval path. `dispatch_run_for_account` gates pack
  trust at run creation, but `Approvals.approve_request` re-dispatches the
  parked run directly; without this re-check a runner that re-advertised
  the pack with a tampered hash during the approval window (flipping the
  pack to `:pending`) would have the operator's approval ship the new,
  untrusted bytes. Returns `:ok` or `{:error, :pack_untrusted |
  :action_not_found}` — the caller refuses the approval on error.
  """
  def recheck_run_pack_trust(run_id) when is_binary(run_id) do
    run_id |> fetch_run!() |> recheck_snapshotted_pack_trust()
  end

  @doc """
  Internal — Approvals' pre-approval gate for signed dispatch: refuse the
  approval when this run's relayed signature would already be outside the
  enforcing runner's freshness window, so a slow approval doesn't leave an
  approved-but-dead run the runner refuses as stale. The runner stays the
  authority; this is the fail-fast. `:ok | {:error, :attestation_stale}`.
  """
  def check_run_attestation_fresh(run_id) when is_binary(run_id) do
    run =
      ActionRun.Query.all()
      |> ActionRun.Query.by_id(run_id)
      |> ActionRun.Query.with_preloaded_runner()
      |> Repo.one!()

    attestation_fresh(run.attestation, run.runner)
  end

  defp attestation_fresh(
         att,
         %Emisar.Runners.Runner{enforce_signatures: true, max_attestation_age_seconds: max_age}
       )
       when is_map(att) and is_integer(max_age) do
    # Mirror the runner's independent freshness and certificate windows. The
    # runner remains authoritative over both signatures; this portal check only
    # prevents creating or approving work whose advertised deadlines are
    # already unusable.
    now = DateTime.utc_now()

    with {:ok, issued_at, deadline} <- attestation_window(att, max_age),
         age when age <= max_age <- abs(DateTime.diff(now, issued_at)),
         :gt <- DateTime.compare(deadline, now) do
      :ok
    else
      _ -> {:error, :attestation_stale}
    end
  end

  defp attestation_fresh(_att, %Emisar.Runners.Runner{enforce_signatures: true}),
    do: {:error, :attestation_stale}

  defp attestation_fresh(_att, _runner), do: :ok

  defp approval_attestation_deadline(%{attestation: attestation, runner_id: runner_id})
       when is_map(attestation) and is_binary(runner_id) do
    case Emisar.Runners.peek_runner_by_id(runner_id) do
      %Emisar.Runners.Runner{
        enforce_signatures: true,
        max_attestation_age_seconds: max_age
      }
      when is_integer(max_age) ->
        case attestation_window(attestation, max_age) do
          {:ok, _issued_at, deadline} -> deadline
          {:error, :attestation_stale} -> DateTime.utc_now()
        end

      _ ->
        nil
    end
  end

  defp approval_attestation_deadline(_attrs), do: nil

  defp attestation_window(attestation, max_age) do
    with issued when is_binary(issued) <- attestation["issued_at"],
         {:ok, issued_at, _offset} <- DateTime.from_iso8601(issued),
         valid_until when is_binary(valid_until) <- get_in(attestation, ["cert", "valid_until"]),
         {:ok, cert_deadline, _offset} <- DateTime.from_iso8601(valid_until) do
      freshness_deadline = DateTime.add(issued_at, max_age, :second)

      {:ok, issued_at,
       Enum.min_by([freshness_deadline, cert_deadline], &DateTime.to_unix(&1, :microsecond))}
    else
      _ -> {:error, :attestation_stale}
    end
  end

  # Per-user runner ACLs (v1). When the caller supplies a
  # `requested_by_membership_id`, the membership's runner scopes must
  # include this runner. Operator UI AND MCP both supply it — an
  # `emk-`/OAuth key carries its creator's membership
  # (`created_by_membership_id`, set at mint), so revoking a user's scope
  # shrinks every key they minted. Do NOT "simplify" MCP to pass nil here:
  # nil means "no per-user scope" (a genuinely user-less system dispatch) — the
  # runbook continuation does NOT pass nil, it threads the initiating membership
  # so later waves re-run this check. Routing a scoped key through nil would
  # unscope the key. `runner_in_account/2` runs first in the with chain, so
  # the runner is guaranteed to belong to `account_id` by the time we get
  # here.
  defp runner_in_membership_scope(_runner_id, _account_id, nil), do: :ok

  defp runner_in_membership_scope(runner_id, _account_id, membership_id) do
    case Emisar.Runners.runner_scopes_for_membership(membership_id) do
      [] ->
        :ok

      scopes ->
        case Emisar.Runners.peek_runner_by_id(runner_id) do
          nil ->
            {:error, :runner_not_found}

          runner ->
            if Emisar.Runners.runner_in_scope?(runner, scopes),
              do: :ok,
              else: {:error, :runner_out_of_scope}
        end
    end
  end

  defp require_runner(nil), do: {:error, :runner_required}
  defp require_runner(_), do: :ok

  # Reason is mandatory at the context layer so operators (UI), API keys
  # (programmatic), and LLM tools (MCP) all hit the same gate. The runner
  # rejects empty-reason runs too, but stopping it here means the run
  # row isn't even created.
  defp require_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "", do: {:error, :reason_required}, else: :ok
  end

  defp require_reason(_), do: {:error, :reason_required}

  defp require_action(nil), do: {:error, :action_required}
  defp require_action(_), do: :ok

  defp runner_in_account(runner_id, account_id) do
    if Emisar.Runners.runner_active_in_account?(runner_id, account_id) do
      :ok
    else
      {:error, :runner_not_found}
    end
  end

  defp public_runner_ref(runner_id) do
    with %Emisar.Runners.Runner{} = runner <- Emisar.Runners.peek_runner_by_id(runner_id),
         {:ok, runner_ref} <- Emisar.Catalog.MCPProjection.runner_ref(runner) do
      {:ok, runner_ref}
    else
      _ -> {:error, :runner_not_found}
    end
  end

  # Authoritative lookup. The runner has already advertised this action
  # via `Catalog.observe_state`; if the catalog row is missing the
  # action simply doesn't exist on that runner and we refuse to dispatch.
  defp fetch_advertised_action(runner_id, action_id, account_id) do
    case Emisar.Catalog.fetch_action_for_account(action_id, runner_id, account_id) do
      {:error, :not_found} -> {:error, :action_not_found}
      {:ok, action} -> {:ok, action}
    end
  end

  defp check_pack_ref(_action, nil), do: :ok

  defp check_pack_ref(action, pack_ref) when is_binary(pack_ref) do
    with {:ok, {pack_id, pack_version, pack_hash}} <-
           Emisar.Catalog.MCPProjection.parse_pack_ref(pack_ref),
         true <-
           action.pack_id == pack_id and action.pack_version == pack_version and
             action.pack_hash == pack_hash do
      :ok
    else
      _ -> {:error, :pack_ref_mismatch}
    end
  end

  # Refuse a portal-originated (operator / runbook / API-key) dispatch to a
  # runner that advertises it enforces client signatures. The runner would
  # reject an unsigned run anyway; blocking here means no run row is created and
  # the caller gets a clear reason. A signed MCP dispatch carries an
  # `:attestation` and passes. The MCP boundary has already validated its shape
  # and exact selected-target match; the runner remains the cryptographic
  # authority that verifies the Ed25519 signature. This portal flag is the
  # UX/backstop gate; the runner's signature check is the real one.
  defp check_attestation(attrs, runner_id, account_id) do
    cond do
      attrs[:attestation] ->
        :ok

      Emisar.Runners.runner_enforces_signatures?(runner_id, account_id) ->
        Audit.record(
          Audit.Events.dispatch_blocked_requires_attestation(
            account_id,
            runner_id,
            attrs[:action_id]
          )
        )

        {:error, :runner_requires_attestation}

      true ->
        :ok
    end
  end

  # Refuse dispatch if the action's pack is in `pending_trust`. The
  # runner is advertising a hash that diverges from what an operator
  # has previously trusted (or from the baseline we ship) — execution
  # waits for a human decision in the /app/packs UI.
  # Returns `{:ok, trusted_hash | nil}` — the hash to SNAPSHOT onto the run (nil
  # for a pack-less / not-yet-versioned action) — or `{:error, :pack_untrusted}`.
  defp check_pack_trust(action, account_id) do
    case Emisar.Catalog.check_pack_trusted(action) do
      {:ok, hash} ->
        {:ok, hash}

      {:error, :pack_untrusted, pack_info} ->
        Audit.record(Audit.Events.dispatch_blocked_pack_untrusted(account_id, pack_info, action))
        {:error, :pack_untrusted}

      {:error, :pack_retired, pack_version} ->
        Audit.record(Audit.Events.dispatch_blocked_pack_retired(account_id, pack_version, action))
        {:error, :pack_retired}
    end
  end

  # The policy sees catalog-authoritative risk + kind so a caller can't
  # spoof "low" to bypass a `:require_approval` on `high`.
  defp evaluate_and_dispatch(attrs, account_id, action) do
    eval_attrs = Map.merge(attrs, %{risk: action.risk, kind: action.kind})
    group = runner_group(attrs[:runner_id])

    case Emisar.Policies.evaluate_with_policy(account_id, eval_attrs, group) do
      {:deny, matched, reason, policy} ->
        dispatch_deny(attrs, policy, reason, matched)

      {:allow, matched, reason, policy} ->
        dispatch_allow(attrs, policy, reason, matched)

      {:require_approval, matched, reason, policy} ->
        dispatch_require_approval(attrs, policy, reason, matched)
    end
  end

  # The dispatch runner's group, so Policies can resolve a group-scoped
  # override. nil for a runner with no group (or none found) — resolution
  # then skips the group tier and falls through to the account default.
  defp runner_group(runner_id) do
    case Emisar.Runners.peek_runner_by_id(runner_id) do
      %{group: group} -> group
      nil -> nil
    end
  end

  # Store a denied row even though we never reach the runner — operators need to
  # see attempts that policy rejected. `create_run` writes the terminal
  # `action_run.denied` audit row (`:denied` ∈ @audited_run_statuses) carrying the
  # policy_reason + matched_rules, so the denial IS audited without a separate
  # `policy.evaluated` row (audit-logging-diet #2 — never zero rows for a denial).
  defp dispatch_deny(attrs, policy, reason, matched) do
    run_attrs =
      attrs
      |> Map.merge(policy_attrs(policy, "deny", reason, matched))
      |> Map.put(:status, :denied)

    case create_run(run_attrs) do
      {:ok, _denied} ->
        {:error, :denied_by_policy, reason}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp dispatch_allow(attrs, policy, reason, matched) do
    attrs = Map.merge(attrs, policy_attrs(policy, "allow", reason, matched))

    # No separate `policy.evaluated "allow"` audit row — it was pure noise (one per
    # dispatch). The allow decision + matched rules live on the ActionRun itself
    # (policy_decision/policy_reason/matched_rules), and the run's own terminal
    # audit row proves it ran (audit-logging-diet #1). Dispatch to the runner only
    # after the run row is durable.
    case create_run(attrs) do
      {:ok, run} ->
        with :ok <- dispatch_to_runner(run) do
          {:ok, :running, run}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # The grant fast-path lets an LLM keep working after a one-time human
  # approval — `peek_matching_grant` returns nil unless the calling key
  # has an unexpired, unrevoked grant whose (action, runner, args)
  # shape covers this call. When matched we dispatch as if policy said
  # `:allow`; the grant is named in the audit row so it's traceable
  # back to the human who said yes.
  defp dispatch_require_approval(attrs, policy, policy_reason, matched) do
    with {:ok, approval} <- Emisar.Policies.approval_settings_for(policy.rules) do
      case lookup_grant(attrs) do
        {:matched, grant} ->
          case dispatch_with_grant(attrs, policy, matched, grant) do
            # The grant lapsed (expired / exhausted / revoked) between the peek and
            # the atomic consume — fall back to the normal approval flow as if no
            # grant matched, rather than burning a use or erroring the caller.
            {:error, :grant_unusable} ->
              file_approval_request(attrs, policy, policy_reason, matched, approval)

            other ->
              other
          end

        :none ->
          file_approval_request(attrs, policy, policy_reason, matched, approval)
      end
    end
  end

  # Dispatch as `:allow` against a matched grant. The grant is consumed INSIDE
  # create_run's Multi (MAJOR-3) — one use is burned only when the run row
  # durably commits, never on a validation failure.
  defp dispatch_with_grant(attrs, policy, matched, grant) do
    attrs = Map.merge(attrs, policy_attrs(policy, "allow", "matched approval grant", matched))
    audit = &Audit.Events.grant_used(&1, grant, policy)
    compose = &Emisar.Approvals.consume_grant_in_multi(&1, :run, grant)

    case create_run(attrs, audit: audit, compose: compose) do
      {:ok, run} ->
        with :ok <- dispatch_to_runner(run) do
          {:ok, :running, run}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # File an approval request (no usable grant). Run + request commit in ONE
  # transaction (MAJOR-2); the approver notification fires post-commit on the
  # fresh-insert path only. No separate `policy.evaluated "require_approval"` row —
  # the `action_run.pending_approval` gating row (`:pending_approval` ∈
  # @audited_run_statuses) + the approval request itself already record that the
  # action was gated (audit-logging-diet #3).
  defp file_approval_request(attrs, policy, policy_reason, matched, approval) do
    attrs =
      attrs
      |> Map.merge(policy_attrs(policy, "require_approval", policy_reason, matched))
      |> Map.merge(%{status: :pending_approval, requires_approval: true})

    # Snapshot the approval-gate posture onto the request so a later policy edit
    # can't move this in-flight request's bar (mirrors the run-level
    # policy_version snapshot). The operator's reason ("why I'm running this")
    # goes to the request; the policy reason stays on run.policy_reason.
    request_opts = [
      min_approvals: approval.min_approvals,
      allow_self_approval: approval.allow_self_approval
    ]

    compose =
      &Emisar.Approvals.create_request_in_multi(
        &1,
        :run,
        attrs[:requested_by_id],
        attrs[:reason],
        request_opts
      )

    case create_run(attrs,
           compose: compose,
           on_create: &Emisar.Approvals.notify_request_created/1
         ) do
      {:ok, run} ->
        {:ok, :pending_approval, run}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # PEEK only — the grant is CONSUMED later, atomically with the run insert (see
  # dispatch_with_grant), so a use is never burned without a durable run.
  defp lookup_grant(%{api_key_id: api_key_id} = attrs) when is_binary(api_key_id) do
    case Emisar.Approvals.peek_matching_grant(
           attrs[:account_id],
           api_key_id,
           attrs[:action_id],
           attrs[:runner_id],
           attrs[:args_sha256]
         ) do
      %{} = grant -> {:matched, grant}
      _ -> :none
    end
  end

  defp lookup_grant(_attrs), do: :none

  defp put_action_arguments(attrs, action) do
    attrs = put_action_arguments_raw(attrs)

    sensitive_arg_names =
      action.args_schema
      |> Map.get("args", [])
      |> Enum.filter(&(&1["sensitive"] == true))
      |> Enum.map(& &1["name"])
      |> Enum.filter(&is_binary/1)

    attrs
    |> Map.put(:args_sha256, Crypto.hash_hex(attrs[:args_raw]))
    |> Map.put(:sensitive_arg_names, sensitive_arg_names)
  end

  defp put_action_arguments_raw(attrs) do
    raw = attrs[:args_raw] || Jason.encode!(attrs[:args] || %{})
    Map.put(attrs, :args_raw, raw)
  end

  @doc """
  Internal — used by `Emisar.Runs.Jobs.DispatchTimeout` to find runs
  that have been sitting in `pending` / `sent` longer than the
  dispatch threshold. Returns a plain list (no pagination); the worker
  iterates and decides per-run whether to time it out based on the
  runner's current state.
  """
  def list_stale_dispatches(cutoff) when is_struct(cutoff, DateTime) do
    ActionRun.Query.all()
    |> ActionRun.Query.status_in([:pending, :sent])
    |> ActionRun.Query.queued_before(cutoff)
    |> ActionRun.Query.ordered_by_oldest()
    |> Repo.all()
  end

  @doc """
  Internal — telemetry/ops. FLEET-WIDE (no subject, every account) count of runs
  awaiting dispatch to a runner (`:pending`) — the dispatch-backlog depth.
  Excludes `:pending_approval` (blocked on a human, not a dispatch queue) and
  `:sent` (already handed to a runner). No `account_id`: this is the aggregate ops
  gauge behind `Emisar.Runs.Jobs.FleetObservability`, the counterpart to
  `Runners.connection_counts/0` (series cardinality + tenant enumeration).
  """
  @spec count_pending_dispatches() :: non_neg_integer()
  def count_pending_dispatches do
    ActionRun.Query.all()
    |> ActionRun.Query.status_in([:pending])
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Internal — reconciles a runner after its authoritative state advertisement.
  Exact in-flight envelopes are replayed first: an existing handler ignores the
  duplicate, while a restarted runner converts its durable pending reservation
  to outcome-unknown without executing again. Outstanding cancellation follows
  the replay. A never-sent pending run is dispatched only when no in-flight work
  needs resolution; each terminal result opens the next queue slot.
  """
  def resume_runs_for_runner(runner_id) when is_binary(runner_id) do
    inflight_runs =
      ActionRun.Query.all()
      |> ActionRun.Query.by_runner_id(runner_id)
      |> ActionRun.Query.status_in([:sent, :running, :cancelling])
      |> ActionRun.Query.ordered_by_oldest()
      |> Repo.all()

    Enum.each(inflight_runs, &recover_inflight_run/1)

    if inflight_runs == [], do: dispatch_queued_for_runner(runner_id)
    :ok
  end

  @doc "Internal — dispatches at most one never-sent run after capacity becomes available."
  def dispatch_queued_for_runner(runner_id) when is_binary(runner_id) do
    ActionRun.Query.all()
    |> ActionRun.Query.by_runner_id(runner_id)
    |> ActionRun.Query.status_in([:pending])
    |> ActionRun.Query.ordered_by_oldest()
    |> ActionRun.Query.limit_to(1)
    |> Repo.all()
    |> Enum.each(fn run ->
      case dispatch_to_runner(run) do
        :ok ->
          :ok

        {:error, :not_dispatchable} ->
          :ok

        {:error, reason} ->
          Logger.warning("queued run delivery failed run=#{run.id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp recover_inflight_run(%ActionRun{} = run) do
    with {:ok, generation} <-
           Emisar.Runners.current_connection_generation(run.account_id, run.runner_id),
         :ok <-
           Emisar.Runners.deliver_to_runner(
             run.account_id,
             run.runner_id,
             generation,
             run_action_payload(run)
           ),
         :ok <- recover_cancellation(run, generation) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("in-flight run recovery failed run=#{run.id}: #{inspect(reason)}")
    end
  end

  defp recover_cancellation(%ActionRun{status: :cancelling} = run, generation) do
    Emisar.Runners.deliver_to_runner(run.account_id, run.runner_id, generation, %{
      "type" => "cancel",
      "request_id" => run.request_id,
      "reason" => run.reason_text
    })
  end

  defp recover_cancellation(%ActionRun{}, _generation), do: :ok

  @doc """
  Internal — used by `Emisar.Runs.Jobs.DispatchTimeout` to find in-flight
  runs whose runner may have died mid-run. Plain list (real fleets keep few
  runs in flight); the worker decides per-run from the runner's presence and
  disconnect history.
  """
  def list_running_runs do
    ActionRun.Query.all()
    |> ActionRun.Query.status_in([:running, :cancelling])
    |> Repo.all()
  end

  @doc """
  Internal — the runbook engine's view of one execution: every run minted
  by that invocation, in dispatch order. The engine derives wave state
  (dispatched / in-flight / failed) from these rows; an execution is at
  most steps × group-members runs, so a plain list is fine.
  """
  def list_runs_for_runbook_execution(account_id, execution_id) do
    ActionRun.Query.all()
    |> ActionRun.Query.by_account_id(account_id)
    |> ActionRun.Query.by_runbook_execution_id(execution_id)
    |> ActionRun.Query.ordered_by_oldest()
    |> Repo.all()
  end

  @doc """
  The runbook's most recent execution, if it's still in flight — so the run page
  can rehydrate after a refresh / reconnect (mount otherwise resets to a blank
  plan and the live execution silently vanishes). `%Subject{}` needs `view_runs`.
  `{:ok, %{execution_id, runs}}` (runs in dispatch order, `:runner` preloaded for
  the row render), or `{:error, :not_found}` when the runbook has no execution or
  its latest one is fully settled.
  """
  def fetch_active_runbook_execution(runbook_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runs_permission()) do
      latest_query =
        ActionRun.Query.all()
        |> ActionRun.Query.by_runbook_id(runbook_id)
        |> ActionRun.Query.ordered_by_recent()
        |> ActionRun.Query.limit_to(1)
        |> Authorizer.for_subject(subject)

      case Repo.peek(latest_query) do
        nil ->
          {:error, :not_found}

        %ActionRun{runbook_execution_id: execution_id} ->
          runs_query =
            ActionRun.Query.all()
            |> ActionRun.Query.by_runbook_execution_id(execution_id)
            |> ActionRun.Query.with_preloaded_runner()
            |> ActionRun.Query.ordered_by_oldest()
            |> Authorizer.for_subject(subject)

          runs = Repo.all(runs_query)

          if Enum.any?(runs, &active_run_status?(&1.status)),
            do: {:ok, %{execution_id: execution_id, runs: runs}},
            else: {:error, :not_found}
      end
    end
  end

  # A run still doing work — not yet settled. An execution with at least one is
  # in flight and worth rehydrating. (`:denied` is terminal, so it's excluded.)
  defp active_run_status?(status), do: not ActionRun.terminal?(status)

  @doc """
  Claims a never-sent `:pending` run and emits its run_action envelope onto the
  runner's PubSub topic. If the runner is offline, the run remains pending and
  returns `:ok`; the next owned connection calls `resume_runs_for_runner/1`.
  The status claim is row-locked, so concurrent senders cannot both publish.
  """
  def dispatch_to_runner(%ActionRun{} = run) do
    case peek_run_by_id(run.id) do
      %ActionRun{status: :pending} = current_run ->
        case Emisar.Runners.current_connection_generation(
               current_run.account_id,
               current_run.runner_id
             ) do
          {:ok, generation} -> deliver_run_action(current_run, :pending, generation)
          {:error, :not_connected} -> :ok
        end

      _ ->
        {:error, :not_dispatchable}
    end
  end

  @doc """
  Internal — redelivers a `:sent` run only to the exact connection generation
  that received the first attempt. A successor connection is never eligible.
  """
  def redeliver_to_runner(%ActionRun{} = run) do
    case peek_run_by_id(run.id) do
      %ActionRun{status: :sent} = current_run ->
        with {:ok, generation} <-
               Emisar.Runners.current_connection_generation(
                 current_run.account_id,
                 current_run.runner_id
               ),
             true <- generation == current_run.runner_connection_generation do
          deliver_run_action(current_run, :sent, generation)
        else
          false -> {:error, :connection_changed}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, :not_dispatchable}
    end
  end

  defp deliver_run_action(%ActionRun{} = run, expected_status, generation) do
    case authorized_run_action_payload(run) do
      {:ok, envelope} ->
        with {:ok, _sent} <-
               transition_from(run, expected_status, :sent, %{
                 sent_at: DateTime.utc_now(),
                 runner_connection_generation: generation
               }),
             :ok <-
               Emisar.Runners.deliver_to_runner(
                 run.account_id,
                 run.runner_id,
                 generation,
                 envelope
               ) do
          :ok
        else
          {:error, reason} = error ->
            Logger.warning("dispatch delivery failed run=#{run.id}: #{inspect(reason)}")
            error
        end

      {:error, :action_not_found} = error ->
        # A reconnect owns the socket before its runner_state catalog arrives.
        # Leave pending work retryable; the socket schedules another dispatch
        # after every successful catalog sync.
        error

      {:error, reason} ->
        # The exact pack snapshot is no longer trusted. Refuse instead of
        # silently upgrading the authorization decision to different bytes.
        mark_refused(
          run,
          "pack trust changed after this run was authorized — re-trust the pack in /app/packs and re-dispatch"
        )

        {:error, reason}
    end
  end

  defp run_action_payload(%ActionRun{} = run) do
    %{
      "type" => "run_action",
      "request_id" => run.request_id,
      "action_id" => run.action_id,
      "args" => runner_args(run),
      "opts" => run.opts || %{},
      # Use `run.reason` (the operator's freeform "why I'm running this")
      # — NOT `run.reason_text`, which holds cancel/error reasons that
      # are written only after the run completes. Reading reason_text
      # here was a longstanding bug: it was always nil at dispatch
      # time, so every cloud-dispatched envelope hit the runner's
      # "reason required" guard.
      "reason" => run.reason
    }
    |> maybe_put_signed_contract(run)
    |> maybe_put_attestation(run)
    |> maybe_put("expected_pack_hash", run.expected_pack_hash)
  end

  # Relay the client attestation (signed by the MCP, never the cloud) so an
  # enforcing runner can verify a real user authorized this run. The portal
  # only carries it through — it neither produces nor checks the signature.
  defp maybe_put_attestation(payload, %ActionRun{attestation: att}) when is_map(att),
    do: Map.put(payload, "attestation", att)

  defp maybe_put_attestation(payload, %ActionRun{}), do: payload

  defp runner_args(%ActionRun{args_raw: raw}), do: Jason.Fragment.new(raw)

  defp maybe_put_signed_contract(payload, %ActionRun{
         pack_ref: pack_ref,
         operation_id: operation_id
       }) do
    payload
    |> maybe_put("pack_ref", pack_ref)
    |> maybe_put("operation_id", operation_id)
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp authorized_run_action_payload(%ActionRun{expected_pack_hash: nil} = run),
    do: {:ok, run_action_payload(run)}

  defp authorized_run_action_payload(%ActionRun{} = run) do
    with :ok <- recheck_snapshotted_pack_trust(run),
         do: {:ok, run_action_payload(run)}
  end

  defp recheck_snapshotted_pack_trust(%ActionRun{} = run) do
    case fetch_advertised_action(run.runner_id, run.action_id, run.account_id) do
      {:ok, action} ->
        case check_pack_trust(action, run.account_id) do
          {:ok, hash} when is_nil(run.expected_pack_hash) or hash == run.expected_pack_hash ->
            :ok

          {:ok, _different_hash} ->
            {:error, :pack_untrusted}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :action_not_found} when is_nil(run.expected_pack_hash) ->
        :ok

      {:error, :action_not_found} ->
        {:error, :action_not_found}
    end
  end

  @doc """
  Internal — terminally refuse a run the cloud will not deliver (a versioned
  pack whose trusted hash is unavailable at send time). `:refused` + the
  human-readable cause in `error_message`, the same terminal state the runner's
  own pre-exec refusals map to.
  """
  def mark_refused(%ActionRun{} = run, reason) when is_binary(reason) do
    transition(run, :refused, %{finished_at: DateTime.utc_now(), error_message: reason})
  end

  @doc """
  Cloud-initiated cancellation. Marks the run as cancelling and tells
  the runner to terminate. Idempotent if the run is already terminal.
  """
  def cancel_run(%ActionRun{} = run, %Subject{} = subject, reason \\ nil) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.cancel_run_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, run.account_id) do
      cancel_run_for_status(run, subject, reason)
    end
  end

  defp cancel_run_for_status(%ActionRun{} = run, subject, reason) do
    reason = reason || "operator cancelled"

    Multi.new()
    |> request_run_cancellation_in_multi(run.id, reason)
    |> add_cancel_requested_audit(subject, reason)
    |> Emisar.Approvals.cancel_request_for_run_in_multi(run.id)
    |> Repo.commit_multi(
      after_commit: fn changes ->
        deliver_cancel_to_runner(changes.run_cancel, reason)
        broadcast_cancellation(changes.run_cancel)
        Emisar.Approvals.broadcast_request_cancelled(changes.request_cancel)
      end
    )
    |> cancellation_request_result()
  end

  # -- State transitions ----------------------------------------------
  #
  # These entry points are called only from already-authorized domain,
  # runner-socket, and job paths.

  @doc """
  Internal — terminally cancel an unsent `:pending`/`:pending_approval` run in
  a caller-owned transaction (Approvals deny + expiry). A run already sent to
  the runner returns `:run_already_dispatched`; its real outcome must remain
  runner-authoritative. The result lands in changes as `:run_cancel`:
  `{:cancelled, run}` when this call transitioned it, `{:noop, run}` when it was
  already terminal, or `:no_run` if the row is gone. Fires NO broadcast — a
  run broadcast or audit fan-out here would escape the enclosing transaction
  before it commits; the caller hoists `broadcast_cancelled_run/1` to its
  `commit_multi(after_commit:)` and the outer commit's fan_out delivers the
  audit event.
  """
  def cancel_run_in_multi(multi, run_id, reason \\ nil) when is_binary(run_id) do
    multi
    |> Multi.run(:run_cancel, fn repo, _changes -> cancel_run_locked(repo, run_id, reason) end)
    |> Multi.run(:run_cancel_audit, fn
      repo, %{run_cancel: {:cancelled, run}} -> repo.insert(Audit.run_event_changeset(run))
      _repo, %{run_cancel: _} -> {:ok, nil}
    end)
  end

  defp request_run_cancellation_in_multi(multi, run_id, reason) do
    multi
    |> Multi.run(:run_cancel, fn repo, _changes ->
      request_run_cancellation_locked(repo, run_id, reason)
    end)
    |> Multi.run(:run_cancel_audit, fn
      repo, %{run_cancel: {:cancelled, run}} -> repo.insert(Audit.run_event_changeset(run))
      _repo, %{run_cancel: _} -> {:ok, nil}
    end)
  end

  # The cancellation audit describes an actual state transition. A stale
  # cancellation may lock a run another writer already settled, which is a
  # no-op rather than a second cancellation request.
  defp add_cancel_requested_audit(multi, %Subject{} = subject, reason) do
    Multi.run(multi, :cancel_requested_audit, fn
      repo, %{run_cancel: {status, run}} when status in [:cancelled, :cancelling] ->
        repo.insert(Audit.Events.run_cancel_requested(subject, run, reason))

      _repo, %{run_cancel: _} ->
        {:ok, nil}
    end)
  end

  defp cancellation_request_result({:ok, %{run_cancel: {_outcome, run}}}), do: {:ok, run}
  defp cancellation_request_result({:ok, %{run_cancel: :no_run}}), do: {:error, :not_found}
  defp cancellation_request_result({:error, reason}), do: {:error, reason}

  # Publish a cancellation only after its state + audit record committed. A
  # dispatch that starts afterward then observes `:cancelled` and refuses to
  # publish an action instead of receiving this cancel before the action exists.
  defp deliver_cancel_to_runner({outcome, %ActionRun{} = run}, reason)
       when outcome in [:cancelling, :retry] do
    with {:ok, generation} <-
           Emisar.Runners.current_connection_generation(run.account_id, run.runner_id) do
      Emisar.Runners.deliver_to_runner(run.account_id, run.runner_id, generation, %{
        "type" => "cancel",
        "request_id" => run.request_id,
        "reason" => reason
      })
    end
  end

  defp deliver_cancel_to_runner(_, _reason), do: :ok

  defp broadcast_cancellation({outcome, %ActionRun{} = run})
       when outcome in [:cancelled, :cancelling],
       do: broadcast_run(run)

  defp broadcast_cancellation(_), do: :ok

  defp request_run_cancellation_locked(repo, run_id, reason) do
    loaded_run =
      ActionRun.Query.all()
      |> ActionRun.Query.by_id(run_id)
      |> ActionRun.Query.lock_for_update()
      |> repo.one()

    case loaded_run do
      nil ->
        {:ok, :no_run}

      %ActionRun{status: status} = run when status in [:pending, :pending_approval] ->
        cancel_loaded_run(repo, run, reason)

      %ActionRun{status: status} = run when status in [:sent, :running] ->
        with {:ok, cancelling} <-
               repo.update(
                 ActionRun.Changeset.transition(run, :cancelling, %{reason_text: reason})
               ) do
          {:ok, {:cancelling, cancelling}}
        end

      %ActionRun{status: :cancelling} = run ->
        {:ok, {:retry, run}}

      %ActionRun{} = run ->
        {:ok, {:noop, run}}
    end
  end

  defp cancel_run_locked(repo, run_id, reason) do
    loaded_run =
      ActionRun.Query.all()
      |> ActionRun.Query.by_id(run_id)
      |> ActionRun.Query.lock_for_update()
      |> repo.one()

    cond do
      is_nil(loaded_run) ->
        {:ok, :no_run}

      ActionRun.terminal?(loaded_run.status) ->
        {:ok, {:noop, loaded_run}}

      loaded_run.status in [:pending, :pending_approval] ->
        cancel_loaded_run(repo, loaded_run, reason)

      true ->
        {:error, :run_already_dispatched}
    end
  end

  defp cancel_loaded_run(repo, %ActionRun{} = loaded_run, reason) do
    with {:ok, cancelled} <-
           repo.update(
             ActionRun.Changeset.transition(loaded_run, :cancelled, cancelled_attrs(reason))
           ) do
      {:ok, {:cancelled, cancelled}}
    end
  end

  defp cancelled_attrs(reason),
    do: %{cancelled_at: DateTime.utc_now(), finished_at: DateTime.utc_now(), reason_text: reason}

  @doc """
  Internal — `Emisar.Runs.Jobs.DispatchTimeout` terminally fails a
  non-finished run (`:error` + `error_message`) when its dispatch can't
  complete: the runner was offline/disabled/removed, disconnected
  mid-run, or stayed online but never acknowledged the send past the
  redispatch deadline. The reason explains which, so the operator sees a
  terminal row with context instead of one stuck in `sent`/`running`
  forever. The transition is fenced to the caller's observed status so a
  stale timeout row cannot overwrite a cap-refused run that has returned to
  `:pending`.
  """
  def mark_errored(%ActionRun{status: status} = run, reason) when is_binary(reason) do
    if ActionRun.terminal?(status) do
      {:ok, run}
    else
      transition_from(run, status, :error, %{
        finished_at: DateTime.utc_now(),
        error_message: reason
      })
    end
  end

  # Unknown / missing status from the runner is treated as "failed" so
  # we still write a terminal row instead of leaving the run stuck.
  @result_statuses %{
    "success" => :success,
    "failed" => :failed,
    "error" => :error,
    "validation_failed" => :validation_failed,
    "unknown_action" => :unknown_action,
    "timed_out" => :timed_out,
    "cancelled" => :cancelled,
    "blocked_by_admission" => :refused,
    # The runner refused the dispatch on a trust check (bad/missing/stale
    # signature, or pack-hash mismatch) — a first-class terminal state distinct
    # from `:failed`; the human cause is carried in error_message.
    "signature_invalid" => :refused,
    "pack_hash_mismatch" => :refused
  }

  defp mark_finished(%ActionRun{} = run, result_payload, connection) do
    status = Map.get(@result_statuses, result_payload["status"], :failed)

    case transition_from(
           run,
           :any_nonterminal,
           status,
           result_attrs(run, result_payload),
           connection
         ) do
      {:ok, finished} = ok ->
        # If this run was part of a runbook execution, let the engine
        # decide whether the next wave fires — it no-ops while wave
        # peers are still in flight and halts on any failure (the failed
        # run surfaces on the runbook run page). Dispatch failures are
        # audited inside the engine. The wave's run events are system-origin
        # (no `%Subject{}`), so they carry no caller request context — the
        # runner's connect IP/UA can't bleed onto them.
        Emisar.Runbooks.dispatch_next_batch(finished)

        ok

      other ->
        other
    end
  end

  defp result_attrs(%ActionRun{} = run, payload) do
    current = peek_run_by_id(run.id) || run

    %{
      finished_at: DateTime.utc_now(),
      cancelled_at: cancelled_at(payload),
      exit_code: payload["exit_code"],
      duration_ms: payload["duration_ms"],
      timed_out: payload["timed_out"] || false,
      emitted_stdout_sha256: payload["emitted_stdout_sha256"],
      emitted_stderr_sha256: payload["emitted_stderr_sha256"],
      emitted_stdout_bytes: payload["emitted_stdout_bytes"],
      emitted_stderr_bytes: payload["emitted_stderr_bytes"],
      output_complete: output_complete?(current, payload),
      stdout_truncated: payload["truncated_stdout"] || false,
      stderr_truncated: payload["truncated_stderr"] || false,
      event_id: payload["event_id"],
      local_audit_failed: payload["local_audit_failed"] || false,
      # Exact shell command the runner ran, already redacted runner-side.
      executed_command: payload["executed_command"],
      executed_command_truncated: payload["executed_command_truncated"] || false,
      # The failure cause belongs in error_message (not reason_text, which holds
      # the operator's freeform reason). The runner sends a terse `reason` code
      # (e.g. "bad_signature", "stale") AND a human `error` sentence ("refused:
      # signature does not match…") on a refusal; prefer the sentence so the
      # operator can act, falling back to the code when there's no `error`
      # (omitempty drops it on an ordinary failure, so this stays the reason).
      error_message: payload["error"] || payload["reason"]
    }
  end

  defp cancelled_at(%{"status" => "cancelled"}), do: DateTime.utc_now()
  defp cancelled_at(_payload), do: nil

  defp output_complete?(%ActionRun{} = run, payload) do
    payload["dropped_progress_chunks"] in [nil, 0] and
      is_integer(payload["progress_chunks"]) and
      payload["progress_chunks"] == run.progress_event_count
  end

  defp transition(%ActionRun{} = run, status, attrs),
    do: transition_from(run, :any_nonterminal, status, attrs, nil)

  defp transition_from(%ActionRun{} = run, expected_status, status, attrs),
    do: transition_from(run, expected_status, status, attrs, nil)

  defp transition_from(%ActionRun{} = run, expected_status, status, attrs, connection) do
    if ActionRun.terminal?(run.status) do
      if expected_status == :any_nonterminal,
        do: {:ok, run},
        else: {:error, :not_dispatchable}
    else
      Multi.new()
      |> put_connection_guard(connection)
      |> Multi.run(:run, fn repo, _changes ->
        # The caller's struct can be stale: a runner result, an operator
        # cancel, and the timeout sweep race on the same row, and a late
        # writer must NOT overwrite a terminal status (or re-advance a
        # runbook). Re-read under the row lock and treat already-terminal
        # as a benign no-op.
        loaded_run =
          ActionRun.Query.all()
          |> ActionRun.Query.by_id(run.id)
          |> ActionRun.Query.lock_for_update()
          |> repo.one()

        cond do
          is_nil(loaded_run) ->
            {:error, :not_found}

          ActionRun.terminal?(loaded_run.status) and expected_status == :any_nonterminal ->
            {:ok, :already_terminal}

          ActionRun.terminal?(loaded_run.status) ->
            {:error, :not_dispatchable}

          expected_status != :any_nonterminal and loaded_run.status != expected_status ->
            {:error, :not_dispatchable}

          true ->
            repo.update(ActionRun.Changeset.transition(loaded_run, status, attrs))
        end
      end)
      |> put_run_audit_event()
      |> Repo.commit_multi(
        after_commit: fn
          %{run: :already_terminal} -> :ok
          %{run: run} -> after_run_committed(run)
        end
      )
      |> case do
        # The losing racer keeps the caller's struct — same contract as
        # the early guard above; the winner's broadcast carries truth.
        {:ok, %{run: :already_terminal}} -> {:ok, run}
        {:ok, %{run: run}} -> {:ok, run}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp put_connection_guard(multi, nil), do: multi

  defp put_connection_guard(
         multi,
         {account_id, runner_id, generation, lease_id}
       ) do
    Multi.run(multi, :runner_connection, fn repo, _changes ->
      case Emisar.Runners.fetch_and_lock_connection_owner(
             account_id,
             runner_id,
             generation,
             lease_id,
             repo: repo
           ) do
        {:ok, runner} -> {:ok, runner}
        {:error, :not_found} -> {:error, :connection_superseded}
      end
    end)
  end

  # Post-commit side effects for a run transition: broadcast the new state,
  # and emit run-outcome telemetry once the run reaches a terminal status
  # (intermediate :sent/:running transitions don't count an outcome).
  defp after_run_committed(%ActionRun{} = run) do
    broadcast_run(run)

    if ActionRun.terminal?(run.status) do
      Emisar.Telemetry.run_finished(run.status, run.duration_ms)
    end

    :ok
  end

  # Adds the run-event audit insert to a Multi, but only for statuses
  # worth auditing (see `@audited_run_statuses`). Returns `{:ok, nil}`
  # for the skipped intermediate states (and the already-terminal no-op)
  # so the transaction still commits and `fan_out_audit_events/1` simply
  # finds no event to broadcast.
  defp put_run_audit_event(multi) do
    Multi.run(multi, :audit, fn repo, %{run: run} ->
      if is_struct(run, ActionRun) and run.status in @audited_run_statuses do
        repo.insert(Audit.run_event_changeset(run))
      else
        {:ok, nil}
      end
    end)
  end

  # An optional decision event (today only `grant_used` — the standing-grant
  # fast path), committed in the SAME transaction as the run row + its terminal
  # event so a grant-dispatched action can't end up with no record of the grant
  # that let it through. `audit_fn` takes the inserted run and returns the event
  # changeset. The policy allow/deny/require_approval decisions no longer write
  # a separate row; their facts live on the run row and its terminal event.
  defp put_decision_audit(multi, nil), do: multi

  defp put_decision_audit(multi, audit_fn) when is_function(audit_fn, 1) do
    Multi.run(multi, :decision_audit, fn repo, %{run: run} ->
      if is_struct(run, ActionRun) do
        repo.insert(audit_fn.(run))
      else
        {:ok, nil}
      end
    end)
  end

  # -- Events (progress chunks) ----------------------------------------
  #
  # Called from the runner socket process — no Subject thread; the
  # socket-level token check is the auth gate.

  @doc "Internal — runner socket: marks a dispatched run accepted while the emitting socket owns its runner."
  def mark_started_from_connection(
        account_id,
        runner_id,
        generation,
        lease_id,
        request_id
      )
      when is_binary(request_id) do
    case fetch_run_by_request_id_for_runner(request_id, runner_id) do
      {:error, :not_found} ->
        {:error, :unknown_request_id}

      {:ok, %ActionRun{} = run} ->
        transition_from(
          run,
          :sent,
          :running,
          %{started_at: DateTime.utc_now()},
          {account_id, runner_id, generation, lease_id}
        )
    end
  end

  # Per-run progress ceiling. A dispatched runner is authenticated but treated
  # as hostile: without a cap it can append unbounded distinct-seq progress rows
  # (each already ≤256 KiB) and fan each onto the run's PubSub topic, exhausting
  # DB rows and socket memory. The budget is durable (counters on the run row)
  # and charged atomically under the run's row lock, so it holds across
  # reconnects and can't be raced by concurrent appends.
  @max_progress_events_per_run 50_000
  @max_progress_bytes_per_run 67_108_864

  @doc "Internal — runner socket: append a progress chunk to a dispatched, non-terminal run within its per-run budget (socket token is the gate, no web subject)."
  def append_event(%ActionRun{} = run, attrs), do: append_event(run, attrs, nil)

  def append_event(run_id, attrs) when is_binary(run_id) do
    case peek_run_by_id(run_id) do
      nil -> {:error, :unknown_run}
      %ActionRun{} = run -> append_event(run, attrs)
    end
  end

  defp append_event(%ActionRun{} = run, attrs, connection) do
    attrs = attrs |> Map.put(:run_id, run.id) |> Map.put(:account_id, run.account_id)
    event_bytes = progress_payload_bytes(attrs)

    Multi.new()
    |> put_connection_guard(connection)
    |> Multi.run(:run, fn repo, _changes ->
      # Re-read under the row lock: the caller's struct can be stale, and the
      # terminal-guard + budget check must judge (and charge) the CURRENT row so
      # concurrent appends can't each pass on a stale count.
      locked_run =
        ActionRun.Query.all()
        |> ActionRun.Query.by_id(run.id)
        |> ActionRun.Query.lock_for_update()

      case repo.fetch(locked_run, ActionRun.Query) do
        {:ok, loaded_run} ->
          cond do
            ActionRun.terminal?(loaded_run.status) ->
              {:error, :run_terminal}

            progress_budget_exceeded?(loaded_run, event_bytes) ->
              {:error, :progress_budget_exceeded}

            true ->
              {:ok, loaded_run}
          end

        {:error, :not_found} ->
          {:error, :unknown_run}
      end
    end)
    |> Multi.insert(:event, RunEvent.Changeset.create(attrs))
    |> Multi.update(:bump, fn %{run: loaded_run} ->
      ActionRun.Changeset.record_progress(loaded_run, event_bytes)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{run: loaded_run, event: event}} ->
        broadcast_run_event(run, event)

        # The first accepted chunk marks the run as :running (a separate locked
        # transition; idempotent server-side).
        if loaded_run.status == :sent do
          transition_from(
            run,
            :sent,
            :running,
            %{started_at: DateTime.utc_now()},
            connection
          )
        end

        {:ok, event}

      {:error, %Ecto.Changeset{} = changeset} ->
        # A re-sent chunk (same run_id + seq) hits the unique index — a benign
        # idempotent duplicate. Classify it as an atom so the caller drops it
        # quietly, while a genuinely malformed event still surfaces as a changeset.
        if Repo.Changeset.unique_constraint_error?(changeset),
          do: {:error, :duplicate_event},
          else: {:error, changeset}

      # Guard refusals are benign to the runner socket. The unique event index
      # rejects replays, while terminal progress counts reveal omitted chunks.
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Internal — appends progress only while the emitting socket owns the runner.
  In-flight handlers survive websocket reconnects, so the current owner may
  continue a run dispatched through an earlier connection generation.
  """
  def append_event_from_connection(
        run_id,
        attrs,
        account_id,
        runner_id,
        generation,
        lease_id
      )
      when is_binary(run_id) do
    case peek_run_by_id(run_id) do
      nil ->
        {:error, :unknown_run}

      %ActionRun{account_id: ^account_id, runner_id: ^runner_id} = run ->
        append_event(run, attrs, {account_id, runner_id, generation, lease_id})

      %ActionRun{} ->
        {:error, :unknown_run}
    end
  end

  # Serialized byte size of a progress event's payload — what the budget charges
  # (matching the per-event 256 KiB cap's measure). An absent/unencodable
  # payload charges 0; the changeset rejects a malformed one separately.
  defp progress_payload_bytes(attrs) do
    with payload when not is_nil(payload) <- Map.get(attrs, :payload),
         {:ok, json} <- Jason.encode(payload) do
      byte_size(json)
    else
      _ -> 0
    end
  end

  defp progress_budget_exceeded?(%ActionRun{} = run, event_bytes) do
    run.progress_event_count >= @max_progress_events_per_run or
      run.progress_byte_count + event_bytes > @max_progress_bytes_per_run
  end

  @doc """
  Internal — sibling flows (the Approvals decide/expiry transactions)
  and the event appender: the run row, nil-or-struct (`peek` — a run
  that vanished mid-flight is a meaningful no-op state for callers).
  """
  def peek_run_by_id(run_id) do
    ActionRun.Query.all()
    |> ActionRun.Query.by_id(run_id)
    |> Repo.peek()
  end

  @doc """
  Internal — Approvals decide: the approval-gated run. Raises if missing —
  the request row holds a foreign key to it, so absence is a broken
  invariant, not a caller-handleable state.
  """
  def fetch_run!(run_id) do
    ActionRun.Query.all()
    |> ActionRun.Query.by_id(run_id)
    |> Repo.fetch!(ActionRun.Query)
  end

  @doc """
  Internal — `Approvals.finalize_approved`: lock the gated run inside the
  approval transaction and confirm it's STILL `:pending_approval`. A cancel or
  expiry between parking and the approval makes it non-dispatchable, so the
  approve must abort rather than resurrect it. `{:ok, run}` only when still
  awaiting approval; `{:error, :run_not_pending_approval | :not_found}` else.
  Takes the transaction `repo` so the lock joins the caller's transaction.
  """
  def fetch_and_lock_pending_approval_run(repo, run_id) when is_binary(run_id) do
    loaded_run =
      ActionRun.Query.all()
      |> ActionRun.Query.by_id(run_id)
      |> ActionRun.Query.lock_for_update()
      |> repo.one()

    case loaded_run do
      %ActionRun{status: :pending_approval} = run -> {:ok, run}
      nil -> {:error, :not_found}
      %ActionRun{} -> {:error, :run_not_pending_approval}
    end
  end

  @doc """
  Internal -- Approvals releases its locked, approved run into a fresh
  `:pending` dispatch window. The caller passes its transaction repo so the
  request approval and run release commit atomically; resetting `queued_at`
  keeps timeouts measured from approval, not from when the human review began.
  """
  def release_pending_approval_run(%ActionRun{status: :pending_approval} = run, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    repo.update(ActionRun.Changeset.release_pending_approval(run))
  end

  @doc """
  Finalizes a result only while the emitting socket owns the runner. In-flight
  handlers and unacknowledged results survive websocket reconnects, so the
  current owner may finish a run dispatched through an earlier generation.
  Ownership and the terminal transition share one transaction.
  """
  def finalize_from_connection(
        account_id,
        runner_id,
        generation,
        lease_id,
        %{"request_id" => request_id} = result
      ) do
    case fetch_run_by_request_id_for_runner(request_id, runner_id) do
      {:error, :not_found} ->
        {:error, :unknown_request_id}

      {:ok, %ActionRun{} = run} ->
        mark_finished(run, result, {account_id, runner_id, generation, lease_id})
    end
  end

  def finalize_from_connection(_account_id, _runner_id, _generation, _lease_id, _msg),
    do: {:error, :missing_request_id}

  @doc """
  Progress events for a run, ordered by `seq`. Returns
  `{:ok, [event], %Paginator.Metadata{}}` per the standard `list_*`
  contract; the run is fetched via `fetch_run_by_id/3` first so the
  subject's account scope and permission gate apply.

  Accepts the same `:filter`/`:page` opts as `Emisar.Repo.list/3`; the
  caller may pass `page: [limit: n]` to bound the result for callers
  (run-detail render, MCP /events) that want all events on one page.
  """
  def list_events_for_run(run_id, %Subject{} = subject, opts \\ []) do
    with {:ok, _run} <- fetch_run_by_id(run_id, subject) do
      RunEvent.Query.all()
      |> RunEvent.Query.by_run_id(run_id)
      |> RunEvent.Query.ordered_by_seq()
      |> Repo.list(RunEvent.Query, opts)
    end
  end

  @doc """
  The most recent `limit` progress chunks for a run, in chronological
  (`seq`-ASC) order — a tail preview of a finished run's output. The run is
  fetched via `fetch_run_by_id/3` first so the subject's account scope and
  permission gate apply. Returns `{:ok, [event]}`.
  """
  def list_recent_events_for_run(run_id, limit, %Subject{} = subject) when is_integer(limit) do
    with {:ok, _run} <- fetch_run_by_id(run_id, subject) do
      events =
        RunEvent.Query.all()
        |> RunEvent.Query.by_run_id(run_id)
        |> RunEvent.Query.by_kind(:progress)
        |> RunEvent.Query.recent_by_seq(limit)
        |> Repo.all()
        |> Enum.reverse()

      {:ok, events}
    end
  end

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account's run create/transition feed (`{:run_updated, run}`)."
  def subscribe_account_runs(account_id),
    do: Emisar.PubSub.subscribe(account_runs_topic(account_id))

  def unsubscribe_account_runs(account_id),
    do: Emisar.PubSub.unsubscribe(account_runs_topic(account_id))

  @doc """
  Subscribe to one run's live updates — `{:run_updated, run}` transitions
  plus `{:run_event, event}` progress chunks. The topic carries the
  account id, so a subscriber can only name runs inside its own account.
  """
  def subscribe_run(account_id, run_id),
    do: Emisar.PubSub.subscribe(run_topic(account_id, run_id))

  def unsubscribe_run(account_id, run_id),
    do: Emisar.PubSub.unsubscribe(run_topic(account_id, run_id))

  defp account_runs_topic(account_id), do: "account:#{account_id}:runs"
  defp run_topic(account_id, run_id), do: "account:#{account_id}:run:#{run_id}"

  # Subscribers (RunDetailLive's meta strip, RunsLive table) need
  # `runner.name` to render — make `runner` preloaded part of the payload
  # contract so a `:run_updated` arriving after mount can cleanly replace
  # `@run` without re-introducing `%NotLoaded{}`.
  @doc """
  Internal — broadcast a run cancelled via `cancel_run_in_multi/3`, from the
  caller's `commit_multi(after_commit:)`. No-op for the already-terminal /
  no-run shapes (nothing changed, so there's nothing to announce).
  """
  def broadcast_cancelled_run({:cancelled, %ActionRun{} = run}), do: broadcast_run(run)
  def broadcast_cancelled_run(_), do: :ok

  defp broadcast_run(%ActionRun{} = run) do
    run =
      case run.runner do
        %Ecto.Association.NotLoaded{} -> Repo.preload(run, :runner)
        _ -> run
      end

    payload = {:run_updated, run}
    Emisar.PubSub.broadcast(run_topic(run.account_id, run.id), payload)
    Emisar.PubSub.broadcast(account_runs_topic(run.account_id), payload)
  end

  defp broadcast_run_event(%ActionRun{} = run, %RunEvent{} = event),
    do: Emisar.PubSub.broadcast(run_topic(run.account_id, run.id), {:run_event, event})

  # -- Authorization ----------------------------------------------------

  @doc "True when the subject may view runs (the console nav + section gate)."
  def subject_can_view_runs?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_runs_permission())

  @doc "Whether `subject` may dispatch action runs (operator+)."
  def subject_can_dispatch_run?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.dispatch_run_permission())

  @doc "Whether `subject` may cancel action runs (operator+)."
  def subject_can_cancel_run?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.cancel_run_permission())

  # -- Helpers ----------------------------------------------------------

  # Common policy-decision fields stamped on every dispatched run. The
  # caller may add :status / :requires_approval on top via Map.merge.
  defp policy_attrs(nil, decision, reason, matched) do
    %{
      policy_decision: decision,
      policy_reason: reason,
      matched_rules: matched
    }
  end

  defp policy_attrs(%Emisar.Policies.Policy{} = policy, decision, reason, matched) do
    %{
      policy_id: policy.id,
      policy_version: policy.vsn,
      policy_decision: decision,
      policy_reason: reason,
      matched_rules: matched
    }
  end
end
