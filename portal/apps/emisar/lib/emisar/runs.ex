defmodule Emisar.Runs do
  @moduledoc """
  Action run lifecycle. Cloud calls `dispatch_run/2` when an operator
  (or MCP, or a runbook step) wants to invoke an action; this module
  creates the run row, evaluates policy, hands the dispatch to the
  Transport for sending, and tracks progress + final result.
  """
  alias Ecto.Multi
  alias Emisar.{Audit, Auth, Crypto, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runs.{ActionRun, Authorizer, RunEvent}
  require Logger

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

      ActionRun.Query.all()
      |> apply_run_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, opts)
    end
  end

  @doc """
  Paginated top-N most recent runs for the dashboard tile. Default
  page size is 8 — the dashboard renders a short fixed list, not a
  scrolling table. Returns `{:ok, [run], %Paginator.Metadata{}}` per
  the context-function convention.

  Options: `preload:` — associations the caller renders (`:runner`,
  `:api_key`); `limit:` — page size (default 8).
  """
  def list_recent_runs(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      {preloads, opts} = Keyword.pop(opts, :preload, [])
      limit = Keyword.get(opts, :limit, 8)

      ActionRun.Query.all()
      |> apply_run_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, page: [limit: limit])
    end
  end

  @failed_statuses [:failed, :error, :timed_out]

  # Run statuses that earn an audit row. The intermediate lifecycle
  # states — pending, sent, running, pending_approval — are already
  # visible on the run's own timeline (status + queued/sent/started
  # timestamps + the event stream); duplicating each into the security
  # log just buried the policy decision and the final outcome under
  # five-rows-per-run noise. Only terminal results and policy denials
  # are audited as run events; the decision itself is captured by the
  # separate `policy.evaluated` row.
  @audited_run_statuses [
    :success,
    :failed,
    :error,
    :validation_failed,
    :unknown_action,
    :timed_out,
    :cancelled,
    :denied
  ]

  @doc """
  Rolled-up totals for the dashboard headline: total runs in window,
  successes, failures (failed/error/timed_out). Pending/running rows
  are excluded — only terminal outcomes count toward the success rate.
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
      %{total: total, success: success, failed: failed} =
        ActionRun.Query.all()
        |> ActionRun.Query.inserted_after(cutoff)
        |> ActionRun.Query.outcome_totals(@failed_statuses)
        |> Authorizer.for_subject(subject)
        |> Repo.one()

      terminal = success + failed

      {:ok,
       %{
         window_hours: hours,
         total: total,
         success: success,
         failed: failed,
         success_rate:
           if terminal > 0 do
             round(success * 100 / terminal)
           end
       }}
    end
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

  # Rendering concerns are the caller's: pass `preload:` only for the
  # associations the page actually shows. Unknown atoms raise (caller bug).
  defp apply_run_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :runner, queryable -> ActionRun.Query.with_preloaded_runner(queryable)
      :api_key, queryable -> ActionRun.Query.with_preloaded_api_key(queryable)
    end)
  end

  @doc """
  Looks up a run by `request_id` AND `runner_id`. Used by the runner
  socket so a runner can only see/mutate runs that were dispatched to
  it — never another runner's runs, even within the same account.
  """
  def fetch_run_by_request_id_for_runner(request_id, runner_id) do
    ActionRun.Query.all()
    |> ActionRun.Query.by_runner_id(runner_id)
    |> ActionRun.Query.by_request_id(request_id)
    |> Repo.fetch(ActionRun.Query)
  end

  # -- Creation ---------------------------------------------------------

  @doc """
  Create a run row in :pending state. Caller is responsible for
  triggering the transport to deliver `run_action` once the row is
  persisted (see Emisar.Transport).

  Returns `{:ok, run}` on a fresh insert, `{:replay, run}` when this
  call lost the race to a concurrent caller that already inserted with
  the same `(api_key_id, idempotency_key)` pair (the unique index is
  the actual correctness guarantee — the pre-flight peek in
  `dispatch_run/2` just spares us the work in the common case), or
  `{:error, changeset}` for any other validation failure.

  Internal — called by `dispatch_run/2` and tests. Tests can also call
  this directly to seed runs without exercising policy + dispatch.
  """
  def create_run(attrs, opts \\ []) do
    request_id = attrs[:request_id] || Crypto.run_request_id()
    attrs = Map.put(attrs, :request_id, request_id)
    attrs = Map.put(attrs, :queued_at, DateTime.utc_now())

    result =
      Multi.new()
      # ON CONFLICT on the partial idempotency index turns a concurrent
      # duplicate into RETURNING the winning row in the same statement —
      # no constraint rescue, no re-fetch. Rows without an
      # idempotency_key can't match the partial index and always insert;
      # the touched updated_at is the price of DO UPDATE ... RETURNING.
      |> Multi.insert(:run, ActionRun.Changeset.create(attrs),
        on_conflict: [set: [updated_at: DateTime.utc_now()]],
        conflict_target:
          {:unsafe_fragment, "(api_key_id, idempotency_key) WHERE idempotency_key IS NOT NULL"},
        returning: true
      )
      |> put_run_audit_event(request_id)
      |> put_decision_audit(request_id, opts[:audit])
      |> Repo.commit_multi()

    case result do
      # Fresh insert: RETURNING carries the request_id this call minted.
      {:ok, %{run: %ActionRun{request_id: ^request_id} = run}} ->
        broadcast_run(run)
        {:ok, run}

      # Conflict path: the returned row is the earlier winner's — replay.
      # No audit row, no broadcast; the original insert already did both.
      {:ok, %{run: %ActionRun{} = run}} ->
        {:replay, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
      dispatch_run_for_account(attrs, account_id)
    end
  end

  @doc """
  Internal: dispatch a run for an explicit account with no `%Subject{}`.
  Used by the runbook engine to continue a chain from the post-`mark_finished`
  callback, where no user is in scope — the originating dispatch already
  authorized the operator and validated runner scope (the continuation passes
  `requested_by_membership_id: nil`, which bypasses the per-membership scope
  check that first dispatch already enforced).
  """
  def dispatch_run_for_account(attrs, account_id) when is_binary(account_id) do
    attrs = Map.put(attrs, :account_id, account_id)
    runner_id = attrs[:runner_id]
    action_id = attrs[:action_id]
    reason = attrs[:reason]
    membership_id = Map.get(attrs, :requested_by_membership_id)

    with :none <- peek_idempotent_run(attrs),
         :ok <- require_runner(runner_id),
         :ok <- require_action(action_id),
         :ok <- require_reason(reason),
         :ok <- runner_in_account(runner_id, account_id),
         :ok <- runner_in_membership_scope(runner_id, account_id, membership_id),
         {:ok, action} <- fetch_advertised_action(runner_id, action_id, account_id),
         :ok <- check_pack_trust(action, account_id) do
      attrs
      |> Map.delete(:requested_by_membership_id)
      |> Map.put(:args_sha256, args_sha256(attrs[:args]))
      |> Map.put(:requires_approval, false)
      |> evaluate_and_dispatch(account_id, action)
    else
      {:replay, run} -> replay_outcome(run)
      other -> other
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
    run = fetch_run!(run_id)

    case fetch_advertised_action(run.runner_id, run.action_id, run.account_id) do
      {:ok, action} ->
        check_pack_trust(action, run.account_id)

      {:error, :action_not_found} ->
        # The runner no longer advertises this action (offline / pack
        # unloaded) — the dispatch itself will fail to reach a live action,
        # so there is nothing to ship the wrong bytes to. The threat this
        # gate closes is an advertised pack that DRIFTED to :pending; that
        # path returns the action above and is refused by check_pack_trust.
        :ok
    end
  end

  # If the caller supplied an Idempotency-Key on this api_key, an earlier
  # call that won the unique-index race owns the run. We re-shape the
  # cached row into the same `{:ok, status_atom, run}` tuple the live
  # dispatch path would return, so MCP responses are byte-identical
  # whether the caller retried or made a fresh call.
  defp peek_idempotent_run(%{api_key_id: api_key_id, idempotency_key: key})
       when is_binary(api_key_id) and is_binary(key) and key != "" do
    query =
      ActionRun.Query.all()
      |> ActionRun.Query.by_api_key_id(api_key_id)
      |> ActionRun.Query.by_idempotency_key(key)

    case Repo.peek(query) do
      nil -> :none
      %ActionRun{} = run -> {:replay, run}
    end
  end

  defp peek_idempotent_run(_attrs), do: :none

  # Re-shapes a cached run into the same outcome tuple the original
  # dispatch call returned, so a retried-after-the-fact request gets a
  # byte-identical response. Cases:
  #
  #   * `denied` — policy already rejected; return the deny tuple so MCP
  #     renders it as `denied_by_policy` rather than as a running run.
  #   * `pending_approval` / `awaiting_approval` — block on the same
  #     approval; `wait_for_run` is still the right tool.
  #   * anything else (sent, running, terminal) — the run exists and the
  #     LLM can long-poll via `/runs/:id?wait=…` for the final state.
  defp replay_outcome(%ActionRun{status: :denied, policy_reason: reason}),
    do: {:error, :denied_by_policy, reason || "policy denied this call"}

  defp replay_outcome(%ActionRun{status: status} = run)
       when status in [:pending_approval, :awaiting_approval],
       do: {:ok, :pending_approval, run}

  defp replay_outcome(%ActionRun{} = run),
    do: {:ok, :running, run}

  # Per-user runner ACLs (v1). When the caller supplies a
  # `requested_by_membership_id`, the membership's runner scopes must
  # include this runner. Operator UI AND MCP both supply it — an
  # `emk-`/OAuth key carries its creator's membership
  # (`created_by_membership_id`, set at mint), so revoking a user's scope
  # shrinks every key they minted. Do NOT "simplify" MCP to pass nil here:
  # nil means "no per-user scope" (the system / runbook-continuation
  # dispatch, which has no user), and routing a scoped key through it would
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

  # Authoritative lookup. The runner has already advertised this action
  # via `Catalog.observe_state`; if the catalog row is missing the
  # action simply doesn't exist on that runner and we refuse to dispatch.
  defp fetch_advertised_action(runner_id, action_id, account_id) do
    case Emisar.Catalog.fetch_action_for_account(action_id, runner_id, account_id) do
      {:error, :not_found} -> {:error, :action_not_found}
      {:ok, action} -> {:ok, action}
    end
  end

  # Refuse dispatch if the action's pack is in `pending_trust`. The
  # runner is advertising a hash that diverges from what an operator
  # has previously trusted (or from the baseline we ship) — execution
  # waits for a human decision in the /app/packs UI.
  defp check_pack_trust(action, account_id) do
    case Emisar.Catalog.check_pack_trusted(action) do
      :ok ->
        :ok

      {:error, :pack_untrusted, %{} = pack_info} ->
        Audit.record(Audit.Events.dispatch_blocked_pack_untrusted(account_id, pack_info, action))
        {:error, :pack_untrusted}
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

  # Store a denied row for the audit trail even though we never reach
  # the runner — operators need to see attempts that policy rejected.
  defp dispatch_deny(attrs, policy, reason, matched) do
    run_attrs =
      attrs
      |> Map.merge(policy_attrs(policy, "deny", reason, matched))
      |> Map.put(:status, :denied)

    audit = &Audit.Events.policy_evaluated(&1, policy, "deny", reason, matched)

    case create_run(run_attrs, audit: audit) do
      {:ok, _denied} ->
        {:error, :denied_by_policy, reason}

      {:replay, run} ->
        # Concurrent retry under the same Idempotency-Key — the original
        # already logged the deny; surface its outcome verbatim.
        replay_outcome(run)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp dispatch_allow(attrs, policy, reason, matched) do
    attrs = Map.merge(attrs, policy_attrs(policy, "allow", reason, matched))
    audit = &Audit.Events.policy_evaluated(&1, policy, "allow", reason, matched)

    # The policy.evaluated decision commits in the SAME transaction as the
    # run (create_run's Multi), so the trail reads decision → outcome and a
    # dispatched action can never lack its decision record. Dispatch to the
    # runner only after that transaction is durable.
    case create_run(attrs, audit: audit) do
      {:ok, run} ->
        with :ok <- dispatch_to_runner(run) do
          {:ok, :running, run}
        end

      {:replay, run} ->
        # Original already pushed the run_action envelope to the runner;
        # re-pushing would duplicate-execute, so skip dispatch + just
        # echo the existing row's outcome.
        replay_outcome(run)

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
    case lookup_grant(attrs) do
      {:matched, grant} ->
        attrs = Map.merge(attrs, policy_attrs(policy, "allow", "matched approval grant", matched))
        audit = &Audit.Events.grant_used(&1, grant, policy)

        # Same atomicity as the allow path: the grant_used decision commits
        # with the run row, before the run reaches the runner.
        case create_run(attrs, audit: audit) do
          {:ok, run} ->
            with :ok <- dispatch_to_runner(run) do
              {:ok, :running, run}
            end

          {:replay, run} ->
            replay_outcome(run)

          {:error, changeset} ->
            {:error, changeset}
        end

      :none ->
        attrs =
          attrs
          |> Map.merge(policy_attrs(policy, "require_approval", policy_reason, matched))
          |> Map.merge(%{status: :pending_approval, requires_approval: true})

        audit =
          &Audit.Events.policy_evaluated(&1, policy, "require_approval", policy_reason, matched)

        # Operator's reason ("why I'm running this") goes to the approval
        # request; the policy reason ("why approval is required") stays
        # on run.policy_reason for the reviewer to see separately. The
        # require_approval decision commits atomically with the run.
        case create_run(attrs, audit: audit) do
          {:ok, run} ->
            with {:ok, _req} <-
                   Emisar.Approvals.create_request(run, attrs[:requested_by_id], attrs[:reason]) do
              {:ok, :pending_approval, run}
            end

          {:replay, run} ->
            replay_outcome(run)

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp lookup_grant(%{api_key_id: api_key_id} = attrs) when is_binary(api_key_id) do
    case Emisar.Approvals.peek_matching_grant(
           api_key_id,
           attrs[:action_id],
           attrs[:runner_id],
           attrs[:args_sha256]
         ) do
      %{} = grant ->
        if Emisar.Approvals.use_grant(grant) == :ok, do: {:matched, grant}, else: :none

      _ ->
        :none
    end
  end

  defp lookup_grant(_attrs), do: :none

  defp args_sha256(args), do: Crypto.hash_hex(Jason.encode!(args || %{}))

  @doc """
  Internal — used by `Emisar.Workers.RunDispatchTimeout` to find runs
  that have been sitting in `pending` / `sent` longer than the
  dispatch threshold. Returns a plain list (no pagination); the worker
  iterates and decides per-run whether to time it out based on the
  runner's current state.
  """
  def list_stale_dispatches(cutoff) when is_struct(cutoff, DateTime) do
    ActionRun.Query.all()
    |> ActionRun.Query.status_in([:pending, :sent])
    |> ActionRun.Query.queued_before(cutoff)
    |> Repo.all()
  end

  @doc """
  Internal — used by `Emisar.Workers.RunDispatchTimeout` to find in-flight
  runs whose runner may have died mid-run. Plain list (real fleets keep few
  runs in flight); the worker decides per-run from the runner's presence and
  disconnect history.
  """
  def list_running_runs do
    ActionRun.Query.all()
    |> ActionRun.Query.status_in([:running])
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
  Re-emits the run_action envelope onto the runner's PubSub topic. Used
  both for fresh dispatches and for the approve→send transition.
  Internal — called from `dispatch_run/2` and `Approvals.approve_request/4`.
  """
  def dispatch_to_runner(%ActionRun{} = run) do
    payload = %{
      "type" => "run_action",
      "request_id" => run.request_id,
      "action_id" => run.action_id,
      "args" => run.args,
      "opts" => run.opts || %{},
      # Use `run.reason` (the operator's freeform "why I'm running this")
      # — NOT `run.reason_text`, which holds cancel/error reasons that
      # are written only after the run completes. Reading reason_text
      # here was a longstanding bug: it was always nil at dispatch
      # time, so every cloud-dispatched envelope hit the runner's
      # "reason required" guard.
      "reason" => run.reason
    }

    Emisar.Runners.deliver_to_runner(
      run.account_id,
      run.runner_id,
      maybe_stamp_pack_hash(payload, run)
    )

    # The envelope is already on the runner's topic, so we can't un-send it
    # if the DB write fails — but a dropped `mark_sent` leaves the runner
    # executing while the row stays un-`sent`. Surface that mismatch instead
    # of swallowing it (the run still shows un-sent until the runner reports
    # progress, which flips it to :running).
    case mark_sent(run) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "mark_sent failed for run #{run.id} after envelope delivered: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Stamp the trusted pack hash into the wire envelope so the runner
  # can re-hash its on-disk pack and refuse a dispatch whose bytes
  # don't match what cloud trusts. We fetch the catalog action scoped to
  # the run's own account (no Subject) because this runs inside an
  # already-authorized dispatch path — the caller's auth already passed;
  # we're just enriching the wire payload with a side-channel fact
  # (trusted hash on file).
  #
  # If anything's missing — catalog row gone, pack_version not yet
  # populated, no trusted hash yet — we omit the key, and the runner
  # skips its trust gate (same as a fresh runner pre-Phase 2). The
  # operator-facing trust gate already ran upstream (`check_pack_trust`
  # in the with-chain), so omitting here only widens the window during
  # the brief moment when a hash is in flux; the upstream gate stays
  # closed.
  defp maybe_stamp_pack_hash(payload, %ActionRun{} = run) do
    with {:ok, action} <-
           Emisar.Catalog.fetch_action_for_account(run.action_id, run.runner_id, run.account_id),
         hash when is_binary(hash) <- Emisar.Catalog.trusted_hash_for_action(action) do
      Map.put(payload, "expected_pack_hash", hash)
    else
      _ -> payload
    end
  end

  @doc """
  Cloud-initiated cancellation. Marks the run as cancelling and tells
  the runner to terminate. Idempotent if the run is already terminal.
  """
  def cancel_run(%ActionRun{status: status} = run, %Subject{} = subject, reason \\ nil) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.cancel_run_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, run.account_id) do
      if ActionRun.terminal?(status) do
        {:ok, run}
      else
        Emisar.Runners.deliver_to_runner(run.account_id, run.runner_id, %{
          "type" => "cancel",
          "request_id" => run.request_id,
          "reason" => reason
        })

        Audit.record(Audit.Events.run_cancel_requested(subject, run, reason))
        mark_cancelled(run, reason || "operator cancelled")
      end
    end
  end

  # -- State transitions ----------------------------------------------
  #
  # These are called from inside `dispatch_run/2`, the runner socket
  # process, and the runbook engine — all already-authorized paths.

  def mark_sent(%ActionRun{} = run) do
    transition(run, :sent, %{sent_at: DateTime.utc_now()})
  end

  def mark_running(%ActionRun{} = run) do
    transition(run, :running, %{started_at: DateTime.utc_now()})
  end

  def mark_cancelled(%ActionRun{} = run, reason \\ nil) do
    transition(run, :cancelled, %{
      cancelled_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      reason_text: reason
    })
  end

  @doc """
  Internal — called by `Emisar.Workers.RunDispatchTimeout` when a run
  has been sitting in `pending` / `sent` longer than the dispatch
  threshold and the target runner is offline. Flips the run to
  `:error` with an explanatory `error_message` so the operator sees
  *something* instead of a row stuck in "sent" forever.
  """
  def mark_runner_unreachable(%ActionRun{} = run, reason) when is_binary(reason) do
    transition(run, :error, %{finished_at: DateTime.utc_now(), error_message: reason})
  end

  # Unknown / missing status from the runner is treated as "failed" so
  # we still write a terminal row instead of leaving the run stuck.
  @result_statuses %{
    "success" => :success,
    "failed" => :failed,
    "error" => :error,
    "validation_failed" => :validation_failed,
    "unknown_action" => :unknown_action,
    "cancelled" => :cancelled
  }

  def mark_finished(%ActionRun{} = run, result_payload) do
    status = Map.get(@result_statuses, result_payload["status"], :failed)

    case transition(run, status, result_attrs(result_payload)) do
      {:ok, finished} = ok ->
        # If this run was part of a runbook execution, let the engine
        # decide whether the next wave fires — it no-ops while wave
        # peers are still in flight and halts on any failure (the failed
        # run surfaces on the runbook run page). Dispatch failures are
        # audited inside the engine. The wave's policy.evaluated rows are
        # system-origin (no `%Subject{}`), so they carry no request
        # context — the runner's connect IP/UA can't bleed onto them.
        Emisar.Runbooks.dispatch_next_batch(finished)

        ok

      other ->
        other
    end
  end

  defp result_attrs(payload) do
    %{
      finished_at: DateTime.utc_now(),
      exit_code: payload["exit_code"],
      duration_ms: payload["duration_ms"],
      timed_out: payload["timed_out"] || false,
      stdout_sha256: payload["stdout_sha256"],
      stderr_sha256: payload["stderr_sha256"],
      stdout_bytes: payload["stdout_bytes"],
      stderr_bytes: payload["stderr_bytes"],
      event_id: payload["event_id"],
      # Exact shell command the runner ran, already redacted runner-side.
      executed_command: payload["executed_command"],
      # The runner's `reason` on non-success results is the failure cause
      # (e.g. validation message). It belongs in error_message, not in
      # reason_text — which holds the operator's freeform reason.
      error_message: payload["reason"]
    }
  end

  defp transition(%ActionRun{} = run, status, attrs) do
    if ActionRun.terminal?(run.status) do
      # Cheap idempotent guard on the caller's struct. The authoritative
      # check is the locked re-read below — this just spares the round
      # trip when the caller already sees a final run.
      {:ok, run}
    else
      Multi.new()
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
          is_nil(loaded_run) -> {:error, :not_found}
          ActionRun.terminal?(loaded_run.status) -> {:ok, :already_terminal}
          true -> repo.update(ActionRun.Changeset.transition(loaded_run, status, attrs))
        end
      end)
      |> put_run_audit_event()
      |> Repo.commit_multi(
        after_commit: fn
          %{run: :already_terminal} -> :ok
          %{run: run} -> broadcast_run(run)
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

  # Adds the run-event audit insert to a Multi, but only for statuses
  # worth auditing (see `@audited_run_statuses`). Returns `{:ok, nil}`
  # for the skipped intermediate states (and the already-terminal no-op)
  # so the transaction still commits and `fan_out_audit_events/1` simply
  # finds no event to broadcast.
  # With `fresh_request_id` (the create_run upsert), the audit row is
  # skipped on an idempotency replay — the returned row carries the
  # original request_id, and the original insert already audited it.
  defp put_run_audit_event(multi, fresh_request_id \\ nil) do
    Multi.run(multi, :audit, fn repo, %{run: run} ->
      fresh? = is_nil(fresh_request_id) or run.request_id == fresh_request_id

      if is_struct(run, ActionRun) and fresh? and run.status in @audited_run_statuses do
        repo.insert(Audit.run_event_changeset(run))
      else
        {:ok, nil}
      end
    end)
  end

  # The policy.evaluated / grant_used decision event, committed in the SAME
  # transaction as the run row (and the run's state-transition event above)
  # so a dispatched action can't end up with no record of the decision that
  # let it through. `audit_fn` takes the inserted run and returns the event
  # changeset. Skipped on the idempotency-replay path (same `fresh?` guard
  # as the run event) — the original insert already logged the decision.
  defp put_decision_audit(multi, _fresh_request_id, nil), do: multi

  defp put_decision_audit(multi, fresh_request_id, audit_fn) when is_function(audit_fn, 1) do
    Multi.run(multi, :decision_audit, fn repo, %{run: run} ->
      fresh? = is_nil(fresh_request_id) or run.request_id == fresh_request_id

      if is_struct(run, ActionRun) and fresh? do
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

  def append_event(%ActionRun{} = run, attrs) do
    attrs = Map.put(attrs, :run_id, run.id) |> Map.put(:account_id, run.account_id)

    RunEvent.Changeset.create(attrs)
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        broadcast_run_event(run, event)

        # The first progress chunk marks the run as :running (transitions
        # are idempotent server-side).
        if run.status == :sent, do: mark_running(run)
        {:ok, event}

      err ->
        err
    end
  end

  def append_event(run_id, attrs) when is_binary(run_id) do
    case peek_run_by_id(run_id) do
      nil -> {:error, :unknown_run}
      %ActionRun{} = run -> append_event(run, attrs)
    end
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
  Translates an inbound `action_result` envelope into a state transition
  on the matching ActionRun. Scoped by runner_id so a runner can only
  finalize runs that were dispatched to it. Returns
  `{:error, :unknown_request_id}` if no matching run exists.

  Internal — called from the runner socket.
  """
  def finalize_from_result(runner_id, %{"request_id" => request_id} = result) do
    case fetch_run_by_request_id_for_runner(request_id, runner_id) do
      {:error, :not_found} -> {:error, :unknown_request_id}
      {:ok, %ActionRun{} = run} -> mark_finished(run, result)
    end
  end

  def finalize_from_result(_runner_id, _msg),
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

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account's run create/transition feed (`{:run_updated, run}`)."
  def subscribe_account_runs(account_id),
    do: Emisar.PubSub.subscribe(account_runs_topic(account_id))

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
