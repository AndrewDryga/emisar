defmodule Emisar.Runs do
  @moduledoc """
  Action run lifecycle. Cloud calls `dispatch_run/2` when an operator
  (or MCP, or a runbook step) wants to invoke an action; this module
  creates the run row, evaluates policy, hands the dispatch to the
  Transport for sending, and tracks progress + final result.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.Accounts
  alias Emisar.ActionContract
  alias Emisar.ApiKeys
  alias Emisar.Approvals
  alias Emisar.Audit
  alias Emisar.Auth
  alias Emisar.Auth.Subject
  alias Emisar.Catalog
  alias Emisar.Crypto
  alias Emisar.MCPOperations
  alias Emisar.RawJSON
  alias Emisar.Repo
  alias Emisar.RequestContext
  alias Emisar.Runs.{ActionRun, Attestation, Authorizer, RunEvent, RunnerError}
  alias Emisar.Users
  require Logger

  @sent_dispatch_deadline_secs 600
  # DispatchTimeout loads both sweeps into memory every 60 seconds, fleet-wide
  # and unbounded. A wide runner outage parks tens of thousands of runs, the
  # tick then takes longer than its own interval, and dispatch timeouts stop
  # being enforced during exactly the incident they exist for. Bound the batch;
  # a backlog drains over consecutive ticks instead of stalling the job.
  @sweep_batch 2_000

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

  @doc "The Runs table's `%Repo.Filter{}` list."
  def run_filters, do: ActionRun.Query.filters()

  @doc """
  Is `status` a terminal run state — settled, streaming nothing more? The
  public lifecycle classification for the web and MCP (polling, pruning,
  completion, pagination); delegates to `ActionRun.terminal?/1`, the engine's
  single source of truth, so no caller re-lists the terminal set.
  """
  def terminal_status?(status), do: ActionRun.terminal?(status)

  @doc """
  The safe outcome facts of one run, for any adapter describing it to an
  operator or a model.

  Returns `status`, whether it is `terminal?`,
  `output_complete` once the run is terminal (`nil` while it can still stream),
  whether it waits on a human as `approval_pending?`, the durable
  `dispatch_deadline_at` a `:sent` run is judged against, and the
  `local_audit_failed?` warning. Pure.
  """
  def run_outcome_facts(%ActionRun{} = run) do
    terminal? = terminal_status?(run.status)

    %{
      status: run.status,
      terminal?: terminal?,
      output_complete: if(terminal?, do: run.output_complete),
      approval_pending?: run.status == :pending_approval,
      dispatch_deadline_at: dispatch_deadline_at(run),
      local_audit_failed?: run.local_audit_failed
    }
  end

  defp dispatch_deadline_at(%ActionRun{status: :sent, queued_at: %DateTime{} = queued_at}),
    do: DateTime.add(queued_at, @sent_dispatch_deadline_secs, :second)

  defp dispatch_deadline_at(%ActionRun{}), do: nil

  @doc """
  Human-first run attribution as `{who, via}`, for a run read with
  `preload: [:attribution]`.

  `who` is the accountable human this account knows — the requesting operator,
  or an MCP run's API-key owner — named through the membership the run was
  dispatched under, so a directory rename stays account-local. It is `nil` when
  the attribution associations were not loaded (unknown is never guessed at) or
  no human row survives. `via` is the secondary channel that adds signal: the
  API-key name (falling back to "LLM agent") for an MCP run, "runbook" /
  "schedule" for engine dispatch, and `nil` for a plain operator run, where
  "via portal" says nothing. Pure.
  """
  def run_who_via(%ActionRun{} = run), do: {run_who(run), run_via(run)}

  # An unloaded requester is UNKNOWN, never a fall-through to the key owner: a
  # run read without its attribution preloads must not be attributed to whoever
  # minted a credential it happens to carry. Only an explicit `nil` requester
  # means "no operator asked for this", which is when the key's owner IS the
  # accountable human.
  defp run_who(%ActionRun{requested_by: %Users.User{} = user} = run),
    do: accountable_name(run, user, requester_membership(user))

  defp run_who(%ActionRun{requested_by: nil, api_key: %ApiKeys.ApiKey{} = api_key} = run),
    do: key_owner_name(run, api_key)

  defp run_who(%ActionRun{}), do: nil

  defp key_owner_name(
         %ActionRun{} = run,
         %ApiKeys.ApiKey{created_by: %Users.User{} = user} = api_key
       ),
       do: accountable_name(run, user, loaded_membership(api_key.created_by_membership))

  defp key_owner_name(_run, %ApiKeys.ApiKey{}), do: nil

  defp requester_membership(%Users.User{memberships: memberships}) when is_list(memberships),
    do: memberships |> List.first() |> loaded_membership()

  defp requester_membership(%Users.User{}), do: :unknown

  defp loaded_membership(%Accounts.Membership{} = membership), do: membership
  defp loaded_membership(nil), do: nil
  defp loaded_membership(_not_loaded), do: :unknown

  # The membership is the account-local naming authority, so it only names
  # anyone once it is provably THIS run's, in THIS account, for THIS person.
  # An absent (or mismatched) membership degrades to the email, which still
  # identifies the accountable human without exposing the cross-account
  # `users.full_name` or a directory name another workspace owns.
  defp accountable_name(_run, _user, :unknown), do: nil

  defp accountable_name(
         %ActionRun{} = run,
         %Users.User{} = user,
         %Accounts.Membership{} = membership
       ) do
    if membership.id == run.initiating_membership_id and
         membership.account_id == run.account_id and membership.user_id == user.id do
      Accounts.member_display_name(membership, user)
    else
      user.email
    end
  end

  defp accountable_name(_run, %Users.User{} = user, nil), do: user.email

  defp run_via(%ActionRun{source: :mcp, api_key: %ApiKeys.ApiKey{name: name}})
       when is_binary(name) and name != "",
       do: name

  defp run_via(%ActionRun{source: :mcp}), do: "LLM agent"
  defp run_via(%ActionRun{source: :runbook}), do: "runbook"
  defp run_via(%ActionRun{}), do: nil

  @doc "The MCP client version snapshotted on a run, if any (e.g. \"1.2.3\"). Pure."
  def client_version(%ActionRun{client_info: %{"version" => version}})
      when is_binary(version) and version != "",
      do: version

  def client_version(%ActionRun{}), do: nil

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

      count_queryable =
        ActionRun.Query.all()
        |> Authorizer.for_subject(subject)

      ActionRun.Query.all()
      |> apply_run_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, Keyword.put(opts, :count_queryable, count_queryable))
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
  key's runs (the MCP `recent_runs` recall path); `count: false` — skip the
  total aggregate when a fixed snippet already has its count elsewhere.
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
      {limit, opts} = Keyword.pop(opts, :limit, 8)
      opts = Keyword.put(opts, :page, limit: limit)

      ActionRun.Query.all()
      |> apply_run_scope(scope, subject)
      |> maybe_by_runner_id(runner_id)
      |> maybe_by_action_id(action_id)
      |> apply_run_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ActionRun.Query, opts)
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
  @attempt_failure_statuses [
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
  The canonical run-outcome split for a list of runs the caller ALREADY holds,
  so a summary rendered beside a collection quantifies exactly the rows on
  screen rather than a time window that disagrees with them.

  Pure and Subject-less by design: it reads no rows, and the list it classifies
  came from an already-authorized read. Returns
  `%{total, success, failed, success_rate}`; `success_rate` is successes over
  attempted RESULTS (success + failure) and is `nil` when none have a result.
  """
  def summarize_runs(runs) when is_list(runs) do
    success = Enum.count(runs, &(&1.status == :success))
    failed = Enum.count(runs, &(&1.status in @attempt_failure_statuses))
    results = success + failed

    %{
      total: length(runs),
      success: success,
      failed: failed,
      success_rate: if(results > 0, do: round(success * 100 / results))
    }
  end

  @doc """
  Internal — monthly report job: run outcome tallies for one account over a
  `[from, to)` window. Subject-less; the job scopes by the explicit, already-
  bounded `account_id`. Returns the `outcome_totals` map
  (`%{total, success, failed, denied, cancelled, dispatched}`) plus
  `:distinct_runners` — how many distinct runners actually received work in
  the window. A policy-denied or still-queued row does not exercise a runner.
  """
  def report_run_stats(account_id, %DateTime{} = from, %DateTime{} = to) do
    window =
      ActionRun.Query.all()
      |> ActionRun.Query.by_account_id(account_id)
      |> ActionRun.Query.inserted_after(from)
      |> ActionRun.Query.inserted_before(to)

    totals = window |> ActionRun.Query.outcome_totals(@attempt_failure_statuses) |> Repo.one()
    distinct_runners = window |> ActionRun.Query.distinct_dispatched_runner_count() |> Repo.one()

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

  @doc """
  The display-safe arguments of one run, for every surface that shows an
  operator what was dispatched.

  Requires `view_runs` and the run's own account. Decodes the exact stored
  bytes — each number keeps its original spelling — then replaces every present
  top-level argument named in the run's `sensitive_arg_names` with
  `"[REDACTED]"`; a declared name the payload doesn't carry is not invented.

  Returns `{:ok, args}`, `{:error, :unauthorized}`, `{:error, :not_found}` for
  a run outside the subject's account, or `{:error, :invalid_action_args}` when
  the stored payload doesn't decode.
  """
  def project_action_args(%ActionRun{} = run, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, run.account_id),
         {:ok, args} <- decode_action_args(run.args_raw) do
      {:ok, redact_sensitive_args(args, run.sensitive_arg_names)}
    end
  end

  @doc """
  The exact shell command line a run will execute, for the approval page —
  where an operator decides against *what runs*, not just which arguments were
  sent.

  Requires `view_runs` and takes a run id so the run is freshly fetched through
  the caller's account scope. `advertised_action` is the runner's catalog row
  for this run; its account, runner, and action id must be the run's own, and its
  pack hash is one half of the proof. The command template and the arg
  declarations both come from the published catalog entry that hash proves
  (`Catalog.PublishedRegistry.resolve_action/4`), never from the advertisement
  itself, so a forged `args_schema` cannot move a default or drop a `sensitive`
  flag out of the line.

  Returns `{:ok, line}` with every sensitive value masked, or
  `{:error, :unauthorized}`, `{:error, :not_found}` for a run outside the
  subject's account, `{:error, :action_mismatch}` when the advertisement is not
  this run's, `{:error, :invalid_action_args}` when the stored payload doesn't
  decode, or `{:error, :no_command_preview}` when nothing provable can be
  rendered — a pack drift, an unknown or script-kind action, or an argument
  reference the template can't resolve.
  """
  def project_action_command(
        run_id,
        %Catalog.RunnerAction{} = advertised_action,
        %Subject{} = subject
      )
      when is_binary(run_id) do
    with {:ok, run} <- fetch_run_by_id(run_id, subject),
         :ok <- ensure_advertisement_matches_run(advertised_action, run),
         {:ok, args} <- decode_action_args(run.args_raw),
         {:ok, action} <-
           Catalog.PublishedRegistry.resolve_action(
             advertised_action.pack_id,
             advertised_action.action_id,
             run.expected_pack_hash,
             advertised_action.pack_hash
           ),
         {:ok, line} <- Catalog.CommandPreview.render(action, args, run.sensitive_arg_names) do
      {:ok, line}
    else
      # The catalog and the renderer both fail closed with a bare `:error`;
      # neither may say more about the pack or the arguments than "no preview".
      :error -> {:error, :no_command_preview}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_advertisement_matches_run(%Catalog.RunnerAction{} = action, %ActionRun{} = run) do
    if action.account_id == run.account_id and action.runner_id == run.runner_id and
         action.action_id == run.action_id,
       do: :ok,
       else: {:error, :action_mismatch}
  end

  # Every parser failure collapses to one reason: malformed or ambiguous stored
  # bytes must never hand a presenter the payload — or the duplicate key — that
  # broke the decode.
  defp decode_action_args(args_raw) do
    case RawJSON.decode_object(args_raw) do
      {:ok, args} -> {:ok, args}
      {:error, _reason} -> {:error, :invalid_action_args}
    end
  end

  defp redact_sensitive_args(args, names) do
    Enum.reduce(names, args, fn name, redacted ->
      if Map.has_key?(redacted, name),
        do: Map.put(redacted, name, "[REDACTED]"),
        else: redacted
    end)
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
      |> ActionRun.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(ActionRun.Query)
    else
      false -> {:error, :not_found}
      other -> other
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

  @doc "Lists only the latest physical attempt for each item in one runbook execution."
  def list_latest_runbook_attempts(execution_id, %Subject{} = subject)
      when is_binary(execution_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      runs =
        ActionRun.Query.all()
        |> ActionRun.Query.by_runbook_execution_id(execution_id)
        |> ActionRun.Query.latest_runbook_attempts()
        |> Authorizer.for_subject(subject)
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

  # Rendering concerns are the caller's: pass `preload:` only for the
  # associations the page actually shows. Unknown atoms raise (caller bug).
  defp apply_run_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :runner, queryable -> ActionRun.Query.with_preloaded_runner(queryable)
      :api_key, queryable -> ActionRun.Query.with_preloaded_api_key(queryable)
      :requested_by, queryable -> ActionRun.Query.with_preloaded_requested_by(queryable)
      :attribution, queryable -> ActionRun.Query.with_attribution(queryable)
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
  Builds one runner-reported `error` envelope from the socket's authenticated
  account and runner identities plus the runner-controlled `:code`, `:message`,
  and `:request_id` diagnostics, which are bounded here before the domain reads
  them.
  """
  def build_runner_error(account_id, runner_id, attrs, context),
    do: RunnerError.new(account_id, runner_id, attrs, context)

  @doc """
  Internal — runner socket: record one runner-reported error envelope and apply
  its dispatch consequence in a single transaction.

  A dispatch refused at the runner's concurrency cap returns to the pending
  queue: the runner checks its active-run count before spawning a handler, so
  the refusal proves the action never started. The account and runner filters
  keep the request correlation inside the authenticated socket's scope, and a
  duplicate cap error is idempotent once the run is pending — a result or a
  terminal transition that won the race stays authoritative.

  The `runner.error` audit row carries the bounded diagnostics and commits with
  the requeue, so an envelope naming an unknown, foreign, or already-settled
  request still leaves its trail.

  Returns `{:ok, :requeued | :already_pending | {:not_dispatchable, status} |
  :request_not_found | :not_applicable}`, or `{:error, reason}` when nothing was
  persisted.
  """
  def handle_runner_error(%RunnerError{} = runner_error) do
    Multi.new()
    |> Multi.run(:run, fn repo, _changes -> apply_runner_error(repo, runner_error) end)
    |> Multi.insert(:audit, fn _changes -> runner_error_audit_event(runner_error) end)
    |> Repo.commit_multi(
      after_commit: fn
        %{run: {:requeued, run}} -> after_run_committed(run)
        %{run: _outcome} -> :ok
      end
    )
    |> case do
      {:ok, %{run: {:requeued, _run}}} -> {:ok, :requeued}
      {:ok, %{run: outcome}} -> {:ok, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_runner_error(
         repo,
         %RunnerError{code: "concurrency_cap_reached", request_id: request_id} = runner_error
       )
       when is_binary(request_id) do
    queryable =
      ActionRun.Query.all()
      |> ActionRun.Query.by_account_id(runner_error.account_id)
      |> ActionRun.Query.by_runner_id(runner_error.runner_id)
      |> ActionRun.Query.by_request_id(request_id)
      |> ActionRun.Query.lock_for_update()

    case repo.fetch(queryable, ActionRun.Query) do
      # The audit fact stands on its own — an envelope we cannot correlate
      # must not abort the row that records it.
      {:error, :not_found} -> {:ok, :request_not_found}
      {:ok, %ActionRun{status: :pending}} -> {:ok, :already_pending}
      {:ok, %ActionRun{status: :sent} = run} -> requeue_cap_refused_run(repo, run)
      {:ok, %ActionRun{} = run} -> {:ok, {:not_dispatchable, run.status}}
    end
  end

  defp apply_runner_error(_repo, %RunnerError{}), do: {:ok, :not_applicable}

  defp requeue_cap_refused_run(repo, %ActionRun{} = run) do
    changeset =
      ActionRun.Changeset.transition(run, :pending, %{
        queued_at: DateTime.utc_now(),
        sent_at: nil,
        runner_connection_generation: nil
      })

    with {:ok, requeued} <- repo.update(changeset), do: {:ok, {:requeued, requeued}}
  end

  defp runner_error_audit_event(%RunnerError{} = runner_error) do
    Audit.Events.runner_error(
      runner_error.account_id,
      runner_error.runner_id,
      %{
        code: runner_error.code,
        message: runner_error.message,
        request_id: runner_error.request_id
      },
      runner_error.context
    )
  end

  # -- Creation ---------------------------------------------------------

  @doc """
  Internal — the dispatch pipeline (`dispatch_run/2`'s allow/deny/approval
  paths) and tests: create a run row in :pending state inside the
  already-authorized dispatch (no web subject). Caller is responsible for
  triggering the transport to deliver `run_action` once the row is
  persisted (see Emisar.Transport).

  Returns `{:ok, run}` or `{:error, changeset}`. An `:attestation` is always
  refused here — signed state is minted only by the preflighted MCP fan-out.

  Tests can also call this directly to seed runs without exercising
  policy + dispatch.
  """
  def create_run(attrs, opts \\ []) do
    request_id = attrs[:request_id] || Crypto.run_request_id()

    attrs =
      attrs
      |> strip_unproven_attestation()
      |> resolve_initiating_membership()
      |> put_action_arguments_raw()

    attrs = Map.put(attrs, :request_id, request_id)
    attrs = Map.put(attrs, :queued_at, DateTime.utc_now())

    result =
      Multi.new()
      |> put_active_account_lock(attrs[:account_id], :active_account)
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
        notify_runbook_settled(run)
        run_on_create(opts[:on_create], changes)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `create_run/2` is reachable by any domain caller, so a `%Attestation{}`
  # arriving here carries no proof that the facts it signed are the facts of
  # this row. Strip the carrier back to a plain envelope and let the changeset
  # refuse it the same way it refuses a raw map — the transaction rolls back, so
  # no run, audit, or approval state is written. The MCP fan-out never comes
  # through here; it inserts its preflighted attrs inside its own transaction.
  defp strip_unproven_attestation(%{attestation: %Attestation{} = attestation} = attrs),
    do: Map.put(attrs, :attestation, Attestation.envelope(attestation))

  defp strip_unproven_attestation(attrs), do: attrs

  defp resolve_initiating_membership(%{initiating_membership_id: id} = attrs)
       when is_binary(id),
       do: attrs

  defp resolve_initiating_membership(%{api_key_id: api_key_id} = attrs)
       when is_binary(api_key_id) do
    case ApiKeys.peek_api_key_by_id(api_key_id) do
      %ApiKeys.ApiKey{created_by_membership_id: membership_id} ->
        Map.put(attrs, :initiating_membership_id, membership_id)

      nil ->
        attrs
    end
  end

  defp resolve_initiating_membership(
         %{account_id: account_id, requested_by_id: requested_by_id} = attrs
       )
       when is_binary(account_id) and is_binary(requested_by_id) do
    case Accounts.peek_sync_membership(account_id, requested_by_id) do
      %Accounts.Membership{id: membership_id} ->
        Map.put(attrs, :initiating_membership_id, membership_id)

      nil ->
        attrs
    end
  end

  defp resolve_initiating_membership(attrs), do: attrs

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
      {:error, :invalid_attestation}      — attrs claimed signed authority
      {:error, :runner_requires_attestation}
      {:error, changeset}

  This path is unsigned: only the MCP fan-out preflights a signed envelope, so
  an `:attestation` here is a claim nobody proved.
  """
  def dispatch_run(attrs, %Subject{account: %{id: account_id}} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.dispatch_run_permission()
           ),
         :ok <- require_subject_membership(subject) do
      attrs
      |> put_dispatcher_context(subject)
      |> put_dispatcher_identity(subject)
      |> dispatch_run_for_account(account_id)
    end
  end

  @doc """
  Internal dispatch seam for an already-account-scoped caller.

  The public subject-aware path establishes attribution and membership scope
  before entering here. Durable schedulers may also supply the initiating
  membership explicitly, so every attempt rechecks current runner access.

  This dispatch is unsigned by definition: it never preflighted a signed
  envelope, so caller attrs carrying an `:attestation` are refused.
  """
  def dispatch_run_for_account(attrs, account_id) when is_binary(account_id) do
    attrs = Map.put(attrs, :account_id, account_id)
    runner_id = attrs[:runner_id]
    action_id = attrs[:action_id]
    reason = attrs[:reason]
    membership_id = Map.get(attrs, :requested_by_membership_id)

    with :ok <- refuse_caller_attestation(attrs),
         :ok <- require_runner(runner_id),
         :ok <- require_action(action_id),
         :ok <- require_reason(reason),
         :ok <- runner_in_account(runner_id, account_id),
         :ok <- runner_online_for_runbook(attrs, runner_id, account_id),
         :ok <- check_attestation(attrs, runner_id, account_id, false),
         :ok <- runner_in_membership_scope(runner_id, account_id, membership_id),
         {:ok, runner_ref} <- public_runner_ref(runner_id),
         {:ok, contract} <-
           fetch_dispatch_contract(account_id, runner_id, action_id, attrs[:pack_ref]),
         action = contract.action,
         :ok <- pack_in_membership_scope(action.pack_id, account_id, membership_id),
         :ok <- ensure_primary_executable_available(action) do
      attrs
      |> persist_initiating_membership()
      |> put_action_arguments(contract)
      |> Map.put(:runner_ref, runner_ref)
      |> Map.put(:expected_pack_hash, contract.pack_hash)
      |> Map.put(:requires_approval, false)
      |> evaluate_and_dispatch(account_id, contract.descriptor)
    end
  end

  @doc """
  Creates or replays one fixed MCP `run_action` operation.

  `facts` is the exact model-facing call: `:operation_id`, `:action_id`,
  `:pack_ref`, the requested `:runner_refs`, `:args` plus the exact
  `:args_raw` bytes, `:reason`, the optional `:evidence`/`:expected`
  justification chain, and the raw `:attestation_headers` with the actual
  request `:portal_origin`. Account, credential, client metadata, membership
  scope, and attribution come from `subject` alone.

  The operation is reserved first. Only the fresh winner resolves current
  runner generations and trusted contracts, validates the arguments and the
  signed envelope, and persists every target atomically; a failed preflight
  rolls the reservation back with it. An exact replay returns the committed
  rows without consulting current catalog state, and nothing is broadcast,
  delivered, or notified until the whole transaction commits.

  Returns `{:ok, :created | :replay, runs}`, `{:error, :operation_conflict}`,
  `{:error, :operation_incomplete}` when the persisted target set does not
  match the request, or the first rejection.
  """
  def dispatch_mcp_action(facts, %Subject{actor: %ApiKeys.ApiKey{}} = subject)
      when is_map(facts) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.dispatch_run_permission()
           ),
         :ok <- require_subject_membership(subject),
         {:ok, facts} <- normalize_mcp_action_facts(facts) do
      commit_mcp_action(facts, mcp_action_operation_attrs(facts), subject, true)
    end
  end

  def dispatch_mcp_action(_facts, %Subject{}), do: {:error, :unauthorized}

  defp normalize_mcp_action_facts(
         %{
           operation_id: operation_id,
           action_id: action_id,
           pack_ref: pack_ref,
           runner_refs: runner_refs,
           args: args,
           args_raw: args_raw,
           reason: reason
         } = facts
       )
       when is_binary(operation_id) and is_binary(action_id) and is_binary(pack_ref) and
              is_list(runner_refs) and is_map(args) and is_binary(args_raw) and
              is_binary(reason) do
    if length(runner_refs) in 1..@max_mcp_fanout and Enum.all?(runner_refs, &is_binary/1) and
         Enum.uniq(runner_refs) == runner_refs do
      {:ok,
       %{
         operation_id: operation_id,
         action_id: action_id,
         pack_ref: pack_ref,
         runner_refs: runner_refs,
         args: args,
         args_raw: args_raw,
         reason: reason,
         evidence: facts[:evidence],
         expected: facts[:expected],
         attestation_headers: Map.get(facts, :attestation_headers, []),
         portal_origin: facts[:portal_origin]
       }}
    else
      {:error, :invalid_targets}
    end
  end

  defp normalize_mcp_action_facts(_facts), do: {:error, :invalid_targets}

  # Evidence, expected, attestation, and origin are deliberately absent: they
  # never make an otherwise-identical retry a different mutation, and replay
  # must answer from persisted children rather than from what this call claims.
  defp mcp_action_operation_attrs(facts) do
    fingerprint =
      MCPOperations.mutation_fingerprint("run_action", %{
        "action_id" => facts.action_id,
        "pack_ref" => facts.pack_ref,
        "args_sha256" => Crypto.hash_hex(facts.args_raw),
        "reason" => facts.reason,
        "runner_refs" => Enum.sort(facts.runner_refs)
      })

    %{
      operation_id: facts.operation_id,
      tool: :run_action,
      fingerprint: fingerprint,
      action_id: facts.action_id,
      pack_ref: facts.pack_ref
    }
  end

  defp commit_mcp_action(facts, operation_attrs, subject, use_grants?) do
    base = put_active_account_lock(Multi.new(), subject.account.id, :active_account)

    with {:ok, multi} <- MCPOperations.reserve_in_multi(base, operation_attrs, subject) do
      result =
        multi
        |> Multi.merge(fn
          %{mcp_operation: %{fresh?: false}} ->
            Multi.new()

          %{mcp_operation: %{operation: operation, fresh?: true}} ->
            compose_fresh_mcp_action(facts, subject, operation.id, use_grants?)
        end)
        |> Repo.commit_multi(after_commit: &after_mcp_action_committed/1)

      case result do
        {:ok, %{mcp_operation: %{operation: operation, fresh?: fresh?}}} ->
          settle_mcp_action(operation, facts, fresh?, subject)

        {:error, :grant_unusable} when use_grants? ->
          # A grant can expire, be revoked, or exhaust its final use between
          # policy planning and the locked consume. The first transaction has
          # rolled back completely, including the operation reservation, so the
          # retry can safely persist the same fan-out as pending approval.
          commit_mcp_action(facts, operation_attrs, subject, false)

        other ->
          other
      end
    end
  end

  defp compose_fresh_mcp_action(facts, subject, operation_record_id, use_grants?) do
    case plan_fresh_mcp_action(facts, subject) do
      {:ok, target_attrs} ->
        compose_mcp_action_runs(
          target_attrs,
          subject.account.id,
          operation_record_id,
          use_grants?
        )

      {:error, reason} ->
        Multi.error(Multi.new(), :mcp_action_preflight, reason)
    end
  end

  defp plan_fresh_mcp_action(facts, subject) do
    with {:ok, targets, action} <- resolve_mcp_action_targets(facts, subject),
         :ok <- validate_mcp_action_args(facts.args, action),
         {:ok, attestation} <- preflight_attestation(facts, targets, subject.account.id) do
      {:ok, Enum.map(targets, &mcp_target_attrs(&1, facts, attestation, subject))}
    end
  end

  # Model-facing input names a pack, an action, and runner refs; only an exact
  # trusted manifest deployed on a current runner generation resolves to a
  # target, so a rotated runner or a changed contract stops the fan-out here.
  defp resolve_mcp_action_targets(facts, subject) do
    case Catalog.resolve_model_action(facts.action_id, facts.pack_ref, facts.runner_refs, subject) do
      {:ok, %{action: action, runners: runners}} ->
        {:ok, Enum.map(runners, &%{id: &1.id, runner_ref: &1.runner_ref}), action}

      {:error, :not_found} ->
        {:error, :target_contract_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_mcp_action_args(args, action) do
    case ActionContract.validate(args, action) do
      :ok -> :ok
      {:error, issue} -> {:error, {:invalid_action_arguments, issue}}
    end
  end

  defp mcp_target_attrs(target, facts, attestation, subject) do
    %{
      action_id: facts.action_id,
      runner_id: target.id,
      args: facts.args,
      args_raw: facts.args_raw,
      reason: facts.reason,
      evidence: facts.evidence,
      expected: facts.expected,
      source: "mcp",
      client_info: mcp_client_info(subject),
      operation_id: facts.operation_id,
      pack_ref: facts.pack_ref
    }
    |> put_dispatcher_context(subject)
    |> put_dispatcher_identity(subject)
    |> put_validated_attestation(attestation)
  end

  defp mcp_client_info(%Subject{actor: %ApiKeys.ApiKey{last_client_info: info}})
       when is_map(info),
       do: info

  defp mcp_client_info(%Subject{}), do: %{}

  defp put_validated_attestation(attrs, nil), do: attrs

  defp put_validated_attestation(attrs, %Attestation{} = attestation),
    do: Map.put(attrs, :attestation, attestation)

  # The envelope is bound to the refs of the runners this account actually
  # scopes — never to refs the caller sent.
  defp preflight_attestation(facts, targets, account_id) do
    with {:ok, runners} <- scoped_target_runners(Enum.map(targets, & &1.id), account_id) do
      resolve_attestation(facts, runners)
    end
  end

  defp resolve_attestation(%{attestation_headers: []}, runners) do
    case Enum.filter(runners, & &1.enforce_signatures) do
      [] -> {:ok, nil}
      enforcing -> {:error, {:signature_required, Enum.map(enforcing, & &1.runner_ref)}}
    end
  end

  # The signed claim covers ONE operation, so it binds the exact argument bytes,
  # reason, and origin of this call plus the scoped refs it fans out to.
  defp resolve_attestation(facts, runners) do
    signed_facts = %{
      action_id: facts.action_id,
      pack_ref: facts.pack_ref,
      args_raw: facts.args_raw,
      runner_refs: Enum.map(runners, & &1.runner_ref),
      reason: facts.reason,
      # Bound by digest in v5, so the verifier needs the plaintext to compare.
      # Read strictly, not with Map.get: a call site that forgets these would
      # otherwise compare against "" and quietly accept a narrative nobody signed.
      evidence: facts.evidence,
      expected: facts.expected,
      operation_id: facts.operation_id,
      portal_origin: facts.portal_origin
    }

    with true <- is_binary(facts.portal_origin),
         {:ok, %Attestation{} = attestation} <-
           Attestation.validate(facts.attestation_headers, signed_facts) do
      {:ok, attestation}
    else
      _ -> {:error, :invalid_attestation}
    end
  end

  defp scoped_target_runners(runner_ids, account_id) do
    runner_ids
    |> Enum.reduce_while({:ok, []}, fn runner_id, {:ok, runners} ->
      case scoped_target_runner(runner_id, account_id) do
        {:ok, runner} -> {:cont, {:ok, [runner | runners]}}
        {:error, :runner_not_found} -> {:halt, {:error, :runner_not_found}}
      end
    end)
    |> case do
      {:ok, runners} -> {:ok, Enum.reverse(runners)}
      {:error, :runner_not_found} -> {:error, :runner_not_found}
    end
  end

  defp scoped_target_runner(runner_id, account_id) do
    with true <- Emisar.Runners.runner_in_account?(runner_id, account_id),
         %Emisar.Runners.Runner{} = runner <- Emisar.Runners.peek_runner_by_id(runner_id),
         {:ok, runner_ref} <- Catalog.MCPProjection.runner_ref(runner) do
      {:ok, %{runner_ref: runner_ref, enforce_signatures: runner.enforce_signatures}}
    else
      _ -> {:error, :runner_not_found}
    end
  end

  # A committed operation whose child rows are missing or partial is never
  # reported as a successful mutation: recovery must reconcile it explicitly.
  defp settle_mcp_action(operation, facts, fresh?, subject) do
    with {:ok, runs} <- list_runs_by_mcp_operation(operation.id, subject),
         :ok <- ensure_complete_mcp_target_set(runs, facts.runner_refs) do
      {:ok, if(fresh?, do: :created, else: :replay), runs}
    end
  end

  defp ensure_complete_mcp_target_set(runs, runner_refs) do
    persisted = Enum.map(runs, & &1.runner_ref)

    if length(persisted) == length(runner_refs) and
         MapSet.new(persisted) == MapSet.new(runner_refs),
       do: :ok,
       else: {:error, :operation_incomplete}
  end

  defp compose_mcp_action_runs(target_attrs, account_id, operation_record_id, use_grants?) do
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
         :ok <- require_subject_membership(subject),
         :ok <- validate_dispatch_batch(target_attrs),
         :ok <- refuse_caller_attestations(target_attrs) do
      target_attrs =
        Enum.map(target_attrs, fn attrs ->
          attrs
          |> put_dispatcher_context(subject)
          |> put_dispatcher_identity(subject)
        end)

      {:ok,
       multi
       |> put_active_account_lock(subject.account.id, {:active_account, namespace})
       |> Multi.merge(fn _changes ->
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

  @doc """
  Internal runbook seam: compose physical attempts into a Runbooks-owned
  transaction using the durable initiating membership instead of fabricating a
  request subject. Current runner scope, policy, pack trust, and the frozen
  action contract are rechecked while the transaction runs.
  """
  def compose_runbook_attempts_in_multi(
        multi,
        target_attrs,
        account_id,
        membership_id,
        namespace,
        opts \\ []
      )

  def compose_runbook_attempts_in_multi(
        %Multi{} = multi,
        target_attrs,
        account_id,
        membership_id,
        namespace,
        opts
      )
      when is_list(target_attrs) and is_binary(account_id) and is_binary(membership_id) do
    use_grants? = Keyword.get(opts, :use_grants?, true)
    execution_id = Keyword.get(opts, :runbook_execution_id)

    with :ok <- validate_runbook_attempt_batch(target_attrs, execution_id),
         :ok <- refuse_caller_attestations(target_attrs) do
      target_attrs =
        Enum.map(target_attrs, fn attrs ->
          attrs
          |> Map.put(:source, "runbook")
          |> Map.put(:requested_by_membership_id, membership_id)
        end)

      {:ok,
       multi
       |> put_active_account_lock(account_id, {:active_account, namespace})
       |> Multi.merge(fn _changes ->
         compose_dispatch_batch(
           target_attrs,
           account_id,
           namespace,
           use_grants?,
           execution_id
         )
       end)}
    end
  end

  def compose_runbook_attempts_in_multi(
        %Multi{},
        _target_attrs,
        _account_id,
        _membership_id,
        _namespace,
        _opts
      ),
      do: {:error, :invalid_targets}

  defp validate_runbook_attempt_batch(target_attrs, execution_id) do
    valid? =
      is_binary(execution_id) and
        length(target_attrs) in 1..@max_mcp_fanout and
        Enum.all?(target_attrs, fn attrs ->
          is_map(attrs) and is_binary(attrs[:runner_id]) and
            is_binary(attrs[:runbook_execution_item_id]) and
            attrs[:runbook_execution_id] == execution_id and
            is_integer(attrs[:attempt_number]) and attrs[:attempt_number] > 0
        end)

    if valid?, do: :ok, else: {:error, :invalid_targets}
  end

  defp validate_dispatch_batch(target_attrs) do
    if length(target_attrs) in 1..@max_mcp_fanout and
         Enum.all?(target_attrs, &(is_map(&1) and is_binary(Map.get(&1, :runner_id)))) do
      :ok
    else
      {:error, :invalid_targets}
    end
  end

  defp compose_dispatch_batch(
         target_attrs,
         account_id,
         namespace,
         use_grants?,
         approved_execution_id \\ nil
       ) do
    target_attrs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, Multi.new()}, fn {attrs, index}, {:ok, multi} ->
      case plan_atomic_run(attrs, account_id, nil, use_grants?, approved_execution_id) do
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

  defp plan_atomic_run(
         attrs,
         account_id,
         operation_record_id,
         use_grants?,
         approved_execution_id \\ nil
       ) do
    attrs = Map.put(attrs, :account_id, account_id)
    runner_id = attrs[:runner_id]
    action_id = attrs[:action_id]
    reason = attrs[:reason]
    membership_id = Map.get(attrs, :requested_by_membership_id)
    # Reserving an operation record is what the signed MCP fan-out — and only it
    # — does, so it doubles as the proof that this plan came through
    # `preflight_attestation/4`.
    signed_fanout? = is_binary(operation_record_id)

    with :ok <- require_runner(runner_id),
         :ok <- require_action(action_id),
         :ok <- require_reason(reason),
         :ok <- runner_in_account(runner_id, account_id),
         :ok <- check_attestation(attrs, runner_id, account_id, signed_fanout?),
         :ok <-
           attestation_fresh(attrs[:attestation], Emisar.Runners.peek_runner_by_id(runner_id)),
         :ok <- runner_in_membership_scope(runner_id, account_id, membership_id),
         {:ok, runner_ref} <- public_runner_ref(runner_id),
         {:ok, contract} <-
           fetch_dispatch_contract(account_id, runner_id, action_id, attrs[:pack_ref]),
         :ok <- ensure_frozen_runbook_contract(attrs, contract),
         :ok <- ensure_runbook_item_identity(attrs, account_id),
         action = contract.action,
         :ok <- pack_in_membership_scope(action.pack_id, account_id, membership_id),
         :ok <- ensure_primary_executable_available(action) do
      attrs =
        attrs
        |> persist_initiating_membership()
        |> put_action_arguments(contract)
        |> Map.put(:runner_ref, runner_ref)
        |> Map.put(:expected_pack_hash, contract.pack_hash)
        |> Map.put(:requires_approval, false)
        |> Map.put(:mcp_operation_record_id, operation_record_id)

      plan_mcp_policy(attrs, account_id, contract.descriptor, use_grants?, approved_execution_id)
    end
  end

  defp plan_mcp_policy(attrs, account_id, descriptor, use_grants?, approved_execution_id) do
    eval_attrs = Map.merge(attrs, %{risk: descriptor["risk"], kind: descriptor["kind"]})
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
        plan_required_approval(
          attrs,
          policy,
          reason,
          matched,
          use_grants?,
          approved_execution_id
        )
    end
  end

  defp plan_required_approval(
         %{runbook_execution_id: execution_id} = attrs,
         policy,
         reason,
         matched,
         _use_grants?,
         execution_id
       )
       when is_binary(execution_id) do
    attrs = Map.merge(attrs, policy_attrs(policy, "require_approval", reason, matched))

    if Emisar.Approvals.runbook_execution_approved?(execution_id, attrs[:account_id]) do
      {:ok,
       %{
         attrs:
           Map.put(
             attrs,
             :policy_reason,
             append_policy_reason(
               reason,
               "An approved runbook execution satisfied that requirement."
             )
           ),
         delivery: :runner
       }}
    else
      {:ok,
       %{
         attrs:
           Map.merge(attrs, %{
             status: :denied,
             policy_reason:
               append_policy_reason(reason, "This runbook execution still needs approval.")
           }),
         delivery: :none
       }}
    end
  end

  defp plan_required_approval(
         attrs,
         policy,
         reason,
         matched,
         use_grants?,
         _execution_id
       ) do
    with {:ok, approval} <- Emisar.Policies.approval_settings_for(policy.rules) do
      {:ok, plan_mcp_approval(attrs, policy, reason, matched, use_grants?, approval)}
    end
  end

  defp plan_mcp_approval(attrs, policy, policy_reason, matched, true, approval) do
    case lookup_grant(attrs) do
      {:matched, grant} ->
        %{
          attrs:
            Map.merge(
              attrs,
              policy_attrs(
                policy,
                "allow",
                append_policy_reason(
                  policy_reason,
                  "A standing grant satisfied that requirement."
                ),
                matched
              )
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

  defp after_mcp_action_committed(%{mcp_operation: %{fresh?: false}}), do: :ok

  defp after_mcp_action_committed(%{mcp_operation: %{fresh?: true}} = changes) do
    after_composed_dispatches_committed(changes)
  end

  @doc "Runs every side effect for dispatch rows after their outer transaction commits."
  def after_composed_dispatches_committed(changes) when is_map(changes) do
    changes
    |> composed_runs_from_changes()
    |> Enum.each(fn {run_key, run} ->
      broadcast_run(run)
      notify_runbook_settled(run)
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

  @doc """
  The subset of account-scoped `run_ids` not yet in a terminal status — the ids
  a settle-wait must keep waiting on. One query for the whole set, so a fan-out
  poll never pays a fetch per run.
  """
  def list_unsettled_run_ids(run_ids, %Subject{} = subject) when is_list(run_ids) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runs_permission()
           ) do
      unsettled =
        ActionRun.Query.all()
        |> ActionRun.Query.by_ids(run_ids)
        |> ActionRun.Query.status_not_in(ActionRun.terminal_statuses())
        |> Authorizer.for_subject(subject)
        |> ActionRun.Query.select_ids()
        |> Repo.all()

      {:ok, unsettled}
    end
  end

  # Snapshot the dispatcher's source ip/ua + self-reported MCP client metadata
  # from the request context onto the run attrs, so every run-lifecycle audit
  # event — including the terminal one logged from the runner socket — attributes
  # the action to where it came from and carries the caller's correlation
  # metadata. A subject-less internal dispatch carries none, which is correct:
  # no request, no dispatcher.
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

  defp require_subject_membership(%Subject{membership_id: membership_id})
       when is_binary(membership_id),
       do: :ok

  defp require_subject_membership(%Subject{}), do: {:error, :runner_out_of_scope}

  defp persist_initiating_membership(attrs) do
    attrs
    |> Map.put(:initiating_membership_id, Map.get(attrs, :requested_by_membership_id))
    |> Map.delete(:requested_by_membership_id)
  end

  @doc """
  Internal read-only runbook approval precheck. Revalidates one frozen target,
  membership scope, trusted exact pack, executable readiness, canonical action
  contract, and the current policy veto without creating a run.
  """
  def recheck_runbook_attempt(attrs, account_id)
      when is_map(attrs) and is_binary(account_id) do
    runner_id = attrs[:runner_id]

    with :ok <- require_runner(runner_id),
         :ok <- require_action(attrs[:action_id]),
         :ok <- runner_in_account(runner_id, account_id),
         :ok <- runner_online(runner_id, account_id),
         false <- Emisar.Runners.runner_enforces_signatures?(runner_id, account_id),
         :ok <-
           runner_in_membership_scope(
             runner_id,
             account_id,
             attrs[:requested_by_membership_id]
           ),
         {:ok, contract} <-
           fetch_dispatch_contract(
             account_id,
             runner_id,
             attrs[:action_id],
             attrs[:pack_ref]
           ),
         :ok <- ensure_frozen_runbook_contract(attrs, contract),
         :ok <-
           pack_in_membership_scope(
             contract.action.pack_id,
             account_id,
             attrs[:requested_by_membership_id]
           ),
         :ok <- ensure_primary_executable_available(contract.action),
         :ok <- current_runbook_policy_allows?(attrs, account_id, contract.descriptor) do
      :ok
    else
      true -> {:error, :runner_requires_attestation}
      {:error, _reason} = error -> error
    end
  end

  def recheck_runbook_attempt(_attrs, _account_id), do: {:error, :invalid_targets}

  defp current_runbook_policy_allows?(attrs, account_id, descriptor) do
    evaluation =
      attrs
      |> Map.merge(%{risk: descriptor["risk"], kind: descriptor["kind"]})
      |> then(
        &Emisar.Policies.evaluate_with_policy(account_id, &1, runner_group(attrs.runner_id))
      )

    case evaluation do
      {:deny, _matched, _reason, _policy} -> {:error, :denied_by_policy}
      {_decision, _matched, _reason, _policy} -> :ok
    end
  end

  @doc """
  Internal — re-validate that an already-created run's action pack is STILL
  trusted for the approval path. Initial dispatch gates pack trust, but
  `Approvals.approve_request` re-dispatches the
  parked run directly; without this re-check a runner that re-advertised
  the pack with a tampered hash during the approval window (flipping the
  pack to `:pending`) would have the operator's approval ship the new,
  untrusted bytes. Fails closed: every resolution failure propagates, so a
  run whose advertised action has since vanished cannot be approved either.
  Returns `:ok` or `{:error, :action_not_found | :pack_untrusted |
  :pack_retired | :action_unavailable}` — the caller refuses the approval on
  error.
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

  # Before insert the value is still the validated struct; after insert it is
  # the normalized envelope the row stores.
  defp attestation_fresh(%Attestation{} = attestation, runner),
    do: attestation_fresh(Attestation.envelope(attestation), runner)

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

  defp approval_attestation_deadline(%{attestation: %Attestation{} = attestation} = attrs) do
    envelope = Attestation.envelope(attestation)

    attrs
    |> Map.put(:attestation, envelope)
    |> approval_attestation_deadline()
  end

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
         [leaf | _rest] when is_binary(leaf) <- attestation["cert_chain"],
         {:ok, cert_deadline} <- certificate_not_after(leaf) do
      freshness_deadline = DateTime.add(issued_at, max_age, :second)

      {:ok, issued_at,
       Enum.min_by([freshness_deadline, cert_deadline], &DateTime.to_unix(&1, :microsecond))}
    else
      _ -> {:error, :attestation_stale}
    end
  end

  # The portal reads ONE fact out of the leaf — when it stops being valid — so an
  # approval is never held past the point where its dispatch could still be
  # accepted. It is not verifying anything: the runner owns trust, the profile,
  # and the scope.
  defp certificate_not_after(encoded_leaf) do
    with {:ok, der} <- Base.decode64(encoded_leaf),
         {:Certificate, tbs, _algorithm, _signature} <- :public_key.pkix_decode_cert(der, :plain),
         # TBSCertificate positions: version, serialNumber, signature, issuer,
         # validity — so the validity is element 5 of the record tuple.
         {:Validity, _not_before, not_after} <- elem(tbs, 5) do
      pkix_time_to_datetime(not_after)
    else
      _ -> :error
    end
  rescue
    # pkix_decode_cert raises on malformed DER. The envelope validator already
    # bounded and base64-checked this value, so a raise here means a structurally
    # invalid certificate, which is the runner's refusal to report, not a crash.
    _ -> :error
  end

  defp pkix_time_to_datetime({:utcTime, time}) do
    # X.509 UTCTime is two-digit years: RFC 5280 reads 50..99 as 19xx and
    # 00..49 as 20xx.
    with <<year::binary-2, rest::binary>> <- to_string(time),
         {value, ""} <- Integer.parse(year) do
      century = if value >= 50, do: "19", else: "20"
      parse_pkix_timestamp(century <> year <> rest)
    else
      _ -> :error
    end
  end

  defp pkix_time_to_datetime({:generalTime, time}), do: parse_pkix_timestamp(to_string(time))
  defp pkix_time_to_datetime(_time), do: :error

  defp parse_pkix_timestamp(
         <<year::binary-4, month::binary-2, day::binary-2, hour::binary-2, minute::binary-2,
           second::binary-2, "Z">>
       ) do
    case DateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z") do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_pkix_timestamp(_time), do: :error

  # Per-user runner ACLs (v1). When the caller supplies a
  # `requested_by_membership_id`, the membership's runner scopes must
  # include this runner. Operator UI AND MCP both supply it — an
  # `emk-`/OAuth key carries its creator's membership
  # (`created_by_membership_id`, set at mint), so revoking a user's scope
  # shrinks every key they minted. Do NOT "simplify" MCP to pass nil here:
  # nil means "no per-user scope" (a genuinely user-less system dispatch) — the
  # runbook scheduler does NOT pass nil; it threads the initiating membership
  # so every later attempt re-runs this check. Routing a scoped key through nil would
  # unscope the key. `runner_in_account/2` runs first in the with chain, so
  # the runner is guaranteed to belong to `account_id` by the time we get
  # here.
  defp runner_in_membership_scope(_runner_id, _account_id, nil), do: :ok

  defp runner_in_membership_scope(runner_id, account_id, membership_id) do
    access = Accounts.runner_access_for_membership(account_id, membership_id)

    case Emisar.Runners.peek_runner_by_id(runner_id) do
      nil ->
        {:error, :runner_not_found}

      runner ->
        if Accounts.RunnerAccess.runner_in_scope?(runner, access),
          do: :ok,
          else: {:error, :runner_out_of_scope}
    end
  end

  # The pack half of the same per-user ACL, checked once the trusted contract has
  # named the action's exact pack. Runner scope is checked earlier in the chain
  # so an out-of-scope runner never learns this account's pack trust state.
  defp pack_in_membership_scope(_pack_id, _account_id, nil), do: :ok

  defp pack_in_membership_scope(pack_id, account_id, membership_id) do
    access = Accounts.runner_access_for_membership(account_id, membership_id)

    if Accounts.RunnerAccess.pack_in_scope?(pack_id, access),
      do: :ok,
      else: {:error, :pack_out_of_scope}
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

  defp runner_online_for_runbook(%{runbook_execution_id: execution_id}, runner_id, account_id)
       when is_binary(execution_id),
       do: runner_online(runner_id, account_id)

  defp runner_online_for_runbook(_attrs, _runner_id, _account_id), do: :ok

  defp runner_online(runner_id, account_id) do
    if Emisar.Runners.online?(account_id, runner_id),
      do: :ok,
      else: {:error, :runner_not_found}
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

  # Nil is a rolling-upgrade advertisement from an older runner. Only a
  # definite false removes an action; this host fact can never make an
  # untrusted or mismatched descriptor executable.
  defp ensure_primary_executable_available(%{primary_executable_available: false}),
    do: {:error, :action_unavailable}

  defp ensure_primary_executable_available(_action), do: :ok

  # `%Attestation{}` is an ordinary Elixir struct, so holding one proves nothing
  # about who built it or what it was bound to. Only `preflight_attestation/4`
  # mints one, and only after validating the raw header against the exact facts
  # of the fan-out it is about to reserve. Every other entry point therefore
  # refuses a caller's `:attestation` outright — map or struct — before a run
  # row, an audit row, or an operation reservation can exist.
  defp refuse_caller_attestation(attrs) do
    if carries_attestation?(attrs), do: {:error, :invalid_attestation}, else: :ok
  end

  defp refuse_caller_attestations(target_attrs) do
    if Enum.any?(target_attrs, &carries_attestation?/1),
      do: {:error, :invalid_attestation},
      else: :ok
  end

  defp carries_attestation?(attrs), do: not is_nil(Map.get(attrs, :attestation))

  # Refuse a portal-originated (operator / runbook / API-key) dispatch to a
  # runner that advertises it enforces client signatures. The runner would
  # reject an unsigned run anyway; blocking here means no run row is created and
  # the caller gets a clear reason.
  #
  # `signed_fanout?` is true only for the MCP fan-out, the one path that
  # validated the envelope against this exact dispatch before reserving its
  # operation. Every other composer plans unsigned, so a carrier in its attrs is
  # a claim of authority nobody proved. The runner remains the cryptographic
  # authority that verifies the Ed25519 signature; this portal flag is the
  # UX/backstop gate.
  defp check_attestation(attrs, runner_id, account_id, signed_fanout?) do
    case Map.get(attrs, :attestation) do
      nil -> refuse_unsigned_dispatch(attrs, runner_id, account_id)
      %Attestation{} when signed_fanout? -> :ok
      _unproven -> {:error, :invalid_attestation}
    end
  end

  defp refuse_unsigned_dispatch(attrs, runner_id, account_id) do
    if Emisar.Runners.runner_enforces_signatures?(runner_id, account_id) do
      Audit.record(
        Audit.Events.dispatch_blocked_requires_attestation(
          account_id,
          runner_id,
          attrs[:action_id]
        )
      )

      {:error, :runner_requires_attestation}
    else
      :ok
    end
  end

  defp fetch_dispatch_contract(account_id, runner_id, action_id, pack_ref) do
    case Catalog.fetch_dispatch_contract(Repo, account_id, runner_id, action_id, pack_ref) do
      {:ok, _contract} = ok ->
        ok

      {:error, :pack_untrusted, pack_info} ->
        audit_dispatch_contract_error(
          account_id,
          runner_id,
          action_id,
          &Audit.Events.dispatch_blocked_pack_untrusted(account_id, pack_info, &1)
        )

        {:error, :pack_untrusted}

      {:error, :pack_retired, pack_version} ->
        audit_dispatch_contract_error(
          account_id,
          runner_id,
          action_id,
          &Audit.Events.dispatch_blocked_pack_retired(account_id, pack_version, &1)
        )

        {:error, :pack_retired}

      other ->
        other
    end
  end

  defp ensure_frozen_runbook_contract(
         %{
           runbook_action_contract: expected_contract,
           runbook_pack_hash: expected_hash
         },
         %{descriptor: descriptor, pack_hash: pack_hash}
       )
       when is_map(expected_contract) and is_binary(expected_hash) do
    current_contract = ActionContract.snapshot(descriptor)

    if current_contract == expected_contract and pack_hash == expected_hash,
      do: :ok,
      else: {:error, :action_contract_changed}
  end

  defp ensure_frozen_runbook_contract(_attrs, _contract), do: :ok

  defp ensure_runbook_item_identity(
         %{
           runbook_execution_id: execution_id,
           runbook_execution_item_id: item_id,
           attempt_number: attempt_number
         } = attrs,
         account_id
       )
       when is_binary(execution_id) and is_binary(item_id) and is_integer(attempt_number) do
    if Emisar.Runbooks.attempt_identity_current?(attrs, account_id),
      do: :ok,
      else: {:error, :invalid_runbook_attempt}
  end

  defp ensure_runbook_item_identity(_attrs, _account_id), do: :ok

  defp audit_dispatch_contract_error(account_id, runner_id, action_id, event_fun) do
    case fetch_advertised_action(runner_id, action_id, account_id) do
      {:ok, action} -> Audit.record(event_fun.(action))
      {:error, :action_not_found} -> :ok
    end
  end

  # The policy sees catalog-authoritative risk + kind so a caller can't
  # spoof "low" to bypass a `:require_approval` on `high`.
  defp evaluate_and_dispatch(attrs, account_id, descriptor) do
    eval_attrs = Map.merge(attrs, %{risk: descriptor["risk"], kind: descriptor["kind"]})
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
    with {:ok, run} <- create_run(attrs),
         :ok <- dispatch_to_runner(run) do
      {:ok, :running, run}
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
          case dispatch_with_grant(attrs, policy, policy_reason, matched, grant) do
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
  defp dispatch_with_grant(attrs, policy, policy_reason, matched, grant) do
    attrs =
      Map.merge(
        attrs,
        policy_attrs(
          policy,
          "allow",
          append_policy_reason(policy_reason, "A standing grant satisfied that requirement."),
          matched
        )
      )

    audit = &Audit.Events.grant_used(&1, grant, policy)
    compose = &Emisar.Approvals.consume_grant_in_multi(&1, :run, grant)

    with {:ok, run} <- create_run(attrs, audit: audit, compose: compose),
         :ok <- dispatch_to_runner(run) do
      {:ok, :running, run}
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
  defp lookup_grant(%{api_key_id: api_key_id, pack_ref: pack_ref} = attrs)
       when is_binary(api_key_id) and is_binary(pack_ref) do
    case Emisar.Approvals.peek_matching_grant(
           attrs[:account_id],
           api_key_id,
           attrs[:action_id],
           attrs[:pack_ref],
           attrs[:runner_id],
           attrs[:args_sha256]
         ) do
      %{} = grant -> {:matched, grant}
      _ -> :none
    end
  end

  defp lookup_grant(_attrs), do: :none

  defp put_action_arguments(attrs, contract) do
    descriptor = contract.descriptor
    attrs = put_action_arguments_raw(attrs)

    sensitive_arg_names =
      descriptor["args_schema"]
      |> Map.get("args", [])
      |> Enum.filter(&(&1["sensitive"] == true))
      |> Enum.map(& &1["name"])
      |> Enum.filter(&is_binary/1)

    attrs
    |> Map.put(:args_sha256, Crypto.hash_hex(attrs[:args_raw]))
    |> Map.put(:sensitive_arg_names, sensitive_arg_names)
    |> Map.put(:structured_output_expected, is_map(descriptor["output_schema"]))
    |> Map.put(:output_schema_snapshot, descriptor["output_schema"])
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
  def list_stale_dispatches(cutoff, limit \\ @sweep_batch)
      when is_struct(cutoff, DateTime) do
    ActionRun.Query.all()
    |> ActionRun.Query.status_in([:pending, :sent])
    |> ActionRun.Query.queued_before(cutoff)
    |> ActionRun.Query.ordered_by_oldest()
    |> ActionRun.Query.limit_to(limit)
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
    # No "reason": CancelMsg is envelope-only, so the runner discards anything
    # else. The two cancel senders had also drifted into sending different
    # things under that key — this one the run's reason_text, the other the
    # cancel's own reason — so it was inconsistent traffic on a frame that
    # freezes at 1.0, mentioned in neither the spec nor the wire golden.
    # Defining a real cancel reason later is an additive change.
    Emisar.Runners.deliver_to_runner(run.account_id, run.runner_id, generation, %{
      "type" => "cancel",
      "request_id" => run.request_id
    })
  end

  defp recover_cancellation(%ActionRun{}, _generation), do: :ok

  @doc """
  Internal — used by `Emisar.Runs.Jobs.DispatchTimeout` to find in-flight
  runs whose runner may have died mid-run. Plain list (real fleets keep few
  runs in flight); the worker decides per-run from the runner's presence and
  disconnect history.
  """
  def list_running_runs(limit \\ @sweep_batch) do
    ActionRun.Query.all()
    |> ActionRun.Query.status_in([:running, :cancelling])
    |> ActionRun.Query.ordered_by_oldest()
    |> ActionRun.Query.limit_to(limit)
    |> Repo.all()
  end

  @doc """
  Internal — every physical attempt minted for one bounded runbook execution,
  in dispatch order. The staged scheduler uses this only for cancellation and
  recovery; result projections use the latest attempt per durable item.
  """
  def list_runs_for_runbook_execution(account_id, execution_id) do
    ActionRun.Query.all()
    |> ActionRun.Query.by_account_id(account_id)
    |> ActionRun.Query.by_runbook_execution_id(execution_id)
    |> ActionRun.Query.ordered_by_oldest()
    |> Repo.all()
  end

  @doc "Internal — bounded terminal attempts whose runbook settlement callback was lost."
  def list_terminal_runbook_callbacks(limit) when is_integer(limit) and limit > 0 do
    ActionRun.Query.terminal_runbook_callbacks(ActionRun.terminal_statuses())
    |> ActionRun.Query.limit_to(limit)
    |> Repo.all()
  end

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

      {:error, :action_unavailable} = error ->
        mark_refused(
          run,
          "the runner reports that this action's primary executable is missing — install it, reload the runner, and dispatch again"
        )

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
      "args" => Jason.Fragment.new(run.args_raw),
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

  # Relay the bridge attestation (signed by the MCP bridge, never the cloud) so
  # an enforcing runner can verify a customer-authorized bridge authorized this
  # run. The portal only carries it through — it neither produces nor checks the
  # signature.
  defp maybe_put_attestation(payload, %ActionRun{attestation: att}) when is_map(att),
    do: Map.put(payload, "attestation", att)

  defp maybe_put_attestation(payload, %ActionRun{}), do: payload

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
    with {:ok, contract} <-
           fetch_dispatch_contract(
             run.account_id,
             run.runner_id,
             run.action_id,
             run.pack_ref
           ),
         :ok <- ensure_primary_executable_available(contract.action),
         true <- contract.pack_hash == run.expected_pack_hash do
      :ok
    else
      # Current trust no longer matches the run's snapshotted hash — a trust
      # decision moved underneath the parked run.
      false ->
        {:error, :pack_untrusted}

      {:error, reason} ->
        {:error, reason}
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
         {:ok, scoped_run} <- fetch_run_by_id(run.id, subject) do
      cancel_run_for_status(scoped_run, subject, reason)
    end
  end

  defp cancel_run_for_status(%ActionRun{} = run, subject, reason) do
    reason = reason || "operator cancelled"

    Multi.new()
    |> put_active_account_lock(run.account_id, :active_account)
    |> request_run_cancellation_in_multi(run.id, reason)
    |> add_cancel_requested_audit(subject, reason)
    |> Emisar.Approvals.cancel_request_for_run_in_multi(run.id)
    |> Repo.commit_multi(
      after_commit: fn changes ->
        deliver_cancel_to_runner(changes.run_cancel)
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

  @doc """
  Internal — atomically cancel every not-yet-dispatched physical attempt for a
  runbook execution. Approval rows lock before their parent runs, matching the
  approval finalizer's lock order, so cancel-vs-approve has one durable winner.
  """
  def cancel_undispatched_runbook_attempts_in_multi(
        %Multi{} = multi,
        execution_id,
        reason
      )
      when is_binary(execution_id) and is_binary(reason) do
    ids_key = {:runbook_undispatched_ids, execution_id}
    requests_key = {:runbook_pending_requests, execution_id}
    runs_key = {:runbook_cancelled_attempts, execution_id}
    cancelled_requests_key = {:runbook_cancelled_requests, execution_id}

    multi
    |> Multi.run(ids_key, fn repo, _changes ->
      ids =
        ActionRun.Query.all()
        |> ActionRun.Query.by_runbook_execution_id(execution_id)
        |> ActionRun.Query.status_in([:pending, :pending_approval])
        |> ActionRun.Query.ordered_by_id()
        |> select_run_ids(repo)

      {:ok, ids}
    end)
    |> Multi.run(requests_key, fn repo, changes ->
      Approvals.lock_pending_requests_for_runs(repo, Map.fetch!(changes, ids_key))
    end)
    |> Multi.run(runs_key, fn repo, changes ->
      cancel_undispatched_runs(repo, Map.fetch!(changes, ids_key), reason)
    end)
    |> Multi.run(cancelled_requests_key, fn repo, changes ->
      Approvals.cancel_locked_requests(repo, Map.fetch!(changes, requests_key), reason)
    end)
  end

  defp select_run_ids(query, repo) do
    query
    |> ActionRun.Query.select_ids()
    |> repo.all()
  end

  defp cancel_undispatched_runs(_repo, [], _reason), do: {:ok, []}

  defp cancel_undispatched_runs(repo, run_ids, reason) do
    runs =
      ActionRun.Query.all()
      |> ActionRun.Query.by_ids(run_ids)
      |> ActionRun.Query.status_in([:pending, :pending_approval])
      |> ActionRun.Query.ordered_by_id()
      |> ActionRun.Query.lock_for_update()
      |> repo.all()

    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, cancelled} ->
      with {:ok, {:cancelled, cancelled_run}} <- cancel_loaded_run(repo, run, reason),
           {:ok, _event} <- repo.insert(Audit.run_event_changeset(cancelled_run)) do
        {:cont, {:ok, [cancelled_run | cancelled]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, cancelled} -> {:ok, Enum.reverse(cancelled)}
      {:error, _reason} = error -> error
    end
  end

  @doc "Post-commit broadcasts for atomic runbook-attempt cancellation."
  def after_undispatched_runbook_attempts_cancelled(changes, execution_id)
      when is_map(changes) and is_binary(execution_id) do
    changes
    |> Map.get({:runbook_cancelled_attempts, execution_id}, [])
    |> Enum.each(&broadcast_and_settle/1)

    changes
    |> Map.get({:runbook_cancelled_requests, execution_id}, [])
    |> Approvals.broadcast_cancelled_requests()

    :ok
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
  defp deliver_cancel_to_runner({outcome, %ActionRun{} = run})
       when outcome in [:cancelling, :retry] do
    with {:ok, generation} <-
           Emisar.Runners.current_connection_generation(run.account_id, run.runner_id) do
      # See recover_cancellation/2: the runner reads only the envelope.
      Emisar.Runners.deliver_to_runner(run.account_id, run.runner_id, generation, %{
        "type" => "cancel",
        "request_id" => run.request_id
      })
    end
  end

  defp deliver_cancel_to_runner(_outcome), do: :ok

  defp broadcast_cancellation({outcome, %ActionRun{} = run})
       when outcome in [:cancelled, :cancelling],
       do: broadcast_and_settle(run)

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

  @max_structured_output_bytes 8_192
  @max_structured_output_depth 16
  @max_structured_output_nodes 1_024

  defp mark_finished(%ActionRun{} = run, result_payload, connection) do
    {status, structured_output, output_error} = result_outcome(run, result_payload)

    case transition_from(
           run,
           :any_nonterminal,
           status,
           result_attrs(run, result_payload, structured_output, output_error),
           connection
         ) do
      {:ok, _finished} = ok ->
        ok

      other ->
        other
    end
  end

  defp result_attrs(%ActionRun{} = run, payload, structured_output, output_error) do
    current = peek_run_by_id(run.id) || run

    %{
      finished_at: DateTime.utc_now(),
      cancelled_at: cancelled_at(payload),
      exit_code: payload["exit_code"],
      duration_ms: payload["duration_ms"],
      timed_out: payload["timed_out"] || false,
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
      structured_output: structured_output,
      # The failure cause belongs in error_message (not reason_text, which holds
      # the operator's freeform reason). The runner sends a terse `reason` code
      # (e.g. "bad_signature", "stale") AND a human `error` sentence ("refused:
      # signature does not match…") on a refusal; prefer the sentence so the
      # operator can act, falling back to the code when there's no `error`
      # (omitempty drops it on an ordinary failure, so this stays the reason).
      error_message: output_error || payload["error"] || payload["reason"]
    }
  end

  defp result_outcome(%ActionRun{} = run, payload) do
    status = Map.get(@result_statuses, payload["status"], :failed)
    output_present? = Map.has_key?(payload, "structured_output")

    cond do
      status != :success ->
        {status, nil, nil}

      run.structured_output_expected and not output_present? ->
        {:validation_failed, nil, "runner omitted required structured output"}

      not run.structured_output_expected and output_present? ->
        {:validation_failed, nil, "runner sent structured output for an untyped action"}

      not output_present? ->
        {status, nil, nil}

      true ->
        with {:ok, schema} <- output_contract_schema(run),
             {:ok, output} <- check_structured_output(payload["structured_output"], schema) do
          {status, output, nil}
        else
          {:error, :invalid_structured_output} ->
            {:validation_failed, nil, "runner sent an invalid structured output value"}

          {:error, :schema_mismatch} ->
            {:validation_failed, nil,
             "runner structured output does not match the trusted schema"}

          {:error, :invalid_contract} ->
            {:validation_failed, nil, "trusted output schema snapshot is unavailable"}
        end
    end
  end

  defp output_contract_schema(%ActionRun{} = run) do
    if Emisar.OutputSchema.valid?(run.output_schema_snapshot),
      do: {:ok, run.output_schema_snapshot},
      else: {:error, :invalid_contract}
  end

  # The runner-sent value is hostile until it passes the run's snapshotted
  # contract plus the same structural and byte ceilings the runner enforces —
  # a compromised runner must not grow rows or bypass typing.
  defp check_structured_output(%{} = output, schema) do
    with :ok <-
           Emisar.JSONValue.validate(output,
             max_depth: @max_structured_output_depth,
             max_nodes: @max_structured_output_nodes
           ),
         {:ok, encoded} <- Jason.encode(output),
         true <- byte_size(encoded) <= @max_structured_output_bytes,
         :ok <- Emisar.OutputSchema.validate_instance(schema, output) do
      {:ok, output}
    else
      {:error, :schema_mismatch} = error -> error
      _other -> {:error, :invalid_structured_output}
    end
  end

  defp check_structured_output(_output, _schema), do: {:error, :invalid_structured_output}

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
            with :ok <- authorize_dispatch_transition(repo, loaded_run, expected_status, status) do
              repo.update(ActionRun.Changeset.transition(loaded_run, status, attrs))
            end
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

  defp authorize_dispatch_transition(repo, run, :pending, :sent) do
    with {:ok, _account} <- Accounts.fetch_and_lock_account(run.account_id, repo: repo) do
      ensure_run_initiator_authorized(repo, run)
    end
  end

  defp authorize_dispatch_transition(_repo, _run, _expected_status, _status), do: :ok

  defp put_active_account_lock(multi, account_id, key) do
    if Repo.valid_uuid?(account_id) do
      Multi.run(multi, key, fn repo, _changes ->
        Accounts.fetch_and_lock_account(account_id, repo: repo)
      end)
    else
      multi
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
    notify_runbook_settled(run)

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

  @doc "Internal - approval release revalidates the exact initiating membership and credential."
  def ensure_run_initiator_authorized(repo, %ActionRun{} = run) do
    with {:ok, membership} <-
           Accounts.fetch_and_lock_active_membership(
             repo,
             run.account_id,
             run.initiating_membership_id
           ),
         {:ok, runner} <-
           Emisar.Runners.fetch_and_lock_active_runner(
             run.runner_id,
             run.account_id,
             repo: repo
           ),
         access = Accounts.runner_access_for_locked_membership(repo, membership),
         true <- Accounts.RunnerAccess.runner_in_scope?(runner, access),
         true <- run_pack_in_scope?(run, access),
         true <- initiating_api_key_usable?(repo, run) do
      :ok
    else
      _ -> {:error, :initiator_no_longer_authorized}
    end
  end

  # The run row carries no pack id, so the action's pack is re-resolved — but
  # only for a grant that actually restricts packs, so an unrestricted release
  # never depends on the action still being advertised.
  defp run_pack_in_scope?(%ActionRun{}, %Accounts.RunnerAccess{pack_mode: :all}), do: true

  defp run_pack_in_scope?(%ActionRun{} = run, %Accounts.RunnerAccess{} = access) do
    case Catalog.fetch_action_for_account(run.action_id, run.runner_id, run.account_id) do
      {:ok, action} -> Accounts.RunnerAccess.pack_in_scope?(action.pack_id, access)
      {:error, :not_found} -> false
    end
  end

  defp initiating_api_key_usable?(_repo, %ActionRun{api_key_id: nil}), do: true

  defp initiating_api_key_usable?(
         repo,
         %ActionRun{api_key_id: api_key_id, account_id: account_id}
       ),
       do: ApiKeys.api_key_usable_in_account?(repo, api_key_id, account_id)

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
  The most recent `limit` progress chunks for an already-fetched run, in
  chronological (`seq`-ASC) order — a tail preview of a finished run's output.
  The subject's permission gate and row scope are re-checked against the run's
  id (a held struct cannot widen visibility), without re-fetching the wide run
  row the caller already holds. Returns `{:ok, [event]}`.
  """
  def list_recent_events_for_run(%ActionRun{} = run, limit, %Subject{} = subject)
      when is_integer(limit) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runs_permission()),
         :ok <- ensure_all_runs_visible([run.id], subject) do
      events =
        RunEvent.Query.all()
        |> RunEvent.Query.by_run_id(run.id)
        |> RunEvent.Query.by_kind(:progress)
        |> RunEvent.Query.recent_by_seq(limit)
        |> Repo.all()
        |> Enum.reverse()

      {:ok, events}
    end
  end

  @doc """
  Returns a bounded output tail for each visible run id. The entire id set must
  be visible to the subject; a mixed visible/hidden request fails closed.
  """
  def list_recent_events_for_runs(run_ids, limit, %Subject{} = subject)
      when is_list(run_ids) and length(run_ids) <= 256 and is_integer(limit) and limit >= 1 and
             limit <= 64 do
    run_ids = Enum.uniq(run_ids)

    with :ok <- validate_run_ids(run_ids),
         :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runs_permission()),
         :ok <- ensure_all_runs_visible(run_ids, subject) do
      events =
        run_ids
        |> RunEvent.Query.recent_progress_for_runs(limit)
        |> Repo.all()
        |> Enum.group_by(& &1.run_id)

      {:ok, events}
    end
  end

  defp validate_run_ids(run_ids) do
    if Enum.all?(run_ids, &Repo.valid_uuid?/1), do: :ok, else: {:error, :not_found}
  end

  defp ensure_all_runs_visible([], %Subject{}), do: :ok

  defp ensure_all_runs_visible(run_ids, %Subject{} = subject) do
    visible_ids =
      ActionRun.Query.all()
      |> ActionRun.Query.by_ids(run_ids)
      |> Authorizer.for_subject(subject)
      |> ActionRun.Query.select_ids()
      |> Repo.all()

    if MapSet.new(visible_ids) == MapSet.new(run_ids), do: :ok, else: {:error, :not_found}
  end

  @doc """
  A forward page of a run's progress chunks — events with `seq` at or after
  `from_seq`, in chronological (`seq`-ASC) order, accumulated until their raw
  chunk bytes reach `byte_budget` (or a per-frame event cap). Drives the MCP
  output tail. The run is fetched via `fetch_run_by_id/3` first so the subject's
  account scope and permission gate apply BEFORE any row is streamed; the stream
  is consumed inside a transaction and never crosses this boundary, so the tail
  never materializes a run's whole (up to 64 MiB) output at once. Returns
  `{:ok, [event], more?}`, where `more?` is true when the page was cut short
  rather than the run's output exhausted.
  """
  def list_events_for_run_since(run_id, from_seq, byte_budget, %Subject{} = subject)
      when is_integer(from_seq) and is_integer(byte_budget) do
    with {:ok, _run} <- fetch_run_by_id(run_id, subject) do
      queryable =
        RunEvent.Query.all()
        |> RunEvent.Query.by_run_id(run_id)
        |> RunEvent.Query.by_kind(:progress)
        |> RunEvent.Query.by_seq_from(from_seq)
        |> RunEvent.Query.ordered_by_seq()

      {:ok, {events, more?}} =
        Repo.transaction(fn -> collect_tail_events(queryable, byte_budget) end)

      {:ok, events, more?}
    end
  end

  defp collect_tail_events(queryable, byte_budget) do
    # 64 rows/batch bounds the stream's in-flight buffer; the 2_000-event cap
    # keeps a frame of tiny chunks from becoming thousands of DB round-trips. The
    # first event always ships so the cursor advances even past a huge chunk.
    queryable
    |> Repo.stream(max_rows: 64)
    |> Enum.reduce_while({[], 0, 0, false}, fn event, {acc, bytes, count, _more} ->
      next_bytes = bytes + byte_size(progress_chunk(event))
      next_count = count + 1

      cond do
        acc == [] -> {:cont, {[event], next_bytes, next_count, false}}
        next_bytes > byte_budget or next_count > 2_000 -> {:halt, {acc, bytes, count, true}}
        true -> {:cont, {[event | acc], next_bytes, next_count, false}}
      end
    end)
    |> then(fn {acc, _bytes, _count, more?} -> {Enum.reverse(acc), more?} end)
  end

  defp progress_chunk(%RunEvent{payload: %{"chunk" => chunk}}) when is_binary(chunk), do: chunk
  defp progress_chunk(_event), do: ""

  @doc """
  The number of progress chunks currently persisted for a run. Backs the MCP
  terminal-output drain: the count is captured when a drain is seeded (a
  terminal run cannot gain events), so the drain can prove at its end that
  every persisted event was delivered — or flag that retention pruned some.
  The run is fetched via `fetch_run_by_id/3` first so the subject's account
  scope and permission gate apply. Returns `{:ok, count}`.
  """
  def count_progress_events_for_run(run_id, %Subject{} = subject) do
    with {:ok, _run} <- fetch_run_by_id(run_id, subject) do
      count =
        RunEvent.Query.all()
        |> RunEvent.Query.by_run_id(run_id)
        |> RunEvent.Query.by_kind(:progress)
        |> Repo.aggregate(:count)

      {:ok, count}
    end
  end

  @doc """
  Internal bounded materialization for runbook extractors. Reads only the
  requested persisted, redacted sources and fails closed when a relevant text
  stream is incomplete, truncated, invalid UTF-8, or exceeds `byte_budget`.
  """
  def materialize_runbook_output(run_id, account_id, sources, byte_budget)
      when is_binary(run_id) and is_binary(account_id) and is_list(sources) and
             is_integer(byte_budget) and byte_budget in 1..65_536 do
    requested = MapSet.new(sources)
    run = fetch_runbook_output_run(run_id, account_id)

    with true <-
           MapSet.subset?(
             requested,
             MapSet.new(["structured_output", "stdout", "stderr"])
           ),
         %ActionRun{} = run <- run,
         true <- ActionRun.terminal?(run.status),
         {:ok, stdout} <- materialize_requested_stream(run, requested, "stdout", byte_budget),
         {:ok, stderr} <- materialize_requested_stream(run, requested, "stderr", byte_budget) do
      {:ok,
       %{
         "structured_output" => run.structured_output,
         "stdout" => stdout,
         "stderr" => stderr
       }}
    else
      false -> {:error, :invalid_output_request}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def materialize_runbook_output(_run_id, _account_id, _sources, _byte_budget),
    do: {:error, :invalid_output_request}

  defp fetch_runbook_output_run(run_id, account_id) do
    ActionRun.Query.all()
    |> ActionRun.Query.by_id(run_id)
    |> ActionRun.Query.by_account_id(account_id)
    |> Repo.one()
  end

  defp materialize_requested_stream(run, requested, stream, byte_budget) do
    if MapSet.member?(requested, stream) do
      with true <- run.output_complete,
           false <- stream_truncated?(run, stream) do
        materialize_progress_stream(run, stream, byte_budget)
      else
        _incomplete_or_truncated -> {:error, :output_incomplete}
      end
    else
      {:ok, nil}
    end
  end

  defp stream_truncated?(run, "stdout"), do: run.stdout_truncated
  defp stream_truncated?(run, "stderr"), do: run.stderr_truncated

  defp materialize_progress_stream(run, stream, byte_budget) do
    queryable =
      RunEvent.Query.all()
      |> RunEvent.Query.by_run_id(run.id)
      |> RunEvent.Query.by_kind(:progress)
      |> RunEvent.Query.by_stream(stream)
      |> RunEvent.Query.ordered_by_seq()

    {:ok, result} =
      Repo.transaction(fn ->
        queryable
        |> Repo.stream(max_rows: 64)
        |> Enum.reduce_while({[], 0}, fn event, {chunks, bytes} ->
          chunk = progress_chunk(event)
          next_bytes = bytes + byte_size(chunk)

          cond do
            not String.valid?(chunk) -> {:halt, {:error, :output_invalid}}
            next_bytes > byte_budget -> {:halt, {:error, :output_too_large}}
            true -> {:cont, {[chunk | chunks], next_bytes}}
          end
        end)
        |> case do
          {:error, reason} -> {:error, reason}
          {chunks, _bytes} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
        end
      end)

    result
  end

  @doc """
  The most recent `limit` progress chunks before `before_seq`, in chronological
  (`seq`-ASC) order — the next older page for the run-detail output viewer's
  "load earlier" control. The run is fetched via `fetch_run_by_id/3` first so the
  subject's account scope and permission gate apply. Returns `{:ok, [event]}`.
  """
  def list_events_for_run_before(run_id, before_seq, limit, %Subject{} = subject)
      when is_integer(before_seq) and is_integer(limit) do
    with {:ok, _run} <- fetch_run_by_id(run_id, subject) do
      events =
        RunEvent.Query.all()
        |> RunEvent.Query.by_run_id(run_id)
        |> RunEvent.Query.by_kind(:progress)
        |> RunEvent.Query.by_seq_before(before_seq)
        |> RunEvent.Query.recent_by_seq(limit)
        |> Repo.all()
        |> Enum.reverse()

      {:ok, events}
    end
  end

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account's run create/transition feed (`{:run_updated, run_id}`)."
  def subscribe_account_runs(account_id),
    do: Emisar.PubSub.subscribe(account_runs_topic(account_id))

  @doc """
  Subscribe to one run's live updates — `{:run_updated, run}` transitions
  plus `{:run_event, event}` progress chunks. Callers must derive both ids from
  a run already authorized for their subject.
  """
  def subscribe_run(account_id, run_id),
    do: Emisar.PubSub.subscribe(run_topic(account_id, run_id))

  def unsubscribe_run(account_id, run_id),
    do: Emisar.PubSub.unsubscribe(run_topic(account_id, run_id))

  defp account_runs_topic(account_id), do: "account:#{account_id}:runs"
  defp run_topic(account_id, run_id), do: "account:#{account_id}:run:#{run_id}"

  # Exact subscribers need `runner.name` to render — make `runner` preloaded
  # part of the payload contract so an update arriving after mount can cleanly
  # replace a run without re-introducing `%NotLoaded{}`.
  @doc """
  Internal — broadcast a run cancelled via `cancel_run_in_multi/3`, from the
  caller's `commit_multi(after_commit:)`. No-op for the already-terminal /
  no-run shapes (nothing changed, so there's nothing to announce).
  """
  def broadcast_cancelled_run({:cancelled, %ActionRun{} = run}), do: broadcast_and_settle(run)
  def broadcast_cancelled_run(_), do: :ok

  defp broadcast_and_settle(%ActionRun{} = run) do
    broadcast_run(run)
    notify_runbook_settled(run)
  end

  defp notify_runbook_settled(
         %ActionRun{
           runbook_execution_item_id: item_id,
           status: status
         } = run
       )
       when is_binary(item_id) do
    if ActionRun.terminal?(status), do: Emisar.Runbooks.action_run_settled(run), else: :ok
  end

  defp notify_runbook_settled(%ActionRun{}), do: :ok

  defp broadcast_run(%ActionRun{} = run) do
    run =
      case run.runner do
        %Ecto.Association.NotLoaded{} -> Repo.preload(run, :runner)
        _ -> run
      end

    Emisar.PubSub.broadcast(run_topic(run.account_id, run.id), {:run_updated, run})
    Emisar.PubSub.broadcast(account_runs_topic(run.account_id), {:run_updated, run.id})
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

  @doc "Whether a current membership role may dispatch action runs."
  def role_can_dispatch_run?(role) when is_atom(role) do
    Authorizer.dispatch_run_permission() in Authorizer.list_permissions_for_role(role)
  end

  def role_can_dispatch_run?(_role), do: false

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

  defp append_policy_reason(reason, sentence), do: reason <> " " <> sentence
end
