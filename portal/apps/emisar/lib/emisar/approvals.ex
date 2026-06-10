defmodule Emisar.Approvals do
  @moduledoc """
  Approval requests for runs that policy gated, plus the durable
  "grants" that let identical follow-up calls bypass the gate for a
  bounded window without re-prompting the operator.

  Flow:

    1. `Runs.dispatch_run` evaluates policy → `:require_approval`.
    2. It calls `Approvals.peek_matching_grant/4` for the calling API
       key. If a usable grant exists, dispatch fast-paths past
       approval (and increments the grant's use count).
    3. Otherwise `Approvals.create_request/3` files an approval row
       and the LLM-facing endpoint returns `pending_approval` with a
       run id for the LLM to poll on.
    4. The operator decides in the UI. On approve, they pick a
       duration (once / 1h / 24h / indefinite) and an arg-match scope
       (exact / any) — those choices populate a new
       `Approvals.Grant` so the LLM doesn't have to ask again next
       time within that window.
  """
  alias Ecto.Multi
  alias Emisar.{Audit, Auth, PubSub, Repo, Runs}
  alias Emisar.Approvals.{Authorizer, Grant, Request}
  alias Emisar.Auth.Subject

  def list_pending_approval_requests(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_approvals_permission()
           ) do
      Request.Query.pending()
      |> Request.Query.ordered_by_requested()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Request.Query, opts)
    end
  end

  @doc """
  Cheap COUNT(*) for the sidebar / dashboard badge — same Subject gate +
  account scoping as `list_pending_approval_requests/2`, but skips the
  pagination + preload work. Returns `0` if the caller lacks permission
  (badge silently disappears rather than erroring).
  """
  def count_pending_approval_requests(%Subject{} = subject) do
    case Auth.Authorizer.ensure_has_permissions(
           subject,
           Authorizer.view_approvals_permission()
         ) do
      :ok ->
        Request.Query.pending()
        |> Authorizer.for_subject(subject)
        |> Repo.aggregate(:count)

      _ ->
        0
    end
  end

  def list_approval_requests_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_approvals_permission()
           ) do
      {status, opts} = Keyword.pop(opts, :status)
      {limit, opts} = Keyword.pop(opts, :limit, 100)

      Request.Query.all()
      |> Request.Query.ordered_by_recent()
      |> apply_request_status_filter(status)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Request.Query, Keyword.put_new(opts, :page, limit: limit))
    end
  end

  defp apply_request_status_filter(query, nil), do: query
  defp apply_request_status_filter(query, status), do: Request.Query.by_status(query, status)

  def fetch_approval_request_by_id(id, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_approvals_permission()
           ),
         true <- Repo.valid_uuid?(id) do
      Request.Query.all()
      |> Request.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Request.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Looks up the (single) approval request for a run. There is a
  unique-by-design relationship: one run produces at most one approval
  request, since policy is evaluated once at dispatch time.
  """
  def fetch_approval_request_by_run_id(run_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_approvals_permission()
           ) do
      Request.Query.all()
      |> Request.Query.by_run_id(run_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Request.Query)
    end
  end

  # Default window for a pending approval to sit before the
  # ApprovalExpiry worker auto-rejects it. Anything past this is
  # almost certainly an on-call who lost the page / left the company —
  # an LLM agent should not be permitted to keep a high-risk action
  # held open for days. Override per-account in the future via a
  # policy setting.
  @default_pending_ttl_hours 24

  # Grant duration windows in seconds. Named constants make the
  # `expires_at_for/2` table read at a glance and let other modules
  # share the same numbers if needed later.
  @one_hour_seconds 60 * 60
  @one_day_seconds 24 * @one_hour_seconds
  @thirty_days_seconds 30 * @one_day_seconds
  @ninety_days_seconds 90 * @one_day_seconds

  @doc """
  Files an approval request for a gated run. Internal — called from
  `Runs.dispatch_run` which has already authorized via its own Subject.
  `requested_by_id` is whoever asked for the run (user, api_key, etc).
  """
  def create_request(%Runs.ActionRun{} = run, requested_by_id, reason \\ nil) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @default_pending_ttl_hours * @one_hour_seconds, :second)

    result =
      Request.Changeset.create(%{
        account_id: run.account_id,
        run_id: run.id,
        requested_by_id: requested_by_id,
        requested_at: now,
        expires_at: expires_at,
        reason: reason,
        context: %{
          runner_id: run.runner_id,
          action_id: run.action_id,
          args_sha256: run.args_sha256
        }
      })
      |> Repo.insert()
      |> tap_broadcast()

    # Fan out emails to every member who can decide. In prod the email
    # dispatch is detached so a slow SMTP/Mailgun call never blocks
    # the caller's `Runs.dispatch_run` path. In tests it's synchronous so
    # the sandbox connection isn't released while a background task
    # is still querying the DB — `:notify_approvers_async?` flips this.
    with {:ok, req} <- result do
      run_notify(fn -> notify_approvers(req, run, requested_by_id) end)
      {:ok, req}
    end
  end

  # Two modes:
  #
  #   * Sync (tests): `notify_approvers_async?: false` runs the closure
  #     inline so the test stays inside its sandbox checkout.
  #   * Async (dev/prod): hands the closure to a supervised Task so
  #     SIGTERM drains in-flight email blasts. The supervisor lives in
  #     the web app's tree; if it's missing in async mode that's a real
  #     configuration bug — `Task.Supervisor.start_child` raises and
  #     surfaces it instead of silently orphaning the task.
  defp run_notify(fun) do
    if Application.get_env(:emisar, :notify_approvers_async?, true) do
      sup = Application.fetch_env!(:emisar, :task_supervisor)
      Task.Supervisor.start_child(sup, fun)
    else
      fun.()
    end
  end

  # Per-page batch size — large enough to cap page count (accounts top
  # out in the hundreds of admins in practice) but small enough that one
  # batch isn't a memory hazard if a future plan removes the cap entirely.
  @notify_page_size 200

  defp notify_approvers(%Request{} = req, run, requested_by_id) do
    # Preload runner so the email body can show the runner's name
    # ("db-prod-01") instead of its UUID — approvers shouldn't need to
    # context-switch into the app just to know what's being touched.
    run = Repo.preload(run, :runner)

    notify_approvers_pages(req, run, requested_by_id, nil)
  end

  # Cursor-walk the membership pages so accounts with >100 admins still
  # get full coverage — earlier code capped at a single 100-row page,
  # silently skipping everyone after.
  defp notify_approvers_pages(%Request{} = req, run, requested_by_id, cursor) do
    page_opts =
      [limit: @notify_page_size]
      |> then(fn opts -> if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts end)

    {:ok, memberships, %{next_page_cursor: next}} =
      Emisar.Accounts.list_account_memberships(req.account_id, page: page_opts)

    approver_roles =
      Auth.Authorizer.roles_with_permission(Authorizer.decide_approval_permission())

    memberships
    |> Enum.filter(fn membership ->
      # Only members who can decide get pinged (viewers can't); the user who
      # triggered the request is excluded since they already saw it in the UI.
      membership.role in approver_roles and membership.user_id != requested_by_id
    end)
    |> Enum.each(&deliver_approval_email(&1, req, run))

    if next,
      do: notify_approvers_pages(req, run, requested_by_id, next),
      else: :ok
  end

  defp deliver_approval_email(membership, req, run) do
    require Logger

    try do
      # Mailer.deliver returns {:ok, _} on success and {:error, reason}
      # on transport failure (Mailgun 5xx, SMTP timeout). It DOES NOT
      # raise on non-success — a bare `try` would silently drop
      # delivery errors. Pattern-match and log non-success explicitly.
      case Emisar.Mailers.UserNotifier.deliver_approval_request(membership.user, req, run) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("approval_email_failed",
            user_id: membership.user_id,
            req_id: req.id,
            error: inspect(reason)
          )
      end
    rescue
      err ->
        Logger.warning("approval_email_crashed",
          user_id: membership.user_id,
          req_id: req.id,
          error: inspect(err)
        )
    end
  end

  @doc """
  Approve a pending request and dispatch the gated run.

  `opts` is an optional keyword list that controls whether to mint a
  durable `Grant` alongside the approval so future identical calls can
  bypass the gate:

    * `:duration` — `:once` (no grant), `:one_hour`, `:one_day`,
      `:thirty_days`, or `:ninety_days`. Default: `:once`.
    * `:scope`    — `:exact_args` (locks args fingerprint) or
      `:any_args` (any args for this action). Default: `:exact_args`.
    * `:max_uses` — for a windowed duration, cap on total executions
      (nil = unlimited within the window); `:once` is always one use.
  """
  def approve_request(req, subject, reason \\ nil, opts \\ [])

  def approve_request(%Request{} = req, %Subject{} = subject, reason, opts) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.decide_approval_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, req.account_id) do
      by_user_id = Subject.actor_id(subject)

      case claim_pending(req, :approved, by_user_id, reason) do
        {:ok, decided} ->
          result =
            Repo.transaction(fn ->
              run = Runs.fetch_run!(req.run_id)

              grant_attrs = %{
                duration: Keyword.get(opts, :duration, :once),
                scope: Keyword.get(opts, :scope, :exact_args),
                max_uses: Keyword.get(opts, :max_uses)
              }

              grant =
                if grant_attrs.duration != :once and run.api_key_id do
                  # The operator explicitly chose a durable window ("for 24h").
                  # If the grant insert fails we must NOT commit the approval as
                  # if it were `:once` — that would silently no-op their intent,
                  # record `grant_id: nil`, and re-prompt on the next identical
                  # call. Roll the whole transaction back so the request stays
                  # pending and the operator can retry.
                  case create_grant(req, run, by_user_id, grant_attrs) do
                    {:ok, grant} -> grant
                    {:error, changeset} -> Repo.rollback({:grant_failed, changeset})
                  end
                end

              Audit.log(req.account_id, "approval.approved",
                actor_kind: "user",
                actor_id: by_user_id,
                subject_kind: "approval_request",
                subject_id: req.id,
                payload: %{
                  run_id: req.run_id,
                  reason: reason,
                  grant_id: grant && grant.id,
                  grant_duration: grant && grant_attrs.duration,
                  grant_scope: grant && grant_attrs.scope
                }
              )

              {decided, run}
            end)
            |> tap_broadcast_tuple()

          # Deliver to the runner AFTER the transaction commits so the
          # PubSub broadcast can't fire before the DB state is durable.
          # The transition to :sent happens inside
          # Runs.dispatch_to_runner/1 → Runs.mark_sent/1.
          with {:ok, {decided, run}} <- result,
               :ok <- Runs.dispatch_to_runner(run) do
            run = Repo.reload!(run)
            {:ok, {decided, run}}
          end

        {:error, :already_decided} ->
          {:error, :already_decided}
      end
    end
  end

  def deny_request(%Request{} = req, %Subject{} = subject, reason \\ nil) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.decide_approval_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, req.account_id) do
      by_user_id = Subject.actor_id(subject)

      case claim_pending(req, :denied, by_user_id, reason) do
        {:ok, decided} ->
          Repo.transaction(fn ->
            run = Runs.fetch_run!(req.run_id)
            {:ok, run} = Runs.mark_cancelled(run, denial_reason(reason))

            Audit.log(req.account_id, "approval.denied",
              actor_kind: "user",
              actor_id: by_user_id,
              subject_kind: "approval_request",
              subject_id: req.id,
              payload: %{run_id: req.run_id, reason: reason}
            )

            {decided, run}
          end)
          |> tap_broadcast_tuple()

        {:error, :already_decided} ->
          {:error, :already_decided}
      end
    end
  end

  defp denial_reason(nil), do: "approval denied"
  defp denial_reason(reason), do: "approval denied: " <> reason

  # Atomically claim a pending approval request as decided. Two operators
  # clicking Approve at the same moment would both pass the LiveView's
  # `status == "pending"` precondition; only one's SQL update will see
  # `WHERE status = 'pending'` evaluate true. The loser gets 0 rows
  # affected and we return `{:error, :already_decided}` so the caller
  # can flash a useful message rather than double-dispatching.
  defp claim_pending(%Request{} = req, status, by_user_id, reason) do
    now = DateTime.utc_now()
    status_str = to_string(status)

    {affected, _} =
      Request.Query.decide_pending(req.id, status_str, by_user_id, reason, now)
      |> Repo.update_all([])

    case affected do
      1 ->
        decided =
          Request.Query.all() |> Request.Query.by_id(req.id) |> Repo.fetch!(Request.Query)

        {:ok, decided}

      0 ->
        {:error, :already_decided}
    end
  end

  defp tap_broadcast({:ok, %Request{} = request} = result) do
    PubSub.broadcast_approval(request)
    result
  end

  defp tap_broadcast(other), do: other

  defp tap_broadcast_tuple({:ok, {req, _run}} = result) do
    PubSub.broadcast_approval(req)
    result
  end

  defp tap_broadcast_tuple(other), do: other

  # -- Grants ---------------------------------------------------------

  @doc """
  Peek a usable grant for the given dispatch. Returns the grant, or
  `nil` if none matches — `peek_*` per CLAUDE.md §1.1 convention for
  nil-or-struct internal lookups.

  Matching is api_key-scoped (a grant given to one key never silently
  covers another). `runner_id` and `args_sha256` may each be either
  exact-match or NULL-as-wildcard on the grant side. Expired/revoked/
  fully-consumed grants are filtered out by `Grant.usable?/1` after
  the SQL pass — the SQL pre-filter narrows the candidate set, and
  `usable?/1` makes the final call.

  Internal — called by `Runs.dispatch_run` on the require-approval branch
  to fast-path past the gate.
  """
  def peek_matching_grant(api_key_id, action_id, runner_id, args_sha256)
      when is_binary(api_key_id) and is_binary(action_id) do
    now = DateTime.utc_now()

    Grant.Query.candidates_for_dispatch(api_key_id, action_id, now)
    |> Grant.Query.by_runner_or_wildcard(runner_id)
    |> Grant.Query.by_args_sha_or_wildcard(args_sha256)
    |> Repo.all()
    |> Enum.find(&Grant.usable?(&1, now))
  end

  @doc """
  Atomically increment uses_count + stamp last_used_at. Refuses to
  exceed `max_uses` — returns `{:error, :exhausted}` so the caller
  treats the grant as no-longer-matching (and the dispatch falls
  through to the normal approval-request path).

  Internal — used by `Runs.dispatch_run` on the grant fast-path.
  """
  def use_grant(%Grant{} = grant) do
    now = DateTime.utc_now()

    query =
      Grant.Query.consumable_by_id(grant.id, now)
      |> Grant.Query.consume_one(now)

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> {:error, :exhausted}
    end
  end

  @doc """
  Mint a grant from an approval decision. `attrs` are the operator's
  choices:

    * `:duration` — `:once`, `:one_hour`, `:one_day`, `:thirty_days`,
      or `:ninety_days`. Every grant has an explicit re-confirm
      horizon — there is intentionally no indefinite option (an
      indefinite grant on an LLM-targeted action is a forgotten
      security hole waiting to happen).
    * `:scope`    — `:exact_args` keeps the args_sha256 lock from the
      original call; `:any_args` widens to "any args for this action"

  The originating request, runner, and api_key are pulled off the
  approval `request` so the grant carries the same shape.

  Internal — called from `approve_request/4` inside the same transaction that
  marks the request decided.
  """
  def create_grant(%Request{} = request, %{} = run, granted_by_id, attrs) do
    now = DateTime.utc_now()
    duration = attrs[:duration]

    Grant.Changeset.create(%{
      account_id: request.account_id,
      api_key_id: run.api_key_id,
      action_id: run.action_id,
      runner_id: run.runner_id,
      args_sha256: if(attrs[:scope] == :any_args, do: nil, else: run.args_sha256),
      granted_by_id: granted_by_id,
      granted_at: now,
      expires_at: expires_at_for(duration, now),
      max_uses: max_uses_for(duration, attrs[:max_uses]),
      # Minting a grant also dispatches the run it was approved from —
      # that execution is the grant's first use. Record it so the UI
      # never shows "not used yet" for an action that already ran, and
      # so `max_uses` counts total executions (this one included).
      uses_count: 1,
      last_used_at: now,
      approval_request_id: request.id
    })
    |> Repo.insert()
  end

  defp expires_at_for(:once, _now), do: nil
  defp expires_at_for(:one_hour, now), do: DateTime.add(now, @one_hour_seconds, :second)
  defp expires_at_for(:one_day, now), do: DateTime.add(now, @one_day_seconds, :second)
  defp expires_at_for(:thirty_days, now), do: DateTime.add(now, @thirty_days_seconds, :second)
  defp expires_at_for(:ninety_days, now), do: DateTime.add(now, @ninety_days_seconds, :second)
  defp expires_at_for(_, _now), do: nil

  # `:once` is hardcoded to a single use regardless of any operator-set
  # cap (the duration alone already says "one shot"). For windowed
  # durations the operator's max_uses wins; default is no cap (unlimited
  # within the time window).
  defp max_uses_for(:once, _), do: 1
  defp max_uses_for(_, n) when is_integer(n) and n > 0, do: n
  defp max_uses_for(_, _), do: nil

  @doc "Operator-initiated kill switch on a grant."
  def revoke_grant(%Grant{} = grant, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_grants_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, grant.account_id) do
      Multi.new()
      |> Multi.update(:grant, Grant.Changeset.revoke(grant, Subject.actor_id(subject)))
      |> Multi.insert(:audit, fn %{grant: revoked} ->
        Audit.Events.approval_grant_revoked(subject, revoked)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{grant: revoked}} -> {:ok, revoked}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Test-only: enumerate the grants that have been minted against an API
  key. Production listings go through `list_grants_for_account/2` which
  is Subject-gated and used by the Grants LV. Used here to verify
  side-effects of `approve_request/4` in tests without rebuilding the operator
  surface in test setup.
  """
  def list_grants_for_api_key(api_key_id, opts \\ []) do
    Grant.Query.not_revoked()
    |> Grant.Query.by_api_key_id(api_key_id)
    |> Grant.Query.ordered_by_recent()
    |> Repo.list(Grant.Query, opts)
  end

  @doc """
  Lists active (un-revoked) grants for an account. `opts[:include_expired]`
  defaults to false. Grants are returned with `api_key`, `runner`,
  `granted_by` and `approval_request: :run` preloaded so the LV table can
  render labels — and the exact arguments the grant is locked to (the
  grant stores only the hash; the raw args live on the originating run) —
  without an N+1.
  """
  def list_grants_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_grants_permission()
           ) do
      {include_expired, opts} = Keyword.pop(opts, :include_expired, false)

      Grant.Query.not_revoked()
      |> Grant.Query.ordered_by_recent()
      |> maybe_filter_expired(include_expired)
      |> Authorizer.for_subject(subject)
      |> Repo.list(
        Grant.Query,
        Keyword.put_new(opts, :preload, [:api_key, :runner, :granted_by, approval_request: :run])
      )
    end
  end

  defp maybe_filter_expired(query, true), do: query
  defp maybe_filter_expired(query, false), do: Grant.Query.not_expired(query)

  def fetch_grant_by_id(id, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_grants_permission()
           ),
         true <- Repo.valid_uuid?(id) do
      Grant.Query.all()
      |> Grant.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(
        Grant.Query,
        Keyword.put_new(opts, :preload, [:api_key, :runner, :granted_by, :revoked_by])
      )
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  # -- Authorization --------------------------------------------------

  @doc "Whether `subject` may decide (approve/deny) approval requests (operator+)."
  def subject_can_decide_approval?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.decide_approval_permission())

  # -- Expiry sweep ---------------------------------------------------

  @doc """
  Atomically transition every pending request whose `expires_at` has
  passed into `"expired"`, cancel the underlying run, and write an
  audit row per expiry. Returns the count expired. Idempotent — runs
  via the `Emisar.Workers.ApprovalExpiry` cron every 5 minutes.

  Internal sweep — runs from an Oban worker with no Subject.
  """
  def expire_overdue_requests(now \\ DateTime.utc_now()) do
    expiring =
      Request.Query.pending()
      |> Request.Query.expired_at_before(now)
      |> Repo.all()

    Enum.each(expiring, &expire_one(&1, now))
    length(expiring)
  end

  defp expire_one(%Request{} = req, now) do
    Repo.transaction(fn ->
      {affected, _} =
        Request.Query.expire_pending(req.id, now)
        |> Repo.update_all([])

      if affected == 1 do
        case Runs.peek_run_by_id(req.run_id) do
          nil ->
            :ok

          %Runs.ActionRun{} = run ->
            # Roll back the whole expiry on a failed cancel so the request
            # stays pending and the next sweep retries it — otherwise the
            # request flips to `expired` while its run is still live, and the
            # sweep won't pick it up again (status no longer pending).
            case Runs.mark_cancelled(run, "approval expired without decision") do
              {:ok, _} -> :ok
              {:error, reason} -> Repo.rollback({:cancel_failed, reason})
            end
        end

        Audit.log(req.account_id, "approval.expired",
          actor_kind: "system",
          subject_kind: "approval_request",
          subject_id: req.id,
          payload: %{
            run_id: req.run_id,
            expires_at: req.expires_at
          }
        )

        reloaded =
          Request.Query.all() |> Request.Query.by_id(req.id) |> Repo.fetch!(Request.Query)

        PubSub.broadcast_approval(reloaded)
      end
    end)
  end
end
