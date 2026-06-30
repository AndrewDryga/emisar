defmodule Emisar.Runs do
  @moduledoc """
  Action run lifecycle. Cloud calls `dispatch_run/2` when an operator
  (or MCP, or a runbook step) wants to invoke an action; this module
  creates the run row, evaluates policy, hands the dispatch to the
  Transport for sending, and tracks progress + final result.
  """
  alias Ecto.Multi
  alias Emisar.{ApiKeys, Audit, Auth, Crypto, Repo, RequestContext}
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
      # "View activity" from an agent key pivots here, scoped to that key — agent
      # activity lives on the run (`api_key_id`), not the audit actor (terminal run
      # events are engine/`system`-attributed, so the audit actor filter is always
      # empty for an api_key). Threaded as an opt, not a visible filter, so it stays
      # a pivot and never renders a UUID text input in the bar.
      {api_key_id, opts} = Keyword.pop(opts, :api_key_id)

      ActionRun.Query.all()
      |> filter_runs_by_api_key_id(api_key_id)
      |> apply_run_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, opts)
    end
  end

  defp filter_runs_by_api_key_id(queryable, nil), do: queryable

  defp filter_runs_by_api_key_id(queryable, api_key_id),
    do: ActionRun.Query.by_api_key_id(queryable, api_key_id)

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

  # `:own` narrows to the calling agent's own runs (its API key) — the MCP
  # `recent_runs` "recall what I ran" path; only an API-key subject has "own"
  # runs, so any other actor falls through to `:account` (the for_subject scope).
  defp apply_run_scope(query, :own, %Subject{actor: %ApiKeys.ApiKey{id: api_key_id}}),
    do: ActionRun.Query.by_api_key_id(query, api_key_id)

  defp apply_run_scope(query, _scope, _subject), do: query

  # Rendering concerns are the caller's: pass `preload:` only for the
  # associations the page actually shows. Unknown atoms raise (caller bug).
  defp apply_run_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :runner, queryable -> ActionRun.Query.with_preloaded_runner(queryable)
      :api_key, queryable -> ActionRun.Query.with_preloaded_api_key(queryable)
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

  # -- Creation ---------------------------------------------------------

  @doc """
  Internal — the dispatch pipeline (`dispatch_run/2`'s allow/deny/approval
  paths) and tests: create a run row in :pending state inside the
  already-authorized dispatch (no web subject). Caller is responsible for
  triggering the transport to deliver `run_action` once the row is
  persisted (see Emisar.Transport).

  Returns `{:ok, run}` on a fresh insert, `{:replay, run}` when this
  call lost the race to a concurrent caller that already inserted with
  the same `(api_key_id, idempotency_key)` pair (the unique index is
  the actual correctness guarantee — the pre-flight peek in
  `dispatch_run/2` just spares us the work in the common case), or
  `{:error, changeset}` for any other validation failure.

  Tests can also call this directly to seed runs without exercising
  policy + dispatch.
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
      # `:compose` lets a caller append steps that read `:run` from changes and
      # commit ATOMICALLY with it — the approval path files its request here, so
      # a run + its request can never half-commit (MAJOR-2).
      |> compose_run_steps(opts[:compose])
      |> Repo.commit_multi()

    case result do
      # Fresh insert: RETURNING carries the request_id this call minted.
      {:ok, %{run: %ActionRun{request_id: ^request_id} = run} = changes} ->
        broadcast_run(run)
        run_on_create(opts[:on_create], changes)
        {:ok, run}

      # Conflict path: the returned row is the earlier winner's — replay.
      # No audit row, no broadcast, no on_create; the original insert did them.
      {:ok, %{run: %ActionRun{} = run}} ->
        {:replay, run}

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
      |> dispatch_run_for_account(account_id)
    end
  end

  # Snapshot the dispatcher's source ip/ua from the request context onto the run
  # attrs, so every run-lifecycle audit event — including the terminal one logged
  # from the runner socket — attributes the action to where it came from. The
  # subject-less dispatch_run_for_account path (the runbook continuation) carries
  # none, which is correct: no request, no dispatcher.
  defp put_dispatcher_context(attrs, %Subject{context: %RequestContext{} = context}) do
    attrs
    |> Map.put(:ip_address, context.ip_address)
    |> Map.put(:user_agent, context.user_agent)
  end

  defp put_dispatcher_context(attrs, _subject), do: attrs

  @doc """
  Internal: dispatch a run for an explicit account with no `%Subject{}`.
  Used by the runbook engine to continue a chain from the post-`mark_finished`
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

    with :none <- peek_idempotent_run(attrs),
         :ok <- require_runner(runner_id),
         :ok <- require_action(action_id),
         :ok <- require_reason(reason),
         :ok <- runner_in_account(runner_id, account_id),
         :ok <- check_attestation(attrs, runner_id, account_id),
         :ok <- runner_in_membership_scope(runner_id, account_id, membership_id),
         {:ok, action} <- fetch_advertised_action(runner_id, action_id, account_id),
         {:ok, pack_hash} <- check_pack_trust(action, account_id) do
      attrs
      |> Map.delete(:requested_by_membership_id)
      |> Map.put(:args_sha256, args_sha256(attrs[:args]))
      # Snapshot the trusted hash as part of the authorization decision (MAJOR-5)
      # so the run ships the exact bytes authorized here, not a send-time re-read.
      |> Map.put(:expected_pack_hash, pack_hash)
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
        # A gate, not a hash provider — normalize the {:ok, hash} to :ok.
        case check_pack_trust(action, run.account_id) do
          {:ok, _hash} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :action_not_found} ->
        # The runner no longer advertises this action (offline / pack
        # unloaded) — the dispatch itself will fail to reach a live action,
        # so there is nothing to ship the wrong bytes to. The threat this
        # gate closes is an advertised pack that DRIFTED to :pending; that
        # path returns the action above and is refused by check_pack_trust.
        :ok
    end
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
    # Mirror the runner's verifier (runner/internal/signing): stale when the
    # signature's issued_at falls outside +/- the freshness window. An
    # unparseable issued_at falls through to :ok — let the runner reject it.
    with issued when is_binary(issued) <- att["issued_at"],
         {:ok, issued_at, _offset} <- DateTime.from_iso8601(issued),
         true <- abs(DateTime.diff(DateTime.utc_now(), issued_at)) > max_age do
      {:error, :attestation_stale}
    else
      _ -> :ok
    end
  end

  defp attestation_fresh(_att, _runner), do: :ok

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
  #   * `pending_approval` — blocks on a human approval; `wait_for_run` is
  #     still the right tool.
  #   * anything else (sent, running, terminal) — the run exists and the
  #     LLM can long-poll via `/runs/:id?wait=…` for the final state.
  defp replay_outcome(%ActionRun{status: :denied, policy_reason: reason}),
    do: {:error, :denied_by_policy, reason || "policy denied this call"}

  defp replay_outcome(%ActionRun{status: :pending_approval} = run),
    do: {:ok, :pending_approval, run}

  defp replay_outcome(%ActionRun{} = run),
    do: {:ok, :running, run}

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

  # Authoritative lookup. The runner has already advertised this action
  # via `Catalog.observe_state`; if the catalog row is missing the
  # action simply doesn't exist on that runner and we refuse to dispatch.
  defp fetch_advertised_action(runner_id, action_id, account_id) do
    case Emisar.Catalog.fetch_action_for_account(action_id, runner_id, account_id) do
      {:error, :not_found} -> {:error, :action_not_found}
      {:ok, action} -> {:ok, action}
    end
  end

  # Refuse a portal-originated (operator / runbook / API-key) dispatch to a
  # runner that advertises it enforces client signatures. The runner would
  # reject an unsigned run anyway; blocking here means no run row is created and
  # the caller gets a clear reason. A signed MCP dispatch carries an
  # `:attestation` and passes — the portal only RELAYS it (it can't forge one),
  # and the runner verifies the Ed25519 signature. This portal flag is the
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
        case dispatch_with_grant(attrs, policy, matched, grant) do
          # The grant lapsed (expired / exhausted / revoked) between the peek and
          # the atomic consume — fall back to the normal approval flow as if no
          # grant matched, rather than burning a use or erroring the caller.
          {:error, :grant_unusable} ->
            file_approval_request(attrs, policy, policy_reason, matched)

          other ->
            other
        end

      :none ->
        file_approval_request(attrs, policy, policy_reason, matched)
    end
  end

  # Dispatch as `:allow` against a matched grant. The grant is consumed INSIDE
  # create_run's Multi (MAJOR-3) — one use is burned only when a fresh run row
  # durably commits, never on a validation failure or an idempotency replay.
  defp dispatch_with_grant(attrs, policy, matched, grant) do
    attrs = Map.merge(attrs, policy_attrs(policy, "allow", "matched approval grant", matched))
    request_id = attrs[:request_id] || Crypto.run_request_id()
    attrs = Map.put(attrs, :request_id, request_id)
    audit = &Audit.Events.grant_used(&1, grant, policy)
    compose = &Emisar.Approvals.consume_grant_in_multi(&1, :run, grant, request_id)

    case create_run(attrs, audit: audit, compose: compose) do
      {:ok, run} ->
        with :ok <- dispatch_to_runner(run) do
          {:ok, :running, run}
        end

      {:replay, run} ->
        replay_outcome(run)

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
  defp file_approval_request(attrs, policy, policy_reason, matched) do
    attrs =
      attrs
      |> Map.merge(policy_attrs(policy, "require_approval", policy_reason, matched))
      |> Map.merge(%{status: :pending_approval, requires_approval: true})

    # Snapshot the approval-gate posture onto the request so a later policy edit
    # can't move this in-flight request's bar (mirrors the run-level
    # policy_version snapshot). The operator's reason ("why I'm running this")
    # goes to the request; the policy reason stays on run.policy_reason.
    request_opts = [
      min_approvals: Emisar.Policies.min_approvals_for(policy.rules),
      allow_self_approval: Emisar.Policies.self_approval_allowed?(policy.rules)
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

      {:replay, run} ->
        replay_outcome(run)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # PEEK only — the grant is CONSUMED later, atomically with the run insert (see
  # dispatch_with_grant), so a use is never burned without a durable run.
  defp lookup_grant(%{api_key_id: api_key_id} = attrs) when is_binary(api_key_id) do
    case Emisar.Approvals.peek_matching_grant(
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
  Internal — re-dispatch a runner's in-flight (`:pending`/`:sent`) runs the
  moment its socket (re)connects, so a dispatch lost to the prior socket's drop
  recovers in ~instant instead of waiting for the next `RunDispatchTimeout`
  sweep (~1 min). Idempotent and safe to fire on every connect: `dispatch_to_runner`
  re-emits and the runner dedupes by `request_id` (replays the cached result or
  runs it once), and an empty in-flight set is a no-op. Called by
  `EmisarWeb.RunnerSocket` after the socket has subscribed to the runner's
  transport, so the re-emitted envelopes reach this live connection.
  """
  def redispatch_inflight_for_runner(runner_id) when is_binary(runner_id) do
    runs =
      ActionRun.Query.all()
      |> ActionRun.Query.by_runner_id(runner_id)
      |> ActionRun.Query.status_in([:pending, :sent])
      |> Repo.all()

    if runs != [] do
      Logger.info("reconnect_redispatch runner=#{runner_id} runs=#{length(runs)}")
      Enum.each(runs, &dispatch_to_runner/1)
    end

    :ok
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
  Re-emits the run_action envelope onto the runner's PubSub topic. Used for
  fresh dispatches, the approve→send transition, and `RunDispatchTimeout`
  re-sending a stale dispatch — the runner dedupes by `request_id`, so a
  redelivery replays the cached result or runs it once (idempotent).
  Internal — called from `dispatch_run/2`, `Approvals.approve_request/4`,
  and `Emisar.Workers.RunDispatchTimeout`.
  """
  def dispatch_to_runner(%ActionRun{} = run) do
    # Independent send-time guard: re-read the CURRENT status and refuse to
    # publish a run that's no longer dispatchable (cancelled / denied / terminal).
    # The envelope goes onto the runner's topic BEFORE `mark_sent`, and
    # `mark_sent`'s terminal guard only blocks the DB transition — not the
    # already-delivered message — so a run cancelled between authorization and
    # delivery (a stale approval racing a cancel) MUST be stopped here, before
    # anything reaches the runner.
    if dispatchable?(peek_run_by_id(run.id)) do
      deliver_run_action(run)
    else
      {:error, :not_dispatchable}
    end
  end

  defp dispatchable?(%ActionRun{status: status}), do: active_run_status?(status)
  defp dispatchable?(_), do: false

  defp deliver_run_action(%ActionRun{} = run) do
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

    payload = maybe_put_attestation(payload, run)

    case stamp_pack_hash(payload, run) do
      {:ok, envelope} ->
        Emisar.Runners.deliver_to_runner(run.account_id, run.runner_id, envelope)

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

      :unavailable ->
        # A versioned pack with no trusted hash to pin — refuse to deliver a
        # hash-less envelope (the runner would skip its hash gate, fail-open).
        # The upstream `check_pack_trust` passed at creation, so this is a pack
        # that DRIFTED to pending/rejected before this (re)delivery: mark the
        # run refused so the operator sees a terminal row with the cause.
        mark_refused(
          run,
          "pack trust changed after this run was authorized — re-trust the pack in /app/packs and re-dispatch"
        )

        {:error, :pack_untrusted}
    end
  end

  # Relay the client attestation (signed by the MCP, never the cloud) so an
  # enforcing runner can verify a real user authorized this run. The portal
  # only carries it through — it neither produces nor checks the signature.
  defp maybe_put_attestation(payload, %ActionRun{attestation: att}) when is_map(att),
    do: Map.put(payload, "attestation", att)

  defp maybe_put_attestation(payload, %ActionRun{}), do: payload

  # Stamp the trusted pack hash into the wire envelope so the runner can re-hash
  # its on-disk pack and refuse a dispatch whose bytes don't match what cloud
  # trusts. Fail CLOSED for a versioned pack: returns `:unavailable` (the caller
  # refuses delivery) rather than ship a hash-less envelope the runner would
  # wave through. We fetch the catalog action scoped to the run's own account
  # (no Subject) — this runs inside an already-authorized dispatch path.
  #
  # Stamp the SNAPSHOTTED pack hash (captured at authorization) into the wire
  # envelope. A pack-less run (nil snapshot) ships no hash. A versioned run ships
  # the hash the operator/policy authorized for THIS run — never a send-time
  # re-read, so a pack that drifted then re-trusted to different bytes can't swap
  # the hash underneath it (MAJOR-5). Still fail CLOSED at send: re-confirm the
  # pack is STILL trusted (an operator may have rejected it since authorization);
  # if not, `:unavailable` so the caller refuses delivery.
  defp stamp_pack_hash(payload, %ActionRun{expected_pack_hash: nil}), do: {:ok, payload}

  defp stamp_pack_hash(payload, %ActionRun{expected_pack_hash: hash} = run) do
    if pack_still_trusted?(run),
      do: {:ok, Map.put(payload, "expected_pack_hash", hash)},
      else: :unavailable
  end

  defp pack_still_trusted?(%ActionRun{} = run) do
    case Emisar.Catalog.fetch_action_for_account(run.action_id, run.runner_id, run.account_id) do
      # The catalog mirror row vanished (runner offline / pack unloaded) — the
      # run was already trust-gated at creation, so don't block a redelivery on a
      # missing row; the runner re-hashes its on-disk pack and refuses a mismatch.
      {:error, _} -> true
      {:ok, action} -> match?({:ok, _hash}, Emisar.Catalog.check_pack_trusted(action))
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

  # A run still awaiting approval was never sent to a runner, so there's no
  # runner to tell — but its approval request is still `:pending`. Cancel the
  # run AND its request in ONE transaction, so a stale approve can't later
  # resurrect + dispatch the run (it now finds a `:cancelled` request).
  defp cancel_run_for_status(%ActionRun{status: :pending_approval} = run, subject, reason) do
    reason = reason || "operator cancelled"

    Multi.new()
    |> cancel_run_in_multi(run.id, reason)
    |> Multi.insert(
      :cancel_requested_audit,
      Audit.Events.run_cancel_requested(subject, run, reason)
    )
    |> Emisar.Approvals.cancel_request_for_run_in_multi(run.id)
    |> Repo.commit_multi(
      after_commit: fn changes ->
        broadcast_cancelled_run(changes.run_cancel)
        Emisar.Approvals.broadcast_request_cancelled(changes.request_cancel)
      end
    )
    |> case do
      {:ok, %{run_cancel: {:cancelled, cancelled}}} -> {:ok, cancelled}
      {:ok, %{run_cancel: {:noop, unchanged}}} -> {:ok, unchanged}
      {:ok, %{run_cancel: :no_run}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_run_for_status(%ActionRun{status: status} = run, subject, reason) do
    if ActionRun.terminal?(status) do
      {:ok, run}
    else
      # In-flight (sent / running): the runner is executing, so tell it to stop.
      Emisar.Runners.deliver_to_runner(run.account_id, run.runner_id, %{
        "type" => "cancel",
        "request_id" => run.request_id,
        "reason" => reason
      })

      Audit.record(Audit.Events.run_cancel_requested(subject, run, reason))
      mark_cancelled(run, reason || "operator cancelled")
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

  def mark_cancelled(%ActionRun{} = run, reason \\ nil),
    do: transition(run, :cancelled, cancelled_attrs(reason))

  @doc """
  Internal — append the run-cancel steps (locked re-read, terminal-guard,
  update to `:cancelled`, and the `run.cancelled` audit insert) to `multi`, for
  a caller composing the cancel into its OWN transaction (Approvals deny +
  expiry). The result lands in changes as `:run_cancel`: `{:cancelled, run}`
  when this call transitioned it, `{:noop, run}` when it was already terminal,
  or `:no_run` if the row is gone. Fires NO broadcast — a run broadcast or audit
  fan-out here would escape the enclosing transaction before it commits; the
  caller hoists `broadcast_cancelled_run/1` to its `commit_multi(after_commit:)`
  and the outer commit's fan_out delivers the audit event.
  """
  def cancel_run_in_multi(multi, run_id, reason \\ nil) when is_binary(run_id) do
    multi
    |> Multi.run(:run_cancel, fn repo, _changes -> cancel_run_locked(repo, run_id, reason) end)
    |> Multi.run(:run_cancel_audit, fn
      repo, %{run_cancel: {:cancelled, run}} -> repo.insert(Audit.run_event_changeset(run))
      _repo, %{run_cancel: _} -> {:ok, nil}
    end)
  end

  defp cancel_run_locked(repo, run_id, reason) do
    loaded_run =
      ActionRun.Query.all()
      |> ActionRun.Query.by_id(run_id)
      |> ActionRun.Query.lock_for_update()
      |> repo.one()

    cond do
      is_nil(loaded_run) -> {:ok, :no_run}
      ActionRun.terminal?(loaded_run.status) -> {:ok, {:noop, loaded_run}}
      true -> cancel_loaded_run(repo, loaded_run, reason)
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
  Internal — `Emisar.Workers.RunDispatchTimeout` terminally fails a
  non-finished run (`:error` + `error_message`) when its dispatch can't
  complete: the runner was offline/disabled/removed, disconnected
  mid-run, or stayed online but never acknowledged the send past the
  redispatch deadline. The reason explains which, so the operator sees a
  terminal row with context instead of one stuck in `sent`/`running`
  forever.
  """
  def mark_errored(%ActionRun{} = run, reason) when is_binary(reason) do
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
    "cancelled" => :cancelled,
    # The runner refused the dispatch on a trust check (bad/missing/stale
    # signature, or pack-hash mismatch) — a first-class terminal state distinct
    # from `:failed`; the human cause is carried in error_message.
    "signature_invalid" => :refused,
    "pack_hash_mismatch" => :refused
  }

  def mark_finished(%ActionRun{} = run, result_payload) do
    status = Map.get(@result_statuses, result_payload["status"], :failed)

    case transition(run, status, result_attrs(result_payload)) do
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
      # The failure cause belongs in error_message (not reason_text, which holds
      # the operator's freeform reason). The runner sends a terse `reason` code
      # (e.g. "bad_signature", "stale") AND a human `error` sentence ("refused:
      # signature does not match…") on a refusal; prefer the sentence so the
      # operator can act, falling back to the code when there's no `error`
      # (omitempty drops it on an ordinary failure, so this stays the reason).
      error_message: payload["error"] || payload["reason"]
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

  # An optional decision event (today only `grant_used` — the standing-grant
  # fast path), committed in the SAME transaction as the run row + its terminal
  # event so a grant-dispatched action can't end up with no record of the grant
  # that let it through. `audit_fn` takes the inserted run and returns the event
  # changeset. Skipped on the idempotency-replay path (same `fresh?` guard as the
  # run event) — the original insert already logged it. (The policy allow/deny/
  # require_approval decisions no longer write a separate row — audit-logging
  # diet — their facts live on the run row + its terminal event.)
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

  @doc "Internal — runner socket: append a progress chunk to a dispatched run (socket token is the gate, no web subject)."
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

      {:error, %Ecto.Changeset{} = changeset} ->
        # A re-sent chunk (same run_id + seq) hits the unique index — a benign
        # idempotent duplicate. Classify it as an atom so the caller drops it
        # quietly, while a genuinely malformed event still surfaces as a changeset.
        if Repo.Changeset.unique_constraint_error?(changeset),
          do: {:error, :duplicate_event},
          else: {:error, changeset}
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
