defmodule Emisar.Approvals do
  @moduledoc """
  Approval requests for runs that policy gated, plus the durable
  "grants" that let identical follow-up calls bypass the gate for a
  bounded window without re-prompting the operator.

  Flow:

    1. `Runs.dispatch_run` evaluates policy → `:require_approval`.
    2. It calls `Approvals.peek_matching_grant/5` for the calling API
       key. If a usable grant exists, dispatch fast-paths past
       approval (and increments the grant's use count).
    3. Otherwise `Approvals.create_request/3` files an approval row
       and the LLM-facing endpoint returns `pending_approval` with a
       run id for the LLM to poll on.
    4. The operator decides in the UI. On approve, they pick a
       duration (once / 1h / 24h / 30d / 90d — every grant has an
       explicit re-confirm horizon) and an arg-match scope (exact /
       any) — those choices populate a new `Approvals.Grant` so the
       LLM doesn't have to ask again next time within that window.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.Accounts
  alias Emisar.ApiKeys
  alias Emisar.Approvals.{Authorizer, Decision, Grant, Request}
  alias Emisar.{Audit, Auth, Repo, Runs}
  alias Emisar.Auth.Subject
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [job_module("ExpireOverdueRequests")]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  def list_pending_approval_requests(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_approvals_permission()
           ) do
      # Oldest-pending-first (a FIFO queue). The order_by opt overrides the
      # query module's default (recent-first) cursor so the effective ORDER BY
      # equals the keyset tuple — otherwise pre-ordering and cursor disagree and
      # rows are skipped/duplicated across pages.
      opts = Keyword.put_new(opts, :order_by, [{:requests, :asc, :requested_at}])

      Request.Query.pending()
      |> scope_requests_to_subject(subject)
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
        |> scope_requests_to_subject(subject)
        |> Authorizer.for_subject(subject)
        |> Repo.aggregate(:count)

      _ ->
        0
    end
  end

  @doc """
  Internal — monthly report job: approval activity for one account. The
  window `[from, to)` yields requested/approved/denied counts; `pending` is the
  account's current all-time backlog (a call-to-action, not window-bound).
  Subject-less — the job scopes by the explicit, already-bounded `account_id`.
  """
  def report_request_stats(account_id, %DateTime{} = from, %DateTime{} = to) do
    window_totals =
      Request.Query.all()
      |> Request.Query.by_account_id(account_id)
      |> Request.Query.requested_in_window(from, to)
      |> Request.Query.status_totals()
      |> Repo.one()

    pending =
      Request.Query.pending()
      |> Request.Query.by_account_id(account_id)
      |> Repo.aggregate(:count)

    Map.put(window_totals, :pending, pending)
  end

  @doc """
  Internal — telemetry sampler. FLEET-WIDE (no subject, every account): the
  count of unresolved approval requests and the age, in seconds, of the
  longest-waiting one. Drives the `emisar.approvals.pending.*` ops gauges,
  which are fleet-wide by design — a per-account series would leak tenant
  cardinality (see `Emisar.Telemetry`). Returns `%{count: 0, oldest_age_seconds: 0}`
  when the queue is empty.
  """
  @spec pending_queue_stats() :: %{
          count: non_neg_integer(),
          oldest_age_seconds: non_neg_integer()
        }
  def pending_queue_stats do
    pending = Request.Query.pending()

    count = Repo.aggregate(pending, :count)
    oldest = Repo.aggregate(pending, :min, :inserted_at)

    age_seconds =
      case oldest do
        %DateTime{} = ts -> max(DateTime.diff(DateTime.utc_now(), ts, :second), 0)
        nil -> 0
      end

    %{count: count, oldest_age_seconds: age_seconds}
  end

  def list_approval_requests_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_approvals_permission()
           ) do
      {status, opts} = Keyword.pop(opts, :status)
      {limit, opts} = Keyword.pop(opts, :limit, 100)
      opts = Keyword.put_new(opts, :page, limit: limit)

      # No pre-ordering: the query module's cursor (recent-first) drives the
      # ORDER BY so it matches the keyset WHERE.
      Request.Query.all()
      |> apply_request_status_filter(status)
      |> scope_requests_to_subject(subject)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Request.Query, opts)
    end
  end

  defp apply_request_status_filter(query, nil), do: query
  # :decided = everything a human (or expiry) already resolved — the approvals
  # page's "Recent decisions" section queries THIS, never "all minus pending"
  # client-side (which made the pager count lie and orphaned rows past page 1).
  defp apply_request_status_filter(query, :decided), do: Request.Query.decided(query)
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
      |> scope_requests_to_subject(subject)
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

  Status-agnostic by design (`Query.all()`, no status filter): returns the
  request whatever its status, because the run-detail banner + approval-detail
  page must show a DECIDED request's outcome. Denying/approving updates status
  (never deletes), and the expiry sweeper only touches pending rows, so a
  decided request always persists and stays fetchable.
  """
  def fetch_approval_request_by_run_id(run_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_approvals_permission()
           ) do
      Request.Query.all()
      |> Request.Query.by_run_id(run_id)
      |> scope_requests_to_subject(subject)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Request.Query)
    end
  end

  @doc """
  Reads the approval attached to an already-authorized visible run.

  API clients do not receive the account approvals permission, but they need
  the bounded request URL and expiry for their own run status. The caller must
  supply the run returned by the Runs context; this function independently
  checks run-view permission and account membership before reading it.
  """
  def fetch_request_for_visible_run(
        %Runs.ActionRun{account_id: account_id, id: run_id},
        %Subject{} = subject
      ) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Runs.Authorizer.view_runs_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account_id) do
      Request.Query.all()
      |> Request.Query.by_run_id(run_id)
      |> Request.Query.by_account_id(account_id)
      |> Repo.fetch(Request.Query)
    end
  end

  @doc """
  The recorded votes on a request, oldest first, with each decider preloaded
  for the UI tally. Requires `view` on approvals; account-scoped (via the
  `:approval_decisions` Authorizer clause). Returns `{:ok, [decision]}`.
  """
  def list_decisions_for_request(%Request{} = request, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_approvals_permission()
           ),
         {:ok, _request} <- fetch_approval_request_by_id(request.id, subject) do
      decisions =
        Decision.Query.all()
        |> Decision.Query.by_request_id(request.id)
        |> Decision.Query.with_preloaded_decider()
        |> Decision.Query.ordered_by_decided()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, decisions}
    end
  end

  @doc """
  Distinct-approver tally for a request — the "N" in "N of M approvals".
  Requires `view`; account-scoped. Returns `{:ok, count}`.
  """
  def approved_count_for_request(%Request{} = request, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_approvals_permission()
           ),
         {:ok, _request} <- fetch_approval_request_by_id(request.id, subject) do
      {:ok, Repo.one(Decision.Query.approved_distinct_decider_count(request.id))}
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

  # The standing-grant durations, in display order. `:once` is single-use (no
  # grant); the rest are windowed and subject to the account's lifetime cap.
  @grant_durations [:once, :one_hour, :one_day, :thirty_days, :ninety_days]

  @doc """
  Internal — called from `Runs.dispatch_run` (already authorized via its
  own Subject) to file an approval request for a gated run.
  `requested_by_id` is whoever asked for the run (UI/runbook); for an
  MCP-triggered run it's `nil` and the effective requester is resolved to
  the api-key owner. `opts` carries the gate snapshot: `:min_approvals`
  (default 1) and `:allow_self_approval` (default true), stamped onto the
  request so a later policy edit can't move this request's bar.
  """
  def create_request(%Runs.ActionRun{} = run, requested_by_id, reason \\ nil, opts \\ []) do
    changeset = request_changeset(run, requested_by_id, reason, opts)

    with {:ok, request} <- Repo.insert(changeset) do
      notify_approval_created(request, run)
      {:ok, request}
    end
  end

  @doc """
  Internal — compose the approval-request insert into the dispatch transaction
  (`Runs.create_run`'s `:compose` hook), so a gated run and its request commit
  ATOMICALLY: a failed request insert rolls the run back rather than leaving a
  permanent `:pending_approval` run with no request. Reads the run from
  `changes[run_key]`. Broadcast + email are post-commit through
  `notify_request_created/1`.
  """
  def create_request_in_multi(multi, run_key, requested_by_id, reason, opts) do
    request_key = nested_multi_key(:approval_request, run_key)

    Multi.insert(
      multi,
      request_key,
      &request_changeset(Map.fetch!(&1, run_key), requested_by_id, reason, opts)
    )
  end

  @doc "Internal — `Runs.create_run` post-commit hook for the atomic approval-dispatch path."
  def notify_request_created(%{
        approval_request: %Request{} = request,
        run: %Runs.ActionRun{} = run
      }),
      do: notify_approval_created(request, run)

  @doc "Internal — post-commit notification for a request composed under dynamic Multi keys."
  def notify_request_created(%Request{} = request, %Runs.ActionRun{} = run),
    do: notify_approval_created(request, run)

  defp request_changeset(%Runs.ActionRun{} = run, requested_by_id, reason, opts) do
    now = DateTime.utc_now()
    default_expiry = DateTime.add(now, @default_pending_ttl_hours * @one_hour_seconds, :second)
    expires_at = earliest_expiry(default_expiry, Keyword.get(opts, :expires_at))

    # Why: an MCP run's `requested_by_id` is nil (the run's requester is an
    # api_key), so "self" must record the HUMAN behind the trigger — the
    # api-key's owner. Stamping the owner here means `allow_self_approval=false`
    # can't be laundered through one's own key by routing the run via MCP.
    Request.Changeset.create(%{
      account_id: run.account_id,
      run_id: run.id,
      requested_by_id: effective_requester(run, requested_by_id),
      requested_at: now,
      expires_at: expires_at,
      reason: reason,
      # Evidence + expected are the run's own snapshot — no caller overrides them,
      # so read them off the run rather than threading two more params through the
      # dispatch (reason stays a param because a direct create_request can set it).
      evidence: run.evidence,
      expected: run.expected,
      min_approvals: Keyword.get(opts, :min_approvals, 1),
      allow_self_approval: Keyword.get(opts, :allow_self_approval, true),
      context: %{
        runner_id: run.runner_id,
        action_id: run.action_id,
        args_sha256: run.args_sha256
      }
    })
  end

  defp earliest_expiry(default, %DateTime{} = requested) do
    if DateTime.compare(requested, default) == :lt, do: requested, else: default
  end

  defp earliest_expiry(default, _requested), do: default

  # Post-commit side effects for a newly filed request: light up the approvals
  # feed + email every eligible decider. Email dispatch is detached in prod so a
  # slow SMTP call never blocks the caller's dispatch path; synchronous in tests
  # so the sandbox connection isn't released while a task still queries the DB
  # (`:notify_approvers_async?` flips this).
  defp notify_approval_created(%Request{} = request, %Runs.ActionRun{} = run) do
    broadcast_approval(request)
    run_notify(fn -> notify_approvers(request, run, request.requested_by_id) end)
    :ok
  end

  # The passed requester wins when present (UI/runbook); otherwise an
  # api-key-triggered run attributes the request to the key's owner.
  defp effective_requester(%Runs.ActionRun{api_key_id: nil}, passed), do: passed
  defp effective_requester(%Runs.ActionRun{}, passed) when is_binary(passed), do: passed

  defp effective_requester(%Runs.ActionRun{api_key_id: api_key_id}, nil),
    do: ApiKeys.fetch_owner_user_id(api_key_id)

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
      supervisor = Application.fetch_env!(:emisar, :task_supervisor)
      Task.Supervisor.start_child(supervisor, fun)
    else
      fun.()
    end
  end

  # Per-page batch size — large enough to cap page count (accounts top
  # out in the hundreds of admins in practice) but small enough that one
  # batch isn't a memory hazard if a future plan removes the cap entirely.
  @notify_page_size 200

  defp notify_approvers(%Request{} = request, run, requested_by_id) do
    # Preload runner so the email body can show the runner's name
    # ("db-prod-01") instead of its UUID — approvers shouldn't need to
    # context-switch into the app just to know what's being touched.
    run = Repo.preload(run, :runner)

    # Preload the account so the email can build the canonical slugged
    # approval link (/app/:account/approvals/:id) — a slug-less URL 404s.
    request = Repo.preload(request, :account)

    notify_approvers_pages(request, run, requested_by_id, nil)
  end

  # Cursor-walk the membership pages so accounts with >100 admins still
  # get full coverage — earlier code capped at a single 100-row page,
  # silently skipping everyone after.
  defp notify_approvers_pages(%Request{} = request, run, requested_by_id, cursor) do
    page_opts =
      [limit: @notify_page_size]
      |> then(fn opts -> if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts end)

    {:ok, memberships, %{next_page_cursor: next}} =
      Accounts.list_account_memberships(request.account_id, page: page_opts)

    approver_roles =
      Auth.Permissions.roles_with_permission(Authorizer.decide_approval_permission())

    memberships
    |> Enum.filter(fn membership ->
      # Only members who can decide get pinged (viewers can't); the user who
      # triggered the request is excluded since they already saw it in the UI.
      membership.role in approver_roles and membership.user_id != requested_by_id
    end)
    |> Enum.each(&deliver_approval_email(&1, request, run))

    if next,
      do: notify_approvers_pages(request, run, requested_by_id, next),
      else: :ok
  end

  defp deliver_approval_email(membership, request, run) do
    # Mailer.deliver returns {:ok, _} on success and {:error, reason}
    # on transport failure (Mailgun 5xx, SMTP timeout). It DOES NOT
    # raise on non-success — a bare rescue would silently drop
    # delivery errors. Pattern-match and log non-success explicitly.
    case Emisar.Mailers.UserNotifier.deliver_approval_request(membership.user, request, run) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("approval_email_failed",
          user_id: membership.user_id,
          req_id: request.id,
          error: inspect(reason)
        )
    end
  rescue
    err ->
      Logger.warning("approval_email_crashed",
        user_id: membership.user_id,
        req_id: request.id,
        error: inspect(err)
      )
  end

  @doc """
  Record an approver's vote and, when the threshold is met, dispatch the
  gated run. Requires `decide` on approvals; scoped to the subject's account.

  `opts` controls whether to mint a durable `Grant` alongside the FINALIZING
  approval so future identical calls bypass the gate:

    * `:duration` — `:once` (no grant), `:one_hour`, `:one_day`,
      `:thirty_days`, or `:ninety_days`. Default: `:once`.
    * `:scope`    — `:exact_args` (locks args fingerprint) or
      `:any_args` (any args for this action). Default: `:exact_args`.
    * `:max_uses` — for a windowed duration, cap on total executions
      (nil = unlimited within the window); `:once` is always one use.

  Returns `{:ok, {request, run}}` when the vote finalizes + dispatches,
  `{:ok, {request, :pending}}` when recorded but below the distinct-approver
  threshold, or `{:error, :self_approval_forbidden | :already_decided |
  :expired | :unauthorized | :not_found | {:grant_failed, changeset}}`.
  """
  def approve_request(%Request{} = request, %Subject{} = subject, reason \\ nil, opts \\ []),
    do: record_decision(request, subject, :approve, reason, opts)

  @doc """
  Deny a pending request — one deny finalizes DENIED, cancels the run, and no
  later approve can out-vote it. Requires `decide`; scoped to the account.
  Returns `{:ok, {request, run}}` or `{:error, :already_decided | :expired |
  :unauthorized | :not_found}`.
  """
  def deny_request(%Request{} = request, %Subject{} = subject, reason \\ nil),
    do: record_decision(request, subject, :deny, reason, [])

  # The single decision path. Fetch the request through the subject scope before
  # evaluating any request-derived guard: callers can hold a stale struct, and
  # must not be able to pair another account's id with their own account_id.
  # The Multi then re-reads the same scoped row under lock, inserts this
  # decider's DB-unique vote, and finalizes on that locked row so concurrent
  # votes serialize. Dispatch fires only after a committed :approved transition.
  defp record_decision(
         %Request{} = supplied_request,
         %Subject{} = subject,
         decision,
         reason,
         opts
       ) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.decide_approval_permission()
           ),
         {:ok, request} <- fetch_approval_request_for_decision(supplied_request.id, subject),
         :ok <- check_self_approval(decision, request, subject),
         :ok <- recheck_trust(decision, request),
         :ok <- check_attestation_fresh(decision, request) do
      by_user_id = Subject.actor_id(subject)

      grant_attrs = %{
        duration: Keyword.get(opts, :duration, :once),
        scope: Keyword.get(opts, :scope, :exact_args),
        max_uses: Keyword.get(opts, :max_uses)
      }

      result =
        Multi.new()
        |> Multi.run(:locked, fn repo, _changes ->
          locked =
            Request.Query.all()
            |> Request.Query.by_id(request.id)
            |> scope_requests_to_subject(subject)
            |> Authorizer.for_subject(subject)
            |> Request.Query.lock_for_update()
            |> repo.one()

          case locked do
            %Request{} = locked -> {:ok, locked}
            nil -> {:error, :not_found}
          end
        end)
        |> Multi.run(:decision, fn _repo, %{locked: locked} ->
          insert_decision(locked, by_user_id, decision)
        end)
        |> Multi.run(:outcome, fn repo, %{locked: locked} ->
          finalize(repo, locked, decision, by_user_id, reason, grant_attrs)
        end)
        # A finalizing deny cancels the run as steps in THIS transaction (no
        # premature broadcast) — they run only when :outcome succeeded, so the
        # run + its `run.cancelled` audit commit atomically with the denial and
        # the broadcasts are hoisted to after_decision + fan_out.
        |> maybe_cancel_run(decision, request, reason)
        |> Multi.insert(:audit, fn %{outcome: outcome} ->
          Audit.Events.approval_decision_recorded(
            subject,
            request,
            decision,
            reason,
            outcome.approved_count
          )
        end)
        # The finalization transition gets its OWN audit row (approval.approved /
        # approval.denied) so the log shows each vote and the release separately.
        # Sub-threshold votes finalize nothing → no second row.
        |> Multi.run(:finalize_audit, fn _repo, %{outcome: outcome} ->
          insert_finalize_audit(subject, request, reason, outcome)
        end)
        |> Repo.commit_multi(after_commit: &after_decision/1)

      with {:ok, changes} <- result do
        decision_result(changes)
      end
    end
  end

  defp fetch_approval_request_for_decision(id, %Subject{} = subject) do
    Request.Query.all()
    |> Request.Query.by_id(id)
    |> scope_requests_to_subject(subject)
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(Request.Query)
  end

  # Self-approval gate (server-side, IL-15 — UI hiding is cosmetic only). Only an
  # APPROVE by the recorded requester is blocked, and only when the request's
  # snapshotted policy forbade self-approval. Deny and the permissive case fall
  # through. Self-approval is a policy setting only — there is no account-wide flag.
  defp check_self_approval(:approve, %Request{allow_self_approval: false} = request, subject) do
    if self?(subject, request), do: {:error, :self_approval_forbidden}, else: :ok
  end

  defp check_self_approval(_decision, _request, _subject), do: :ok

  defp self?(%Subject{} = subject, %Request{requested_by_id: rb}) when is_binary(rb),
    do: Subject.actor_id(subject) == rb

  # No resolvable requester (e.g. an api-key whose creator was since deleted →
  # nil owner) has no "self", so the self-approval gate is vacuous for it. That
  # is not a bypass: min_approvals still requires N distinct approvers, and the
  # ghost requester can't log in to approve. Failing closed here (block everyone)
  # would instead strand such a request forever.
  defp self?(_subject, _request), do: false

  # Re-gate pack trust before an approve: the pack could have drifted to
  # :pending (a tampered re-advertisement) since the run was parked. The
  # finalizing approve re-dispatches, so without this the operator's "yes"
  # against the trusted bytes would ship the new ones. Deny needs no trust
  # check — it cancels.
  defp recheck_trust(:approve, %Request{run_id: run_id}), do: Runs.recheck_run_pack_trust(run_id)
  defp recheck_trust(:deny, _request), do: :ok

  # Fail-fast: refuse an approve when the parked signed dispatch would already
  # be stale at the enforcing runner (the runner remains authoritative).
  defp check_attestation_fresh(:approve, %Request{run_id: run_id}),
    do: Runs.check_run_attestation_fresh(run_id)

  defp check_attestation_fresh(:deny, _request), do: :ok

  # Insert this decider's vote; a second vote by the same operator hits the
  # (request_id, decider_id) unique index → :already_decided.
  defp insert_decision(%Request{} = request, by_user_id, decision) do
    Decision.Changeset.create(request.account_id, request.id, by_user_id, %{
      decision: decision,
      decided_at: DateTime.utc_now()
    })
    |> Repo.insert()
    |> case do
      {:ok, decision_row} -> {:ok, decision_row}
      {:error, changeset} -> insert_decision_error(changeset)
    end
  end

  defp insert_decision_error(changeset) do
    # The shared unique-error test — never a per-context copy.
    if Emisar.Repo.Changeset.unique_constraint_error?(changeset),
      do: {:error, :already_decided},
      else: {:error, changeset}
  end

  # Finalize on the LOCKED request row. The locked row's status + the
  # distinct-approve count read INSIDE the transaction are the only inputs —
  # never the caller's stale struct. Returns an outcome map the audit step,
  # after-commit, and return shape all read from `changes`.
  defp finalize(_repo, nil, _decision, _by_user_id, _reason, _grant_attrs),
    do: {:error, :not_found}

  defp finalize(_repo, %Request{status: :pending} = locked, :deny, by_user_id, reason, _attrs) do
    # One deny finalizes DENIED; no approve can override it (a later decision
    # insert may succeed, but the request is no longer pending, so finalize
    # returns :already_decided for them). The run cancel is composed as steps in
    # the outer transaction by maybe_cancel_run/4 — not here — so it can't
    # broadcast before the denial commits.
    with {:ok, denied} <- guarded_transition(locked, :denied, by_user_id, reason) do
      {:ok, %{action: :cancelled, request: denied, approved_count: nil}}
    end
  end

  defp finalize(repo, %Request{status: :pending} = locked, :approve, by_user_id, reason, attrs) do
    count = repo.one(Decision.Query.approved_distinct_decider_count(locked.id))

    if count >= locked.min_approvals,
      do: finalize_approved(repo, locked, by_user_id, reason, attrs, count),
      else: {:ok, %{action: :recorded_pending, request: locked, run: nil, approved_count: count}}
  end

  # Locked row already decided (another vote finalized first, or it expired):
  # the vote is recorded but can't change the outcome.
  defp finalize(_repo, %Request{status: :expired}, _decision, _by, _reason, _attrs),
    do: {:error, :expired}

  # The gated run was cancelled (its request was cancelled atomically), so there
  # is nothing left to approve — a stale approve must NOT resurrect it.
  defp finalize(_repo, %Request{status: :cancelled}, _decision, _by, _reason, _attrs),
    do: {:error, :run_cancelled}

  defp finalize(_repo, %Request{}, _decision, _by_user_id, _reason, _attrs),
    do: {:error, :already_decided}

  # Compose the run cancel into the decision transaction — only for a deny.
  # The steps sit after :outcome, so they execute only when the deny actually
  # finalized (a non-pending locked row makes :outcome error → the Multi aborts
  # → no cancel). Approve dispatches its run post-commit instead; a sub-threshold
  # vote touches no run. `request.run_id` is immutable, so the original struct's
  # id is correct.
  defp maybe_cancel_run(multi, :deny, %Request{run_id: run_id}, reason),
    do: Runs.cancel_run_in_multi(multi, run_id, denial_reason(reason))

  defp maybe_cancel_run(multi, :approve, _request, _reason), do: multi

  # Threshold met: flip to :approved on the locked row and mint the grant HERE
  # (only on the finalizing approve, so sub-threshold votes never mint). The
  # run dispatches after-commit.
  defp finalize_approved(repo, %Request{} = locked, by_user_id, reason, attrs, count) do
    # Lock the gated run IN THIS transaction and confirm it's still
    # `:pending_approval` — a cancel/expiry between parking and this approval
    # makes it non-dispatchable, so the approve must abort rather than resurrect
    # it. With the request + run both locked, the decision is atomic.
    with {:ok, run} <- Runs.fetch_and_lock_pending_approval_run(repo, locked.run_id),
         :ok <- Runs.ensure_run_initiator_authorized(repo, run),
         {:ok, approved} <- guarded_transition(locked, :approved, by_user_id, reason),
         {:ok, released_run} <- Runs.release_pending_approval_run(run, repo: repo),
         {:ok, grant} <- mint_grant(locked, released_run, by_user_id, attrs) do
      {:ok,
       %{
         action: :dispatch,
         request: approved,
         run: released_run,
         grant: grant,
         grant_attrs: attrs,
         approved_count: count
       }}
    end
  end

  # A grant is minted only for a windowed duration on an api-key-triggered
  # run; `:once` and a runner-/operator-sourced run mint nothing.
  defp mint_grant(%Request{}, %{api_key_id: nil}, _by_user_id, _attrs), do: {:ok, nil}
  defp mint_grant(%Request{}, _run, _by_user_id, %{duration: :once}), do: {:ok, nil}

  defp mint_grant(%Request{} = request, %Runs.ActionRun{} = run, by_user_id, attrs) do
    case create_grant(request, run, by_user_id, attrs) do
      {:ok, grant} ->
        {:ok, grant}

      {:error, :grant_exceeds_account_max_lifetime} ->
        {:error, :grant_exceeds_account_max_lifetime}

      {:error, changeset} ->
        {:error, {:grant_failed, changeset}}
    end
  end

  # The guarded UPDATE — flips a still-pending, non-expired row to `status`,
  # stamping decider/reason. 0 rows means another decision or the expiry landed
  # between the lock and here → classify so the caller flashes the right cause.
  defp guarded_transition(%Request{} = locked, status, by_user_id, reason) do
    now = DateTime.utc_now()

    {affected, _} =
      Request.Query.decide_pending(locked.id, status, by_user_id, reason, now)
      |> Repo.update_all([])

    case affected do
      1 ->
        transitioned =
          Request.Query.all() |> Request.Query.by_id(locked.id) |> Repo.fetch!(Request.Query)

        {:ok, transitioned}

      0 ->
        {:error, claim_blocked_reason(locked.id, now)}
    end
  end

  # Finalization audit — only on a release. The dispatch branch carries the
  # minted grant + attrs for `approval_approved`; a deny logs `approval_denied`.
  defp insert_finalize_audit(subject, request, reason, %{
         action: :dispatch,
         grant: grant,
         grant_attrs: grant_attrs
       }) do
    Audit.Events.approval_approved(subject, request, reason, grant, grant_attrs)
    |> Repo.insert()
  end

  defp insert_finalize_audit(subject, request, reason, %{action: :cancelled}) do
    Audit.Events.approval_denied(subject, request, reason)
    |> Repo.insert()
  end

  defp insert_finalize_audit(_subject, _request, _reason, %{action: :recorded_pending}),
    do: {:ok, nil}

  # After-commit side effects, keyed off the committed outcome. Dispatch fires
  # ONLY on a finalizing approve (:dispatch) — never on a sub-threshold vote.
  defp after_decision(%{outcome: %{action: :dispatch, run: run, request: request}}) do
    broadcast_approval(request)
    count_approval_decision(request)
    Runs.dispatch_to_runner(run)
  end

  defp after_decision(%{outcome: %{action: :cancelled, request: request}, run_cancel: run_cancel}) do
    broadcast_approval(request)
    count_approval_decision(request)
    Runs.broadcast_cancelled_run(run_cancel)
  end

  defp after_decision(%{outcome: %{request: request}}) do
    broadcast_approval(request)
    count_approval_decision(request)
    :ok
  end

  # Telemetry: count a request only when it reaches a TERMINAL decision. A
  # partial approval (still :pending below the threshold) is not an outcome.
  defp count_approval_decision(%Request{status: status})
       when status in [:approved, :denied, :expired],
       do: Emisar.Telemetry.approval_decided(status)

  defp count_approval_decision(_request), do: :ok

  # Return shapes: a finalizing approve reloads the now-:sent run;
  # recorded-but-sub-threshold returns {request, :pending}; a deny returns the
  # cancelled run.
  defp decision_result(%{outcome: %{action: :dispatch, request: request, run: run}}),
    do: {:ok, {request, Repo.reload!(run)}}

  defp decision_result(%{outcome: %{action: :recorded_pending, request: request}}),
    do: {:ok, {request, :pending}}

  defp decision_result(%{
         outcome: %{action: :cancelled, request: request},
         run_cancel: run_cancel
       }),
       do: {:ok, {request, run_from_cancel(run_cancel)}}

  defp run_from_cancel({:cancelled, %Runs.ActionRun{} = run}), do: run
  defp run_from_cancel({:noop, %Runs.ActionRun{} = run}), do: run

  defp denial_reason(nil), do: "approval denied"
  defp denial_reason(reason), do: "approval denied: " <> reason

  defp claim_blocked_reason(request_id, now) do
    query = Request.Query.all() |> Request.Query.by_id(request_id)

    case Repo.peek(query) do
      %Request{status: :expired} ->
        :expired

      %Request{status: :pending, expires_at: %DateTime{} = expires_at} ->
        if DateTime.compare(expires_at, now) == :gt, do: :already_decided, else: :expired

      _ ->
        :already_decided
    end
  end

  @doc """
  Internal — compose into `Runs.cancel_run`'s transaction: when a
  `:pending_approval` run is cancelled, its still-pending approval request is
  flipped to `:cancelled` atomically, so a stale approve can never resurrect +
  dispatch the run. No broadcast here (the caller hoists it post-commit). Result
  lands in `changes.request_cancel` as `{:cancelled, request}` or `:none`.
  """
  def cancel_request_for_run_in_multi(multi, run_id) when is_binary(run_id) do
    Multi.run(multi, :request_cancel, fn repo, _changes ->
      now = DateTime.utc_now()
      {count, _} = repo.update_all(Request.Query.cancel_pending_by_run_id(run_id, now), [])

      if count >= 1 do
        request =
          Request.Query.all()
          |> Request.Query.by_run_id(run_id)
          |> Request.Query.ordered_by_recent()
          |> Request.Query.limit_to(1)
          |> repo.one()

        {:ok, {:cancelled, request}}
      else
        {:ok, :none}
      end
    end)
  end

  @doc "Internal — `Runs.cancel_run` after-commit broadcast for a run-cancel-driven request cancel."
  def broadcast_request_cancelled({:cancelled, %Request{} = request}),
    do: broadcast_approval(request)

  def broadcast_request_cancelled(_), do: :ok

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account's approval feed (`{:approval_updated, request}`)."
  def subscribe_account_approvals(account_id),
    do: Emisar.PubSub.subscribe(account_approvals_topic(account_id))

  defp account_approvals_topic(account_id), do: "account:#{account_id}:approvals"

  defp broadcast_approval(%Request{} = request) do
    Emisar.PubSub.broadcast(
      account_approvals_topic(request.account_id),
      {:approval_updated, request}
    )
  end

  # -- Grants ---------------------------------------------------------

  @doc """
  Internal — called by `Runs.dispatch_run` on the require-approval branch
  (already-authorized run context) to fast-path past the gate. Peeks a
  usable grant for the given dispatch; returns the grant, or `nil` if none
  matches — `peek_*` per AGENTS.md §1.1 convention for nil-or-struct
  internal lookups.

  Matching is api_key-scoped (a grant given to one key never silently
  covers another), and `pack_ref` binds it to the exact trusted action
  contract. `runner_id` and `args_sha256` may each be either exact-match or
  NULL-as-wildcard on the grant side. Expired/revoked/fully-consumed grants
  are filtered out by `Grant.usable?/1` after the SQL pass — the SQL
  pre-filter narrows the candidate set, and `usable?/1` makes the final call.
  """
  def peek_matching_grant(account_id, api_key_id, action_id, pack_ref, runner_id, args_sha256)
      when is_binary(account_id) and is_binary(api_key_id) and is_binary(action_id) and
             is_binary(pack_ref) do
    # The account-level kill switch (cap = 0) lives HERE, inside matching —
    # disabling standing grants makes existing rows inert immediately, and a
    # future caller can't forget the check.
    if account_grant_lifetime_cap(account_id) == 0 do
      nil
    else
      now = DateTime.utc_now()

      Grant.Query.candidates_for_dispatch(api_key_id, action_id, pack_ref, now)
      |> Grant.Query.by_runner_or_wildcard(runner_id)
      |> Grant.Query.by_args_sha_or_wildcard(args_sha256)
      |> Repo.all()
      |> Enum.find(&Grant.usable?(&1, now))
    end
  end

  @doc """
  Internal — compose a grant consumption into `Runs.create_run`'s Multi (the
  grant fast-path), so a grant use is burned ONLY when the run is durably
  created in the same transaction, never on a validation failure (MAJOR-3).
  Returns `{:error, :grant_unusable}` if the grant lapsed between the peek and
  commit, so the caller can fall back to the normal approval flow.
  """
  def consume_grant_in_multi(multi, run_key, %Grant{} = grant) do
    grant_key = nested_multi_key(:grant_use, run_key)

    Multi.run(multi, grant_key, fn repo, _changes ->
      consume_grant(repo, grant)
    end)
  end

  defp nested_multi_key(key, :run), do: key
  defp nested_multi_key(key, run_key), do: {key, run_key}

  defp consume_grant(repo, %Grant{} = grant) do
    now = DateTime.utc_now()
    query = Grant.Query.consumable_by_id(grant.id, now) |> Grant.Query.consume_one(now)

    case repo.update_all(query, []) do
      {1, _} -> {:ok, :consumed}
      {0, _} -> {:error, :grant_unusable}
    end
  end

  @doc """
  Internal — called from `approve_request/4` (already-authorized) inside
  the same transaction that marks the request decided, to mint a grant
  from an approval decision. `attrs` are the operator's choices:

    * `:duration` — `:once`, `:one_hour`, `:one_day`, `:thirty_days`,
      or `:ninety_days`. Every grant has an explicit re-confirm
      horizon — there is intentionally no indefinite option (an
      indefinite grant on an LLM-targeted action is a forgotten
      security hole waiting to happen).
    * `:scope`    — `:exact_args` keeps the args_sha256 lock from the
      original call; `:any_args` widens to "any args for this action"

  The originating request, runner, and api_key are pulled off the
  approval `request` so the grant carries the same shape.
  """
  def create_grant(%Request{} = request, %Runs.ActionRun{} = run, granted_by_id, attrs) do
    now = DateTime.utc_now()
    duration = attrs[:duration]

    with :ok <- check_grant_within_account_cap(request.account_id, duration) do
      Grant.Changeset.create(%{
        account_id: request.account_id,
        api_key_id: run.api_key_id,
        action_id: run.action_id,
        pack_ref: run.pack_ref,
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
  end

  @doc """
  The standing-grant durations an account may pick, in display order, filtered
  by its max-grant-lifetime cap. `:once` (single-use, not a standing grant) is
  always allowed. The approval form renders only these, so an approver can't
  pick a duration the server would reject — both this and the
  `check_grant_within_account_cap/2` backstop share `grant_duration_within_cap?/2`,
  so the UI and the gate can't drift apart.
  """
  def allowed_grant_durations(account_id) when is_binary(account_id) do
    cap = account_grant_lifetime_cap(account_id)
    Enum.filter(@grant_durations, &grant_duration_within_cap?(&1, cap))
  end

  # A regulated account can cap the maximum standing-grant DURATION
  # (Accounts `max_grant_lifetime_seconds`). The approval UI hides over-cap
  # durations (`allowed_grant_durations/1`), but this is the IL-15 server
  # backstop that holds even if the UI is bypassed.
  defp check_grant_within_account_cap(account_id, duration) do
    cap = account_grant_lifetime_cap(account_id)

    if grant_duration_within_cap?(duration, cap) do
      :ok
    else
      {:error, :grant_exceeds_account_max_lifetime}
    end
  end

  # `:once` is single-use (exempt); an uncapped account allows everything; a
  # windowed duration is allowed only when it fits inside the cap.
  defp grant_duration_within_cap?(:once, _cap), do: true
  defp grant_duration_within_cap?(_duration, nil), do: true
  defp grant_duration_within_cap?(duration, cap), do: duration_seconds_for(duration) <= cap

  # The account's grant-lifetime cap (nil = no cap, 0 = standing grants
  # DISABLED — no windowed duration fits inside 0, and matching short-circuits
  # above). Reads the one settings
  # value Approvals enforces off `Accounts.fetch_account_settings/1`; a missing
  # account means no cap to apply on this path.
  defp account_grant_lifetime_cap(account_id) do
    case Accounts.fetch_account_settings(account_id) do
      {:ok, settings} -> settings.max_grant_lifetime_seconds
      {:error, :not_found} -> nil
    end
  end

  defp duration_seconds_for(:one_hour), do: @one_hour_seconds
  defp duration_seconds_for(:one_day), do: @one_day_seconds
  defp duration_seconds_for(:thirty_days), do: @thirty_days_seconds
  defp duration_seconds_for(:ninety_days), do: @ninety_days_seconds

  # Deliberately NO catch-all: an unknown duration atom must crash, not
  # silently mint a never-expiring grant (the web layer parses operator
  # input down to exactly these atoms).
  defp expires_at_for(:once, _now), do: nil
  defp expires_at_for(:one_hour, now), do: DateTime.add(now, @one_hour_seconds, :second)
  defp expires_at_for(:one_day, now), do: DateTime.add(now, @one_day_seconds, :second)
  defp expires_at_for(:thirty_days, now), do: DateTime.add(now, @thirty_days_seconds, :second)
  defp expires_at_for(:ninety_days, now), do: DateTime.add(now, @ninety_days_seconds, :second)

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
           ) do
      by_user_id = Subject.actor_id(subject)

      Grant.Query.all()
      |> Grant.Query.by_id(grant.id)
      |> scope_grants_to_subject(subject)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Grant.Query,
        with: &Grant.Changeset.revoke(&1, by_user_id),
        audit: &Audit.Events.approval_grant_revoked(subject, &1)
      )
    end
  end

  @doc """
  Revokes EVERY un-revoked grant in the subject's account — the "disable
  standing grants" sweep. Each grant goes through `revoke_grant/2` (its own
  row lock + audit event), so the trail records every capability that was
  cut. Returns `{:ok, count}`. `%Subject{}` needs `manage_grants`.
  """
  def revoke_all_grants(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_grants_permission()
           ) do
      grants =
        Grant.Query.not_revoked()
        |> scope_grants_to_subject(subject)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      Enum.each(grants, fn grant ->
        {:ok, _} = revoke_grant(grant, subject)
      end)

      {:ok, length(grants)}
    end
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

      {preloads, opts} = Keyword.pop(opts, :preload, [])

      Grant.Query.not_revoked()
      |> Grant.Query.ordered_by_recent()
      |> maybe_filter_expired(include_expired)
      |> apply_grant_preloads(preloads)
      |> scope_grants_to_subject(subject)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Grant.Query, opts)
    end
  end

  # Rendering concerns are the caller's: pass `preload:` only for the
  # associations the page actually shows. Unknown atoms raise (caller bug).
  defp apply_grant_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :api_key, queryable ->
        Grant.Query.with_preloaded_api_key(queryable)

      :runner, queryable ->
        Grant.Query.with_preloaded_runner(queryable)

      :granted_by, queryable ->
        Grant.Query.with_preloaded_granted_by(queryable)

      :revoked_by, queryable ->
        Grant.Query.with_preloaded_revoked_by(queryable)

      :approval_request_run, queryable ->
        Grant.Query.with_preloaded_approval_request_run(queryable)
    end)
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
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      Grant.Query.all()
      |> Grant.Query.by_id(id)
      |> apply_grant_preloads(preloads)
      |> scope_grants_to_subject(subject)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Grant.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp scope_requests_to_subject(queryable, %Subject{} = subject),
    do: Request.Query.by_runner_access(queryable, Accounts.runner_access_for_subject(subject))

  defp scope_grants_to_subject(queryable, %Subject{} = subject),
    do: Grant.Query.by_runner_access(queryable, Accounts.runner_access_for_subject(subject))

  # -- Authorization --------------------------------------------------

  @doc "True when the subject may view approval requests (the console nav + section gate)."
  def subject_can_view_approvals?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_approvals_permission())

  @doc "Whether `subject` may decide (approve/deny) approval requests (operator+)."
  def subject_can_decide_approval?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.decide_approval_permission())

  @doc "Whether `subject` may manage (revoke) standing grants (owner/admin) — matches `revoke_grant/2`'s gate."
  def subject_can_manage_grants?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_grants_permission())

  # -- Expiry sweep ---------------------------------------------------

  @doc """
  Internal — the approval expiry job, system, no subject. Atomically
  transitions every pending request whose
  `expires_at` has passed into `"expired"`, cancels the underlying run,
  and writes an audit row per expiry. Returns the count expired.
  Idempotent — runs every 5 minutes.
  """
  def expire_overdue_requests(now \\ DateTime.utc_now()) do
    expiring =
      Request.Query.pending()
      |> Request.Query.expired_at_at_or_before(now)
      |> Repo.all()

    Enum.count(expiring, &expired?(&1, now))
  end

  defp expired?(%Request{} = request, now) do
    match?({:ok, _}, expire_one(request, now))
  end

  defp expire_one(%Request{} = request, now) do
    Multi.new()
    # Claim the still-pending request as expired; 0 rows means another
    # decision landed between the sweep's SELECT and here — abort as a
    # benign no-op.
    |> Multi.run(:expire, fn _repo, _changes ->
      {affected, _} = Request.Query.expire_pending(request.id, now) |> Repo.update_all([])

      case affected do
        1 -> {:ok, :expired}
        0 -> {:error, :not_pending}
      end
    end)
    # Cancel the underlying run as steps in THIS transaction (no premature
    # broadcast) so the run + its `run.cancelled` audit commit atomically with
    # the expiry — otherwise the request could flip to `expired` with its run
    # still live. A real cancel failure aborts the expiry so the next sweep
    # retries it. The run broadcast is hoisted below; the audit rides fan_out.
    |> Runs.cancel_run_in_multi(request.run_id, "approval expired without decision")
    |> Multi.insert(:audit, Audit.Events.approval_expired(request))
    |> Multi.run(:reloaded, fn _repo, _changes ->
      {:ok, Request.Query.all() |> Request.Query.by_id(request.id) |> Repo.fetch!(Request.Query)}
    end)
    |> Repo.commit_multi(
      after_commit: fn changes ->
        broadcast_approval(changes.reloaded)
        count_approval_decision(changes.reloaded)
        Runs.broadcast_cancelled_run(changes.run_cancel)
      end
    )
  end
end
