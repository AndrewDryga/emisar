defmodule Emisar.Runs do
  @moduledoc """
  Action run lifecycle. Cloud calls `dispatch/2` when an operator
  (or MCP, or a runbook step) wants to invoke an action; this module
  creates the run row, evaluates policy, hands the dispatch to the
  Transport for sending, and tracks progress + final result.
  """

  import Ecto.Query
  alias Emisar.{Audit, PubSub, Repo}
  alias Emisar.Runs.{ActionRun, RunEvent}

  # -- Listing / queries ------------------------------------------------

  def list_runs_for_account(account_id, opts \\ []) do
    query =
      from r in ActionRun,
        where: r.account_id == ^account_id,
        order_by: [desc: r.inserted_at]

    query =
      query
      |> maybe_filter_status(opts[:status])
      |> maybe_filter_runner(opts[:runner_id])
      |> maybe_filter_action(opts[:action_id])
      |> maybe_limit(opts[:limit] || 100)

    Repo.all(query)
  end

  def list_recent_runs_for_agent(runner_id, limit \\ 50) do
    from(r in ActionRun,
      where: r.runner_id == ^runner_id,
      order_by: [desc: r.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  def get_run(account_id, id) do
    from(r in ActionRun,
      where: r.account_id == ^account_id and r.id == ^id,
      preload: [:runner]
    )
    |> Repo.one()
  end

  def get_run_by_request_id(account_id, request_id) do
    Repo.get_by(ActionRun, account_id: account_id, request_id: request_id)
  end

  @doc """
  Looks up a run by `request_id` AND `runner_id`. Used by the runner
  socket so an runner can only see/mutate runs that were dispatched to
  it — never another runner's runs, even within the same account.
  """
  def get_run_for_runner(runner_id, request_id) do
    Repo.get_by(ActionRun, runner_id: runner_id, request_id: request_id)
  end

  defp maybe_filter_status(q, nil), do: q
  defp maybe_filter_status(q, status), do: where(q, [r], r.status == ^status)
  defp maybe_filter_runner(q, nil), do: q
  defp maybe_filter_runner(q, runner_id), do: where(q, [r], r.runner_id == ^runner_id)
  defp maybe_filter_action(q, nil), do: q
  defp maybe_filter_action(q, action_id), do: where(q, [r], r.action_id == ^action_id)
  defp maybe_limit(q, n), do: limit(q, ^n)

  # -- Creation ---------------------------------------------------------

  @doc """
  Create a run row in :pending state. Caller is responsible for
  triggering the transport to deliver `run_action` once the row is
  persisted (see Emisar.Transport).
  """
  def create_run(attrs) do
    request_id = attrs[:request_id] || attrs["request_id"] || generate_request_id()
    attrs = Map.put(attrs, :request_id, request_id)
    attrs = Map.put(attrs, :queued_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

    %ActionRun{}
    |> ActionRun.create_changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast()
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
  def dispatch(account_id, attrs) do
    attrs = Map.put(attrs, :account_id, account_id)
    runner_id = attrs[:runner_id] || attrs["runner_id"]
    action_id = attrs[:action_id] || attrs["action_id"]
    reason = attrs[:reason] || attrs["reason"]

    with :ok <- require_runner(runner_id),
         :ok <- require_action(action_id),
         :ok <- require_reason(reason),
         :ok <- runner_in_account(runner_id, account_id),
         {:ok, action} <- fetch_advertised_action(account_id, runner_id, action_id) do
      do_dispatch(account_id, attrs, action)
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
  defp fetch_advertised_action(account_id, runner_id, action_id) do
    case Emisar.Catalog.get_action(account_id, runner_id, action_id) do
      nil -> {:error, :action_not_found}
      action -> {:ok, action}
    end
  end

  defp do_dispatch(account_id, attrs, action) do
    args_sha =
      :crypto.hash(:sha256, Jason.encode!(attrs[:args] || attrs["args"] || %{}))
      |> Base.encode16(case: :lower)

    # Inject catalog-authoritative risk and kind so a caller cannot
    # spoof "low" to bypass a "high requires approval" rule.
    eval_attrs =
      attrs
      |> Map.put(:risk, action.risk)
      |> Map.put(:kind, action.kind)

    attrs =
      attrs
      |> Map.put(:args_sha256, args_sha)
      |> Map.put(:requires_approval, false)

    case Emisar.Policies.evaluate_with_policy(account_id, eval_attrs) do
      {:deny, matched, reason, policy} ->
        # Store a denied run row for the audit trail so operators can
        # see attempts even when they didn't reach the runner.
        run_attrs =
          attrs
          |> Map.merge(policy_attrs(policy, "deny", reason, matched))
          |> Map.put(:status, "denied")

        {:ok, denied_run} = create_run(run_attrs)
        log_policy_evaluated(denied_run, policy, "deny", reason, matched)
        {:error, :denied_by_policy, reason}

      {:allow, matched, reason, policy} ->
        attrs = Map.merge(attrs, policy_attrs(policy, "allow", reason, matched))

        with {:ok, run} <- create_run(attrs),
             :ok <- dispatch_to_runner(run) do
          log_policy_evaluated(run, policy, "allow", reason, matched)
          {:ok, :running, run}
        end

      {:require_approval, matched, policy_reason, policy} ->
        attrs =
          attrs
          |> Map.merge(policy_attrs(policy, "require_approval", policy_reason, matched))
          |> Map.merge(%{status: "pending_approval", requires_approval: true})

        # Pass the *operator's* reason (why they want to run it) to the
        # approval request — not the policy reason (why approval is
        # required). The policy reason is also on run.policy_reason for
        # the approval reviewer to see separately.
        operator_reason = attrs[:reason] || attrs["reason"]

        with {:ok, run} <- create_run(attrs),
             {:ok, _req} <-
               Emisar.Approvals.create_request(run, attrs[:requested_by_id], operator_reason) do
          log_policy_evaluated(run, policy, "require_approval", policy_reason, matched)
          {:ok, :pending_approval, run}
        end
    end
  end

  defp runner_belongs_to_account?(runner_id, account_id) do
    Repo.exists?(
      from a in Emisar.Runners.Runner,
        where: a.id == ^runner_id and a.account_id == ^account_id and is_nil(a.disabled_at)
    )
  end

  @doc """
  Re-emits the run_action envelope onto the runner's PubSub topic. Used
  both for fresh dispatches and for the approve→send transition.
  """
  def dispatch_to_runner(%ActionRun{} = run) do
    PubSub.deliver_to_runner(run.runner_id, %{
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
    })

    mark_sent(run)
    :ok
  end

  @doc """
  Cloud-initiated cancellation. Marks the run as cancelling and tells
  the runner to terminate. Idempotent if the run is already terminal.
  """
  def cancel(%ActionRun{status: status} = run, by_user_id, reason \\ nil) do
    if ActionRun.terminal?(status) do
      {:ok, run}
    else
      PubSub.deliver_to_runner(run.runner_id, %{
        "type" => "cancel",
        "request_id" => run.request_id,
        "reason" => reason
      })

      Audit.log(run.account_id, "run.cancel_requested",
        actor_kind: "user",
        actor_id: by_user_id,
        subject_kind: "run",
        subject_id: run.id,
        payload: %{from_status: status, reason: reason}
      )

      mark_cancelled(run, reason || "operator cancelled")
    end
  end

  def generate_request_id do
    "req_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end

  # -- State transitions ----------------------------------------------

  def mark_sent(%ActionRun{} = run) do
    transition(run, :sent, %{sent_at: now_utc()})
  end

  def mark_running(%ActionRun{} = run) do
    transition(run, :running, %{started_at: now_utc()})
  end

  def mark_cancelled(%ActionRun{} = run, reason \\ nil) do
    transition(run, :cancelled, %{cancelled_at: now_utc(), finished_at: now_utc(), reason_text: reason})
  end

  def mark_finished(%ActionRun{} = run, result_payload) do
    status =
      case result_payload["status"] do
        "success" -> :success
        "failed" -> :failed
        "error" -> :error
        "validation_failed" -> :validation_failed
        "unknown_action" -> :unknown_action
        "cancelled" -> :cancelled
        _ -> :failed
      end

    attrs = %{
      finished_at: now_utc(),
      exit_code: result_payload["exit_code"],
      duration_ms: result_payload["duration_ms"],
      timed_out: result_payload["timed_out"] || false,
      stdout_sha256: result_payload["stdout_sha256"],
      stderr_sha256: result_payload["stderr_sha256"],
      stdout_bytes: result_payload["stdout_bytes"],
      stderr_bytes: result_payload["stderr_bytes"],
      event_id: result_payload["event_id"],
      # The runner's `reason` on non-success results is the failure cause
      # (e.g. validation message). It belongs in error_message, not in
      # reason_text — which holds the operator's freeform reason.
      error_message: result_payload["reason"]
    }

    case transition(run, status, attrs) do
      {:ok, finished} = ok ->
        # If this run was part of a runbook and succeeded, fire the
        # next step. Non-success stops the runbook and the failed step
        # surfaces on the runbook detail.
        Emisar.Runbooks.dispatch_next_step(finished)
        ok

      other ->
        other
    end
  end

  def mark_error_envelope(%ActionRun{} = run, %{} = error) do
    transition(run, :error, %{
      finished_at: now_utc(),
      error_message: error["message"] || error["code"]
    })
  end

  defp transition(%ActionRun{} = run, status, attrs) do
    run
    |> ActionRun.transition_changeset(status, attrs)
    |> Repo.update()
    |> tap_broadcast()
  end

  # -- Events (progress chunks) ----------------------------------------

  def append_event(%ActionRun{} = run, attrs) do
    attrs = Map.put(attrs, :run_id, run.id) |> Map.put(:account_id, run.account_id)

    %RunEvent{}
    |> RunEvent.changeset(attrs)
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
    case Repo.get(ActionRun, run_id) do
      nil -> {:error, :unknown_run}
      %ActionRun{} = run -> append_event(run, attrs)
    end
  end

  @doc """
  Translates an inbound `action_result` envelope into a state transition
  on the matching ActionRun. Scoped by runner_id so an runner can only
  finalize runs that were dispatched to it. Returns
  `{:error, :unknown_request_id}` if no matching run exists.
  """
  def finalize_from_result(runner_id, %{"request_id" => request_id} = result) do
    case get_run_for_runner(runner_id, request_id) do
      nil -> {:error, :unknown_request_id}
      %ActionRun{} = run -> mark_finished(run, result)
    end
  end

  def finalize_from_result(_runner_id, _msg),
    do: {:error, :missing_request_id}

  def list_events(run_id, opts \\ []) do
    limit = opts[:limit] || 500
    from(e in RunEvent,
      where: e.run_id == ^run_id,
      order_by: e.seq,
      limit: ^limit
    )
    |> Repo.all()
  end

  # -- Helpers ----------------------------------------------------------

  defp now_utc, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp tap_broadcast({:ok, %ActionRun{} = run} = result) do
    PubSub.broadcast_run(run)
    Audit.log_run_event(run)
    result
  end

  defp tap_broadcast(other), do: other

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
      policy_version: policy.version,
      policy_decision: decision,
      policy_reason: reason,
      matched_rules: matched
    }
  end

  # Emits an audit row for every policy evaluation tied to a run, so
  # operators can answer "what was the policy state when this fired?"
  # by querying the audit trail by run_id.
  defp log_policy_evaluated(%ActionRun{} = run, policy, decision, reason, matched) do
    Audit.log(run.account_id, "policy.evaluated",
      actor_kind: "system",
      subject_kind: "action_run",
      subject_id: run.id,
      subject_label: run.action_id,
      payload: %{
        run_id: run.id,
        policy_id: policy && policy.id,
        policy_name: policy && policy.name,
        policy_version: policy && policy.version,
        decision: decision,
        reason: reason,
        matched_rules: matched
      }
    )
  end
end
