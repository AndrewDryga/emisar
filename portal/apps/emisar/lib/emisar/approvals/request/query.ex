defmodule Emisar.Approvals.Request.Query do
  use Emisar, :query

  def all,
    do: from(requests in Emisar.Approvals.Request, as: :requests)

  def none(queryable), do: where(queryable, false)

  def by_id(queryable, id),
    do: where(queryable, [requests: r], r.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [requests: r], r.account_id == ^account_id)

  def by_run_id(queryable, run_id),
    do: where(queryable, [requests: r], r.run_id == ^run_id)

  def by_run_ids(queryable, run_ids) when is_list(run_ids),
    do: where(queryable, [requests: r], r.run_id in ^run_ids)

  def by_runbook_execution_id(queryable, execution_id),
    do: where(queryable, [requests: r], r.runbook_execution_id == ^execution_id)

  def by_runbook_execution_ids(queryable, execution_ids) when is_list(execution_ids),
    do: where(queryable, [requests: r], r.runbook_execution_id in ^execution_ids)

  def by_ids(queryable, ids) when is_list(ids),
    do: where(queryable, [requests: r], r.id in ^ids)

  def by_status(queryable, status),
    do: where(queryable, [requests: r], r.status == ^status)

  # PostgreSQL equivalent of Catalog.MCPProjection's canonical pack-ref
  # contract. Approval visibility is evaluated in SQL for pagination/counting,
  # so corrupt frozen identities must be rejected here rather than filtered
  # after the page has already been sliced.
  @canonical_pack_ref_pattern "^[a-z][a-z0-9_-]*@[0-9]+([.][0-9]+)*(-[0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?/sha256:[0-9a-f]{64}$"

  def by_target_access(queryable, %Emisar.Accounts.RunnerAccess{mode: :none}),
    do: where(queryable, [requests: _], false)

  # Long on purpose — do not "simplify to the Grant sibling's 4 lines". A grant
  # targets ONE runner and one pack_ref, so its filter decomposes trivially. A
  # request targets one of TWO shapes, and the second is the hard one: a
  # runbook-execution request is visible only when the execution HAS items and
  # NO item falls outside the caller's reach — the exists/not-exists pair below
  # is that all-items check, written as a double negation because SQL has no
  # FORALL. The four near-twin `case access` blocks cannot be extracted either:
  # dynamic/2 binds names literally (scope_runner vs scope_item_runner), and
  # parameterizing a binding name takes a macro, which costs more than the
  # repetition. Reviewed and kept, round 5 (2026-08-28).
  def by_target_access(
        queryable,
        %Emisar.Accounts.RunnerAccess{} = access
      ) do
    action_runner_allowed =
      case access do
        %Emisar.Accounts.RunnerAccess{mode: :all} ->
          dynamic([scope_runner: runner], not is_nil(runner.id))

        %Emisar.Accounts.RunnerAccess{
          mode: :restricted,
          runner_ids: runner_ids,
          groups: groups
        } ->
          dynamic(
            [scope_runner: runner],
            not is_nil(runner.id) and
              (runner.id in ^runner_ids or runner.group in ^groups)
          )
      end

    item_runner_allowed =
      case access do
        %Emisar.Accounts.RunnerAccess{mode: :all} ->
          dynamic([scope_item_runner: runner], not is_nil(runner.id))

        %Emisar.Accounts.RunnerAccess{
          mode: :restricted,
          runner_ids: runner_ids,
          groups: groups
        } ->
          dynamic(
            [scope_item_runner: runner],
            not is_nil(runner.id) and
              (runner.id in ^runner_ids or runner.group in ^groups)
          )
      end

    action_pack_allowed =
      case access do
        %Emisar.Accounts.RunnerAccess{pack_mode: :all} ->
          dynamic(
            [scope_run: run],
            is_nil(run.pack_ref) or
              fragment("? ~ ?", run.pack_ref, ^@canonical_pack_ref_pattern)
          )

        %Emisar.Accounts.RunnerAccess{pack_mode: :restricted, pack_ids: pack_ids} ->
          dynamic(
            [scope_run: run],
            fragment("? ~ ?", run.pack_ref, ^@canonical_pack_ref_pattern) and
              fragment("split_part(?, '@', 1)", run.pack_ref) in ^pack_ids
          )
      end

    item_pack_allowed =
      case access do
        %Emisar.Accounts.RunnerAccess{pack_mode: :all} ->
          dynamic(
            [runbook_execution_items: item],
            is_nil(item.pack_ref) or
              fragment("? ~ ?", item.pack_ref, ^@canonical_pack_ref_pattern)
          )

        %Emisar.Accounts.RunnerAccess{pack_mode: :restricted, pack_ids: pack_ids} ->
          dynamic(
            [runbook_execution_items: item],
            fragment("? ~ ?", item.pack_ref, ^@canonical_pack_ref_pattern) and
              fragment("split_part(?, '@', 1)", item.pack_ref) in ^pack_ids
          )
      end

    execution_item =
      Emisar.Runbooks.ExecutionItem.Query.all()
      |> where(
        [runbook_execution_items: item],
        item.runbook_execution_id == parent_as(:requests).runbook_execution_id and
          item.account_id == parent_as(:requests).account_id
      )
      |> select([runbook_execution_items: _item], 1)

    item_allowed =
      dynamic(
        [runbook_execution_items: item, scope_item_runner: runner],
        item.account_id == parent_as(:requests).account_id and
          runner.account_id == parent_as(:requests).account_id and
          ^item_runner_allowed and ^item_pack_allowed
      )

    disallowed_condition =
      dynamic(
        [runbook_execution_items: item],
        item.runbook_execution_id == parent_as(:requests).runbook_execution_id and
          not (^item_allowed)
      )

    disallowed_execution_item =
      Emisar.Runbooks.ExecutionItem.Query.all()
      |> with_named_binding(:scope_item_runner, fn queryable, binding ->
        join(
          queryable,
          :left,
          [runbook_execution_items: item],
          runner in ^Emisar.Runners.Runner.Query.not_deleted(),
          on: item.runner_id == runner.id,
          as: ^binding
        )
      end)
      |> where(^disallowed_condition)
      |> select([runbook_execution_items: _item], 1)

    target_allowed =
      dynamic(
        [requests: request, scope_run: run, scope_runner: runner],
        (not is_nil(request.run_id) and is_nil(request.runbook_execution_id) and
           run.account_id == request.account_id and runner.account_id == request.account_id and
           ^action_runner_allowed and ^action_pack_allowed) or
          (is_nil(request.run_id) and not is_nil(request.runbook_execution_id) and
             exists(execution_item) and not exists(disallowed_execution_item))
      )

    queryable
    |> with_named_binding(:scope_run, fn queryable, binding ->
      join(
        queryable,
        :left,
        [requests: request],
        run in ^Emisar.Runs.ActionRun.Query.all(),
        on: request.run_id == run.id,
        as: ^binding
      )
    end)
    |> with_named_binding(:scope_runner, fn queryable, binding ->
      join(
        queryable,
        :left,
        [scope_run: run],
        runner in ^Emisar.Runners.Runner.Query.not_deleted(),
        on: run.runner_id == runner.id,
        as: ^binding
      )
    end)
    |> where(^target_allowed)
  end

  def pending(queryable \\ all()),
    do: where(queryable, [requests: r], r.status == :pending)

  def decided(queryable \\ all()),
    do: where(queryable, [requests: r], r.status != :pending)

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [requests: r], desc: r.requested_at)

  def ordered_by_id(queryable \\ all()),
    do: order_by(queryable, [requests: r], asc: r.id)

  # Oldest deadline first, so a batched expiry sweep drains its backlog in the
  # order the requests lapsed. Matches the partial index the sweep's predicate
  # already uses (`approval_requests_pending_expires_at_idx`).
  def ordered_by_expires_at(queryable \\ all()),
    do: order_by(queryable, [requests: r], asc: r.expires_at)

  def requested_in_window(queryable, %DateTime{} = from, %DateTime{} = to),
    do: where(queryable, [requests: r], r.requested_at >= ^from and r.requested_at < ^to)

  @doc """
  One-row aggregate for the monthly report: every request filed in the window
  and its current outcome, counted with SQL FILTER so the context does no
  app-side summing. These outcome counts always reconcile to `requested`.
  """
  def status_totals(queryable) do
    select(queryable, [requests: r], %{
      requested: count(r.id),
      approved: filter(count(r.id), r.status == ^:approved),
      denied: filter(count(r.id), r.status == ^:denied),
      expired: filter(count(r.id), r.status == ^:expired),
      cancelled: filter(count(r.id), r.status == ^:cancelled),
      pending: filter(count(r.id), r.status == ^:pending)
    })
  end

  def limit_to(queryable, n), do: limit(queryable, ^n)

  def expired_at_at_or_before(queryable, now),
    do: where(queryable, [requests: r], not is_nil(r.expires_at) and r.expires_at <= ^now)

  @doc """
  Row lock for the finalize re-read in `record_decision` — the decision is
  taken on the LOCKED request row so concurrent votes serialize and a
  finalizing transition can't race another. `FOR NO KEY UPDATE`, matching the
  run-transition lock.
  """
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  @doc """
  Conditional UPDATE used by `claim_pending/4`: matches only rows still
  `status == "pending"` AND not past `expires_at` — so two concurrent
  operators racing to decide can't both win, and a request that lapsed
  past its expiry can't be approved in the window before the expiry sweep
  (which runs only every few minutes) flips it to `:expired`. The decision
  boundary is the row predicate here, not the sweep, so the advertised
  hard expiry holds even if the sweep is delayed. Mirrors how
  `Grant.Query.consumable_by_id/2` guards `expires_at` at consumption.
  """
  def decide_pending(id, status, by_user_id, reason, now) do
    all()
    |> where(
      [requests: r],
      r.id == ^id and r.status == :pending and
        (is_nil(r.expires_at) or r.expires_at > ^now)
    )
    |> update(
      set: [
        status: ^status,
        decided_by_id: ^by_user_id,
        decided_at: ^now,
        decision_reason: ^reason
      ]
    )
  end

  @doc """
  Conditional UPDATE for `expire_overdue_requests/1`: flips a still-pending
  expired request to `"expired"` with the cancel reason in
  `decision_reason`.
  """
  def expire_pending(id, now) do
    all()
    |> where(
      [requests: r],
      r.id == ^id and r.status == :pending and not is_nil(r.expires_at) and r.expires_at <= ^now
    )
    |> update(
      set: [
        status: :expired,
        decided_at: ^now,
        decision_reason: "pending approval window expired",
        updated_at: ^now
      ]
    )
  end

  @doc """
  Conditional UPDATE for `Approvals.cancel_request_for_run_in_multi/2`: flips a
  still-pending request whose gated RUN was cancelled to `"cancelled"`. Scoped
  by `run_id` (immutable) + `status == :pending` so it composes atomically into
  the run-cancel transaction and can't override an already-decided request.
  """
  def cancel_pending_by_run_id(run_id, now) do
    all()
    |> where([requests: r], r.run_id == ^run_id and r.status == :pending)
    |> update(
      set: [
        status: :cancelled,
        decided_at: ^now,
        decision_reason: "run cancelled before approval",
        updated_at: ^now
      ]
    )
  end

  def cancel_pending_by_ids(ids, now, reason) when is_list(ids) do
    all()
    |> where([requests: r], r.id in ^ids and r.status == :pending)
    |> update(
      set: [
        status: :cancelled,
        decided_at: ^now,
        decision_reason: ^reason,
        updated_at: ^now
      ]
    )
  end

  @doc """
  Conditional update for an execution-level cancellation. Its pending request
  becomes cancelled in the same transaction that closes the execution, so a
  stale approval cannot reactivate it afterward.
  """
  def cancel_pending_by_runbook_execution_id(execution_id, now) do
    all()
    |> where(
      [requests: r],
      r.runbook_execution_id == ^execution_id and r.status == :pending
    )
    |> update(
      set: [
        status: :cancelled,
        decided_at: ^now,
        decision_reason: "runbook execution cancelled before approval",
        updated_at: ^now
      ]
    )
  end

  @doc "Audit label-lookup helper. See Users.User.Query.select_labels/3."
  def select_labels(queryable, ids, field) do
    queryable
    |> where([requests: r], r.id in ^ids)
    |> select([requests: r], {r.id, field(r, ^field)})
  end

  @doc """
  Audit label projection: a request's name lives in its frozen `context`, not in
  one column, so the trail reads the map and lets `Approvals.request_name/1`
  word it. Mirrors `Policy.Query.select_audit_labels/2`.
  """
  def select_audit_labels(queryable, ids) do
    queryable
    |> where([requests: r], r.id in ^ids)
    |> select([requests: r], {r.id, r.context})
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:requests, :desc, :requested_at}, {:requests, :asc, :id}]
end
