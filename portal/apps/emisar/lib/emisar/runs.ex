defmodule Emisar.Runs do
  @moduledoc """
  Action run lifecycle. Cloud calls `dispatch_run/2` when an operator
  (or MCP, or a runbook step) wants to invoke an action; this module
  creates the run row, evaluates policy, hands the dispatch to the
  Transport for sending, and tracks progress + final result.
  """

  require Logger

  alias Ecto.Multi
  alias Emisar.{Audit, Auth, PubSub, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runs.{ActionRun, Authorizer, RunEvent}
  alias Emisar.Runners.Runner

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
      ActionRun.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, Keyword.put_new(opts, :preload, [:runner, :api_key]))
    end
  end

  @doc """
  Paginated top-N most recent runs for the dashboard tile. Default
  page size is 8 — the dashboard renders a short fixed list, not a
  scrolling table. Returns `{:ok, [run], %Paginator.Metadata{}}` per
  the context-function convention; runner is preloaded for label
  rendering.
  """
  def list_recent_runs(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      limit = Keyword.get(opts, :limit, 8)
      page = [limit: limit]

      ActionRun.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, preload: [:runner], page: page)
    end
  end

  @failed_statuses ~w[failed error timed_out]

  # Run statuses that earn an audit row. The intermediate lifecycle
  # states — pending, sent, running, pending_approval — are already
  # visible on the run's own timeline (status + queued/sent/started
  # timestamps + the event stream); duplicating each into the security
  # log just buried the policy decision and the final outcome under
  # five-rows-per-run noise. Only terminal results and policy denials
  # are audited as run events; the decision itself is captured by the
  # separate `policy.evaluated` row.
  @audited_run_statuses ~w[success failed error validation_failed unknown_action timed_out cancelled denied]

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

      rows =
        ActionRun.Query.all()
        |> ActionRun.Query.inserted_after(cutoff)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      total = length(rows)
      success = Enum.count(rows, &(&1.status == "success"))
      failed = Enum.count(rows, &(&1.status in @failed_statuses))
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
      ActionRun.Query.all()
      |> ActionRun.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(ActionRun.Query, Keyword.put_new(opts, :preload, [:runner, :api_key]))
    else
      false -> {:error, :not_found}
      other -> other
    end
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
  def create_run(attrs) do
    request_id = attrs[:request_id] || generate_request_id()
    attrs = Map.put(attrs, :request_id, request_id)
    attrs = Map.put(attrs, :queued_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

    result =
      Multi.new()
      |> Multi.insert(:run, ActionRun.Changeset.create(attrs))
      |> put_run_audit_event()
      |> Repo.commit_multi(after_commit: fn %{run: run} -> PubSub.broadcast_run(run) end)

    case result do
      {:ok, %{run: run}} ->
        {:ok, run}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if idempotency_conflict?(errors) do
          # The winning concurrent insert created the row; re-fetch and
          # report the replay so the caller can return the original
          # outcome instead of bubbling a confusing constraint error.
          case peek_idempotent_run(attrs) do
            {:replay, run} -> {:replay, run}
            # Theoretical race: the conflicting row was deleted between
            # the failed insert and our re-fetch. Fall through to the
            # original error so the caller doesn't silently swallow it.
            :none -> {:error, cs}
          end
        else
          {:error, cs}
        end
    end
  end

  # Matches the `unique_constraint([:api_key_id, :idempotency_key], …)`
  # in `ActionRun.Changeset.create/1`. Other unique-index hits
  # (`request_id`, etc.) are NOT idempotency replays and should still
  # propagate as changeset errors.
  defp idempotency_conflict?(errors) do
    Enum.any?(errors, fn
      {:api_key_id, {_, opts}} ->
        Keyword.get(opts, :constraint_name) == "action_runs_api_key_idempotency_key_index"

      _ ->
        false
    end)
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
           {:ok, action} <- fetch_advertised_action(runner_id, action_id, subject),
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
  end

  # If the caller supplied an Idempotency-Key on this api_key, an earlier
  # call that won the unique-index race owns the run. We re-shape the
  # cached row into the same `{:ok, status_atom, run}` tuple the live
  # dispatch path would return, so MCP responses are byte-identical
  # whether the caller retried or made a fresh call.
  defp peek_idempotent_run(%{api_key_id: api_key_id, idempotency_key: key})
       when is_binary(api_key_id) and is_binary(key) and key != "" do
    case ActionRun.Query.all()
         |> ActionRun.Query.by_api_key_id(api_key_id)
         |> ActionRun.Query.by_idempotency_key(key)
         |> Repo.peek() do
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
  defp replay_outcome(%ActionRun{status: "denied", policy_reason: reason}),
    do: {:error, :denied_by_policy, reason || "policy denied this call"}

  defp replay_outcome(%ActionRun{status: status} = run)
       when status in ["pending_approval", "awaiting_approval"],
       do: {:ok, :pending_approval, run}

  defp replay_outcome(%ActionRun{} = run),
    do: {:ok, :running, run}

  # Per-user runner ACLs (v1). If the caller is operator-driven and
  # supplies `requested_by_membership_id`, the membership's runner
  # scopes must include this runner. MCP/system paths pass nil and
  # bypass — their own auth gate (api_key.runner_filter +
  # runner_group_filter) is the relevant check there.
  # `runner_in_account/2` runs first in the with chain, so the runner
  # is guaranteed to belong to `account_id` by the time we get here.
  defp runner_in_membership_scope(_runner_id, _account_id, nil), do: :ok

  defp runner_in_membership_scope(runner_id, _account_id, membership_id) do
    case Emisar.Accounts.runner_scopes_for_membership(membership_id) do
      [] ->
        :ok

      scopes ->
        with {:ok, runner} <- Emisar.Runners.peek_runner_by_id(runner_id) do
          if Emisar.Accounts.runner_in_scope?(runner, scopes),
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
    if runner_belongs_to_account?(runner_id, account_id) do
      :ok
    else
      {:error, :runner_not_found}
    end
  end

  # Authoritative lookup. The runner has already advertised this action
  # via `Catalog.observe_state`; if the catalog row is missing the
  # action simply doesn't exist on that runner and we refuse to dispatch.
  defp fetch_advertised_action(runner_id, action_id, %Subject{} = subject) do
    case Emisar.Catalog.fetch_action_by_id(action_id, runner_id, subject) do
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

      {:error, :pack_untrusted, %{id: pv_id, pack_id: pack_id, version: version}} ->
        Emisar.Audit.log(account_id, :dispatch_blocked_pack_untrusted,
          actor_kind: "system",
          subject_kind: "pack_version",
          subject_id: pv_id,
          subject_label: "#{pack_id}@#{version}",
          payload: %{
            pack_id: pack_id,
            version: version,
            action_id: action.action_id,
            runner_id: action.runner_id
          }
        )

        {:error, :pack_untrusted}
    end
  end

  # The policy sees catalog-authoritative risk + kind so a caller can't
  # spoof "low" to bypass a `:require_approval` on `high`.
  defp evaluate_and_dispatch(attrs, account_id, action) do
    eval_attrs = Map.merge(attrs, %{risk: action.risk, kind: action.kind})

    case Emisar.Policies.evaluate_with_policy(account_id, eval_attrs) do
      {:deny, matched, reason, policy} ->
        dispatch_deny(attrs, policy, reason, matched)

      {:allow, matched, reason, policy} ->
        dispatch_allow(attrs, policy, reason, matched)

      {:require_approval, matched, reason, policy} ->
        dispatch_require_approval(attrs, policy, reason, matched)
    end
  end

  # Store a denied row for the audit trail even though we never reach
  # the runner — operators need to see attempts that policy rejected.
  defp dispatch_deny(attrs, policy, reason, matched) do
    run_attrs =
      attrs
      |> Map.merge(policy_attrs(policy, "deny", reason, matched))
      |> Map.put(:status, "denied")

    case create_run(run_attrs) do
      {:ok, denied} ->
        log_policy_evaluated(denied, policy, "deny", reason, matched)
        {:error, :denied_by_policy, reason}

      {:replay, run} ->
        # Concurrent retry under the same Idempotency-Key — the original
        # already logged the deny; surface its outcome verbatim.
        replay_outcome(run)

      {:error, cs} ->
        {:error, cs}
    end
  end

  defp dispatch_allow(attrs, policy, reason, matched) do
    attrs = Map.merge(attrs, policy_attrs(policy, "allow", reason, matched))

    case create_run(attrs) do
      {:ok, run} ->
        # Record the policy decision *before* the envelope leaves for the
        # runner, so the audit trail reads decision → outcome — never the
        # other way round.
        log_policy_evaluated(run, policy, "allow", reason, matched)

        with :ok <- dispatch_to_runner(run) do
          {:ok, :running, run}
        end

      {:replay, run} ->
        # Original already pushed the run_action envelope to the runner;
        # re-pushing would duplicate-execute, so skip dispatch + just
        # echo the existing row's outcome.
        replay_outcome(run)

      {:error, cs} ->
        {:error, cs}
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

        case create_run(attrs) do
          {:ok, run} ->
            # Same ordering rule as the allow path: log the grant-based
            # decision before the run reaches the runner.
            log_grant_used(run, grant, policy)

            with :ok <- dispatch_to_runner(run) do
              {:ok, :running, run}
            end

          {:replay, run} ->
            replay_outcome(run)

          {:error, cs} ->
            {:error, cs}
        end

      :none ->
        attrs =
          attrs
          |> Map.merge(policy_attrs(policy, "require_approval", policy_reason, matched))
          |> Map.merge(%{status: "pending_approval", requires_approval: true})

        # Operator's reason ("why I'm running this") goes to the approval
        # request; the policy reason ("why approval is required") stays
        # on run.policy_reason for the reviewer to see separately.
        case create_run(attrs) do
          {:ok, run} ->
            with {:ok, _req} <-
                   Emisar.Approvals.create_request(run, attrs[:requested_by_id], attrs[:reason]) do
              log_policy_evaluated(run, policy, "require_approval", policy_reason, matched)
              {:ok, :pending_approval, run}
            end

          {:replay, run} ->
            replay_outcome(run)

          {:error, cs} ->
            {:error, cs}
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

  defp args_sha256(args) do
    :crypto.hash(:sha256, Jason.encode!(args || %{}))
    |> Base.encode16(case: :lower)
  end

  defp runner_belongs_to_account?(runner_id, account_id) do
    Runner.Query.not_deleted()
    |> Runner.Query.not_disabled()
    |> Runner.Query.by_id(runner_id)
    |> Runner.Query.by_account_id(account_id)
    |> Repo.exists?()
  end

  @doc """
  Internal — used by `Emisar.Workers.RunDispatchTimeout` to find runs
  that have been sitting in `pending` / `sent` longer than the
  dispatch threshold. Returns a plain list (no pagination); the worker
  iterates and decides per-run whether to time it out based on the
  runner's current state.
  """
  def list_stale_dispatches(cutoff) when is_struct(cutoff, DateTime) do
    ActionRun.Query.all()
    |> ActionRun.Query.status_in(["pending", "sent"])
    |> ActionRun.Query.queued_before(cutoff)
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

    PubSub.deliver_to_runner(run.runner_id, maybe_stamp_pack_hash(payload, run))

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
  # don't match what cloud trusts. We `fetch_action_by_id` against the
  # system subject because this runs inside an authorized dispatch path
  # — the caller's auth already passed; we're just enriching the wire
  # payload with a side-channel fact (trusted hash on file).
  #
  # If anything's missing — catalog row gone, pack_version not yet
  # populated, no trusted hash yet — we omit the key, and the runner
  # skips its trust gate (same as a fresh runner pre-Phase 2). The
  # operator-facing trust gate already ran upstream (`check_pack_trust`
  # in the with-chain), so omitting here only widens the window during
  # the brief moment when a hash is in flux; the upstream gate stays
  # closed.
  defp maybe_stamp_pack_hash(payload, %ActionRun{} = run) do
    account = Emisar.Accounts.fetch_account_by_id!(run.account_id)
    system = Subject.system(account)

    with {:ok, action} <- Emisar.Catalog.fetch_action_by_id(run.action_id, run.runner_id, system),
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
        PubSub.deliver_to_runner(run.runner_id, %{
          "type" => "cancel",
          "request_id" => run.request_id,
          "reason" => reason
        })

        log_cancel_requested(run, subject, reason)
        mark_cancelled(run, reason || "operator cancelled")
      end
    end
  end

  defp log_cancel_requested(%ActionRun{} = run, %Subject{} = subject, reason) do
    Audit.log(run.account_id, "run.cancel_requested",
      actor_kind: Subject.actor_kind(subject),
      actor_id: Subject.actor_id(subject),
      subject_kind: "run",
      subject_id: run.id,
      payload: %{from_status: run.status, reason: reason}
    )
  end

  def generate_request_id do
    "req_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end

  # -- State transitions ----------------------------------------------
  #
  # These are called from inside `dispatch_run/2`, the runner socket
  # process, and the runbook engine — all already-authorized paths.

  def mark_sent(%ActionRun{} = run) do
    transition(run, :sent, %{sent_at: now_utc()})
  end

  def mark_running(%ActionRun{} = run) do
    transition(run, :running, %{started_at: now_utc()})
  end

  def mark_cancelled(%ActionRun{} = run, reason \\ nil) do
    transition(run, :cancelled, %{
      cancelled_at: now_utc(),
      finished_at: now_utc(),
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
    transition(run, :error, %{finished_at: now_utc(), error_message: reason})
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
        # If this run was part of a runbook and succeeded, fire the
        # next step. Non-success stops the runbook and the failed step
        # surfaces on the runbook detail.
        finished
        |> Emisar.Runbooks.dispatch_next_step()
        |> audit_continuation(finished)

        ok

      other ->
        other
    end
  end

  # `dispatch_next_step/1` either dispatches the next runbook step
  # (`{:ok, :running | :pending_approval, _}`), no-ops when there's no
  # continuation (`:noop`), or fails to dispatch it. The failure is either
  # a denied-by-policy 3-tuple (`{:error, :denied_by_policy, reason}`) or a
  # 2-tuple (`{:error, %Changeset{} | :runner_out_of_scope | :pack_untrusted
  # | …}`). A failed continuation silently stopped the runbook with no
  # trace — write a run-scoped audit row so operators can see WHY the chain
  # halted mid-flight.
  defp audit_continuation({:error, :denied_by_policy, reason}, %ActionRun{} = finished),
    do: log_continuation_failure(finished, reason)

  defp audit_continuation({:error, reason}, %ActionRun{} = finished),
    do: log_continuation_failure(finished, reason)

  defp audit_continuation(_ok_or_noop, _finished), do: :ok

  defp log_continuation_failure(%ActionRun{} = finished, reason) do
    Audit.log(finished.account_id, "runbook.step_dispatch_failed",
      actor_kind: "system",
      subject_kind: "action_run",
      subject_id: finished.id,
      subject_label: finished.action_id,
      payload: %{
        run_id: finished.id,
        runbook_id: finished.runbook_id,
        runbook_step_id: finished.runbook_step_id,
        reason: inspect(reason)
      }
    )
  end

  defp result_attrs(payload) do
    %{
      finished_at: now_utc(),
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
    Multi.new()
    |> Multi.update(:run, ActionRun.Changeset.transition(run, status, attrs))
    |> put_run_audit_event()
    |> Repo.commit_multi(after_commit: fn %{run: run} -> PubSub.broadcast_run(run) end)
    |> case do
      {:ok, %{run: run}} -> {:ok, run}
      {:error, _} = err -> err
    end
  end

  # Adds the run-event audit insert to a Multi, but only for statuses
  # worth auditing (see `@audited_run_statuses`). Returns `{:ok, nil}`
  # for the skipped intermediate states so the transaction still
  # commits and `fan_out_audit_events/1` simply finds no event to
  # broadcast.
  defp put_run_audit_event(multi) do
    Multi.run(multi, :audit, fn repo, %{run: run} ->
      if run.status in @audited_run_statuses do
        repo.insert(Audit.run_event_changeset(run))
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
        PubSub.broadcast_run_event(run, event)

        # The first progress chunk marks the run as :running (transitions
        # are idempotent server-side).
        if run.status == "sent", do: mark_running(run)
        {:ok, event}

      err ->
        err
    end
  end

  def append_event(run_id, attrs) when is_binary(run_id) do
    case ActionRun.Query.all() |> ActionRun.Query.by_id(run_id) |> Repo.peek() do
      nil -> {:error, :unknown_run}
      %ActionRun{} = run -> append_event(run, attrs)
    end
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

  # -- Helpers ----------------------------------------------------------

  defp now_utc, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

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

  # Emits an audit row for every policy evaluation tied to a run, so
  # operators can answer "what was the policy state when this fired?"
  # by querying the audit trail by run_id. Includes `policy_version`
  # — the vsn snapshot at decision time, so a later edit to the
  # policy doesn't lose the trail of "this decision was made under
  # policy v5".
  defp log_policy_evaluated(%ActionRun{} = run, policy, decision, reason, matched) do
    Audit.log(run.account_id, "policy.evaluated",
      actor_kind: "system",
      subject_kind: "action_run",
      subject_id: run.id,
      subject_label: run.action_id,
      payload: %{
        run_id: run.id,
        policy_id: policy && policy.id,
        policy_version: policy && policy.vsn,
        decision: decision,
        reason: reason,
        matched_rules: matched
      }
    )
  end

  # Emits an audit row when a run bypasses approval via a standing
  # grant. The grant id + originating approval are in the payload so
  # operators can trace "why did this fire without prompting?" back to
  # the human who said yes.
  defp log_grant_used(%ActionRun{} = run, grant, policy) do
    Audit.log(run.account_id, "approval.grant_used",
      actor_kind: "system",
      subject_kind: "action_run",
      subject_id: run.id,
      subject_label: run.action_id,
      payload: %{
        run_id: run.id,
        grant_id: grant.id,
        approval_request_id: grant.approval_request_id,
        policy_id: policy && policy.id,
        uses_count: grant.uses_count + 1,
        max_uses: grant.max_uses
      }
    )
  end
end
