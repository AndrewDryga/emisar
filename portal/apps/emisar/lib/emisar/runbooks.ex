defmodule Emisar.Runbooks do
  @moduledoc """
  Cloud-side runbooks: CRUD + expansion to action runs. A runbook is
  a workflow definition; expanding it produces an ordered sequence of
  `run_action` dispatches, one per step.

  v0.1 expansion is straight-line sequential — branching, conditional
  steps, and inline assertions are on the roadmap.
  """
  alias Ecto.Multi
  alias Emisar.{Audit, Auth, MCPOperations, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runbooks.{Authorizer, Runbook, RunbookExecution, StepSelector}

  # -- Reads -----------------------------------------------------------

  def list_runbooks(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.ordered_by_title_version()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Runbook.Query, opts)
    end
  end

  @doc "Lists every runbook visible to the subject for bounded in-memory MCP projection."
  def list_all_runbooks(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      runbooks =
        Runbook.Query.not_deleted()
        |> Runbook.Query.ordered_by_title_version()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, runbooks}
    end
  end

  def fetch_runbook_by_id(id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         true <- Repo.valid_uuid?(id) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Resolves the latest PUBLISHED runbook a caller may execute, by slug first
  (newest version of that slug) then, failing that, by a runbook row id.
  Requires `view_runbooks`; scoped to the subject's account. Returns
  `{:ok, runbook}` or `{:error, :not_found | :unauthorized}`. Drafts and
  cross-account rows read as `:not_found` — this is the resolver behind the
  MCP `execute_runbook` tool, which then dispatches through `dispatch_runbook/4`.
  """
  def fetch_published_runbook(slug_or_id, %Subject{} = subject) when is_binary(slug_or_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      case fetch_latest_published_by_slug(slug_or_id, subject) do
        {:error, :not_found} -> fetch_published_by_id(slug_or_id, subject)
        result -> result
      end
    end
  end

  @doc "Fetches one exact immutable published runbook version by slug and version."
  def fetch_published_runbook_version(slug, version, %Subject{} = subject)
      when is_binary(slug) and is_integer(version) and version > 0 do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.published()
      |> Runbook.Query.by_slug(slug)
      |> Runbook.Query.by_version(version)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    end
  end

  @doc "Fetches one MCP-created draft through the caller's credential lineage."
  def fetch_mcp_draft_by_operation(operation_id, %Subject{} = subject)
      when is_binary(operation_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         {:ok, %{tool: :create_runbook_draft, resource_id: draft_id}} <-
           MCPOperations.fetch_recovery(operation_id, subject) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(draft_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    else
      {:ok, _other_operation} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Fetches one MCP runbook execution through the caller's credential lineage."
  def fetch_execution_by_operation(operation_id, %Subject{} = subject)
      when is_binary(operation_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         {:ok, %{tool: :execute_runbook, resource_id: execution_id}} <-
           MCPOperations.fetch_recovery(operation_id, subject) do
      RunbookExecution.Query.by_account_id(subject.account.id)
      |> RunbookExecution.Query.by_id(execution_id)
      |> Repo.fetch(RunbookExecution.Query)
    else
      {:ok, _other_operation} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Fetches one runbook execution visible to the subject."
  def fetch_execution_by_id(execution_id, %Subject{} = subject) when is_binary(execution_id) do
    query =
      RunbookExecution.Query.by_account_id(subject.account.id)
      |> RunbookExecution.Query.by_id(execution_id)

    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         true <- Repo.valid_uuid?(execution_id),
         {:ok, execution} <- Repo.fetch(query, RunbookExecution.Query),
         :ok <- ensure_execution_scope(execution, subject) do
      {:ok, execution}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp ensure_execution_scope(
         %RunbookExecution{} = execution,
         %Subject{membership_id: membership_id} = subject
       )
       when is_binary(membership_id) do
    runner_ids = execution.work_list |> Enum.map(& &1["runner_id"]) |> MapSet.new()

    with {:ok, runners} <- Emisar.Runners.list_all_runners_for_account(subject) do
      scopes = Emisar.Runners.runner_scopes_for_membership(membership_id)

      visible_ids =
        runners
        |> Enum.filter(&Emisar.Runners.runner_in_scope?(&1, scopes))
        |> MapSet.new(& &1.id)

      if MapSet.subset?(runner_ids, visible_ids), do: :ok, else: {:error, :not_found}
    end
  end

  defp ensure_execution_scope(%RunbookExecution{}, %Subject{}), do: {:error, :not_found}

  @doc "Fetches the immutable runbook row retained by an execution, including soft-deleted families."
  def fetch_runbook_for_execution(%RunbookExecution{} = execution, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         :ok <- Subject.ensure_in_account(subject, execution.account_id) do
      Runbook.Query.all()
      |> Runbook.Query.by_id(execution.runbook_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    end
  end

  defp fetch_latest_published_by_slug(slug, %Subject{} = subject) do
    Runbook.Query.not_deleted()
    |> Runbook.Query.published()
    |> Runbook.Query.by_slug(slug)
    |> Runbook.Query.latest_version()
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(Runbook.Query)
  end

  defp fetch_published_by_id(id, %Subject{} = subject) do
    if Repo.valid_uuid?(id) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.published()
      |> Runbook.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Changeset for the runbook editor's metadata form (title/slug/description).
  Drives `phx-change` validation + inline field errors in the LiveView; the
  row itself is persisted by `create_runbook/2` / `save_new_version/3`, which
  also validate the structured `definition`.
  """
  def change_runbook(attrs \\ %{}), do: Runbook.Changeset.form(attrs)

  # -- Mutations -------------------------------------------------------

  def create_runbook(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             {:one_of,
              [Authorizer.manage_runbooks_permission(), Authorizer.draft_runbooks_permission()]}
           ) do
      user_id = Subject.user_id(subject)

      Multi.new()
      |> Multi.insert(
        :runbook,
        Runbook.Changeset.create(account.id, user_id, attrs)
      )
      |> Multi.insert(:audit, fn %{runbook: runbook} ->
        Audit.Events.runbook_created(subject, runbook)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_runbook_created(&1.runbook))
      |> case do
        {:ok, %{runbook: runbook}} -> {:ok, runbook}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Creates or replays one MCP draft under its bridge operation identity."
  def create_mcp_draft(attrs, operation_id, fingerprint, %Subject{account: account} = subject)
      when is_binary(operation_id) and is_binary(fingerprint) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             {:one_of,
              [Authorizer.manage_runbooks_permission(), Authorizer.draft_runbooks_permission()]}
           ) do
      id = MCPOperations.resource_id(operation_id, :create_runbook_draft, subject)
      attrs = Map.put(attrs, "id", id)

      operation_attrs = %{
        operation_id: operation_id,
        tool: :create_runbook_draft,
        fingerprint: fingerprint,
        resource_id: id,
        resource_ref: attrs["slug"]
      }

      with {:ok, multi} <-
             MCPOperations.reserve_in_multi(Multi.new(), operation_attrs, subject) do
        multi =
          Multi.merge(multi, fn
            %{mcp_operation: %{fresh?: false}} ->
              Multi.new()

            %{mcp_operation: %{fresh?: true}} ->
              Multi.new()
              |> Multi.insert(
                :runbook,
                Runbook.Changeset.create(account.id, Subject.user_id(subject), attrs)
              )
              |> Multi.insert(:audit, fn %{runbook: runbook} ->
                Audit.Events.runbook_created(subject, runbook)
              end)
          end)

        with {:ok, %{mcp_operation: reservation}} <-
               Repo.commit_multi(multi, after_commit: &after_mcp_draft_committed/1),
             {:ok, runbook} <- fetch_runbook_by_id(id, subject) do
          kind = if reservation.fresh?, do: :created, else: :replay
          {:ok, kind, runbook}
        end
      end
    end
  end

  defp after_mcp_draft_committed(%{mcp_operation: %{fresh?: true}, runbook: runbook}) do
    broadcast_runbook_created(runbook)
  end

  defp after_mcp_draft_committed(%{mcp_operation: %{fresh?: false}}), do: :ok

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account's runbook list changes (`{:list_changed, :runbook, …}`)."
  def subscribe_account_runbooks(account_id),
    do: Emisar.PubSub.subscribe(account_runbooks_topic(account_id))

  defp account_runbooks_topic(account_id), do: "account:#{account_id}:runbooks"

  defp broadcast_runbook_created(%Runbook{} = runbook) do
    Emisar.PubSub.broadcast(
      account_runbooks_topic(runbook.account_id),
      {:list_changed, :runbook, "runbook.created", runbook.id}
    )
  end

  defp broadcast_runbook_updated(%Runbook{} = runbook) do
    Emisar.PubSub.broadcast(
      account_runbooks_topic(runbook.account_id),
      {:list_changed, :runbook, "runbook.updated", runbook.id}
    )
  end

  defp broadcast_runbook_published(%Runbook{} = runbook) do
    Emisar.PubSub.broadcast(
      account_runbooks_topic(runbook.account_id),
      {:list_changed, :runbook, "runbook.published", runbook.id}
    )
  end

  defp broadcast_runbook_deleted(%Runbook{} = runbook) do
    Emisar.PubSub.broadcast(
      account_runbooks_topic(runbook.account_id),
      {:list_changed, :runbook, "runbook.deleted", runbook.id}
    )
  end

  def save_new_version(%Runbook{} = old, attrs, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, old.account_id) do
      user_id = Subject.user_id(subject)

      Multi.new()
      |> Multi.insert(:runbook, Runbook.Changeset.new_version(old, user_id, attrs))
      |> Multi.insert(:audit, fn %{runbook: runbook} ->
        Audit.Events.runbook_updated(subject, old, runbook)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_runbook_updated(&1.runbook))
      |> case do
        {:ok, %{runbook: runbook}} -> {:ok, runbook}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def publish(%Runbook{} = runbook, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(runbook.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runbook.Query,
        with: &Runbook.Changeset.update(&1, %{status: :published}),
        audit: &Audit.Events.runbook_published(subject, &1),
        after_commit: &broadcast_runbook_published/1
      )
    end
  end

  @doc """
  Soft-deletes a runbook and ALL its versions (they share a slug within the
  account). Requires `manage_runbooks` and that the subject owns the runbook's
  account. Returns `{:ok, runbook}` or `{:error, :unauthorized | :not_found}`.
  """
  def delete_runbook(%Runbook{} = runbook, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id) do
      # Tombstone the whole family — a per-row delete would strand older
      # versions (each version is its own not-deleted row) in the list.
      queryable =
        Runbook.Query.not_deleted()
        |> Runbook.Query.by_account_id(runbook.account_id)
        |> Runbook.Query.by_slug(runbook.slug)
        |> Authorizer.for_subject(subject)

      Multi.new()
      |> Multi.update_all(:runbooks, queryable, set: [deleted_at: DateTime.utc_now()])
      |> Multi.insert(:audit, Audit.Events.runbook_deleted(subject, runbook))
      |> Repo.commit_multi(after_commit: fn _ -> broadcast_runbook_deleted(runbook) end)
      |> case do
        {:ok, _} -> {:ok, runbook}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Expansion + dispatch (internal — called by Runs / executor) ----

  # Runbook steps have no conditions yet, so they're independent and can
  # run concurrently — but unbounded fan-out (steps × group members)
  # would flood runners, so the engine releases waves of this many runs
  # and waits for the wave to finish before the next.
  @batch_size 5
  @max_fan_out 1_000

  @doc """
  Expand a runbook into the ordered list of step descriptors that the
  cloud's executor will dispatch.
  """
  def expand(%Runbook{definition: %{"steps" => steps}}) when is_list(steps), do: steps
  def expand(_), do: []

  @doc """
  Dispatch a runbook. Each step targets its own runner(s) via its
  `runner_selector` (set in the editor): a `runner_id` list passed
  through, or a `group` list resolved to those groups' active members at
  dispatch. Mints a `runbook_execution_id` grouping the runs, expands
  each step against its own runners into the work list, and dispatches
  the first wave of `#{@batch_size}`; later waves fire from
  `dispatch_next_batch/1` as runs finish. Any failed/denied run or row-less
  dispatch failure halts the waves that follow it.

  `opts[:max_runners_per_step]` and `opts[:max_fan_out]` let a stricter caller
  tighten, but never relax, the domain ceilings. They are applied while the
  work list used by the execution transaction is resolved, closing the race
  between an earlier caller preflight and changing group membership.

  Requires `dispatch_run` permission; the runbook must be in the subject's
  account. Returns
  `{:ok, %{execution_id: …, total: …, plan: […], runs: […], errors: […]}}`
  once at least one run row exists — `plan` is the full resolved work-list
  (`%{step_id, step_index, action_id, runner_id}` per step×runner the
  execution will run, all waves) for the dispatch UI to render up front,
  keyed (`step_id`) to match each run's `runbook_step_id`; `errors` carries
  this wave's dispatch failures as `%{step_id, runner_id, reason}` (same
  `step_id` keying, so the UI can mark the matching placeholder row) — or
  `{:error, reason}` when nothing could be dispatched: `:empty_runbook`,
  `{:step_no_runners, n}` when step `n`'s group resolves to no active runners,
  or `{:fan_out_too_large, max}` when the resolved work exceeds the cap.
  """
  def dispatch_runbook(%Runbook{} = runbook, reason, %Subject{} = subject, opts \\ [])
      when is_binary(reason) do
    operation_id = Keyword.get(opts, :operation_id)
    operation_fingerprint = Keyword.get(opts, :operation_fingerprint)
    operation_ref = Keyword.get(opts, :operation_ref)
    expansion_limits = Keyword.take(opts, [:max_runners_per_step, :max_fan_out])

    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Emisar.Runs.Authorizer.dispatch_run_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id),
         :ok <- ensure_membership(subject),
         steps = expand(runbook),
         :ok <- ensure_steps(steps),
         :ok <- ensure_unique_step_ids(steps),
         {:ok, work_list} <- resolve_work_list(runbook.account_id, steps, expansion_limits) do
      if operation_id do
        dispatch_mcp_first_wave(
          runbook,
          reason,
          subject,
          work_list,
          operation_id,
          operation_fingerprint,
          operation_ref,
          true
        )
      else
        dispatch_first_wave(runbook, reason, subject, work_list)
      end
    end
  end

  # Persist the execution, then dispatch its first wave.
  defp dispatch_first_wave(runbook, reason, subject, work_list) do
    case create_execution(runbook, reason, subject, work_list) do
      {:ok, execution} ->
        outcomes =
          work_list
          |> Enum.take(@batch_size)
          |> Enum.map(fn item ->
            dispatch_item(runbook, execution, item, &Emisar.Runs.dispatch_run(&1, subject))
          end)

        runs = for {:ok, run} <- outcomes, do: run
        errors = for {:error, dispatch_error} <- outcomes, do: dispatch_error
        rows = length(runs) + Enum.count(outcomes, &(&1 == :row_exists))

        if rows == 0 and errors != [] do
          # Nothing dispatched at all → the whole start failed; hand the caller
          # the bare reason (the per-row identity is only useful when some rows
          # did dispatch and others didn't).
          {:error, hd(errors).reason}
        else
          {:ok, execution_result(execution.id, work_list, runs, errors)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_mcp_first_wave(
         runbook,
         reason,
         subject,
         work_list,
         operation_id,
         fingerprint,
         operation_ref,
         use_grants?
       ) do
    execution_id = MCPOperations.resource_id(operation_id, :execute_runbook, subject)

    operation_attrs = %{
      operation_id: operation_id,
      tool: :execute_runbook,
      fingerprint: fingerprint,
      resource_id: execution_id,
      resource_ref: operation_ref
    }

    descriptor = %{
      id: execution_id,
      reason: reason,
      user_id: Subject.user_id(subject),
      membership_id: subject.membership_id,
      operation_id: operation_id
    }

    first_wave_attrs =
      work_list
      |> Enum.take(@batch_size)
      |> Enum.map(&step_attrs(runbook, descriptor, &1))

    with {:ok, multi} <-
           MCPOperations.reserve_in_multi(Multi.new(), operation_attrs, subject),
         {:ok, multi} <-
           compose_mcp_execution(
             multi,
             runbook,
             reason,
             subject,
             work_list,
             first_wave_attrs,
             execution_id,
             use_grants?
           ) do
      result =
        Repo.commit_multi(multi,
          after_commit: &Emisar.Runs.after_composed_dispatches_committed/1
        )

      case result do
        {:ok, %{mcp_operation: _reservation}} ->
          with {:ok, execution} <- fetch_execution_by_id(execution_id, subject) do
            runs = Emisar.Runs.list_runs_for_runbook_execution(runbook.account_id, execution.id)
            stored_work_list = frozen_items(execution.work_list, expand(runbook))
            {:ok, execution_result(execution.id, stored_work_list, runs, [])}
          end

        {:error, :grant_unusable} when use_grants? ->
          dispatch_mcp_first_wave(
            runbook,
            reason,
            subject,
            work_list,
            operation_id,
            fingerprint,
            operation_ref,
            false
          )

        other ->
          other
      end
    end
  end

  defp compose_mcp_execution(
         multi,
         runbook,
         reason,
         subject,
         work_list,
         first_wave_attrs,
         execution_id,
         use_grants?
       ) do
    {:ok,
     Multi.merge(multi, fn
       %{mcp_operation: %{fresh?: false}} ->
         Multi.new()

       %{mcp_operation: %{operation: operation, fresh?: true}} ->
         attrs = %{
           id: execution_id,
           account_id: runbook.account_id,
           runbook_id: runbook.id,
           initiating_membership_id: subject.membership_id,
           requested_by_id: Subject.user_id(subject),
           api_key_id: Subject.api_key_id(subject),
           operation_id: operation.operation_id,
           mcp_operation_record_id: operation.id,
           reason: reason,
           work_list: freeze_work_list(work_list)
         }

         execution_multi =
           Multi.new()
           |> Multi.insert(:execution, RunbookExecution.Changeset.create(attrs))
           |> Multi.insert(:execution_audit, fn %{execution: execution} ->
             Audit.Events.runbook_dispatched(
               subject,
               runbook,
               execution,
               length(work_list),
               ceil(length(work_list) / @batch_size)
             )
           end)

         case Emisar.Runs.compose_dispatch_batch_in_multi(
                execution_multi,
                first_wave_attrs,
                subject,
                {:runbook_first_wave, execution_id},
                use_grants?: use_grants?
              ) do
           {:ok, composed} -> composed
           {:error, reason} -> Multi.error(Multi.new(), :mcp_dispatch_batch, reason)
         end
     end)}
  end

  defp execution_result(execution_id, work_list, runs, errors) do
    %{
      execution_id: execution_id,
      total: length(work_list),
      plan: build_plan(work_list),
      runs: runs,
      errors: errors
    }
  end

  @doc """
  Resolve a runbook's steps to the full work-list — the blast radius — WITHOUT
  dispatching, so the run form can show it before the operator commits. Requires
  `dispatch_run` (the run page's gate); the runbook must be in the subject's
  account. `{:ok, %{plan: [...], total: n, waves: w}}` — `plan` matches
  `dispatch_runbook`'s, `waves` = ⌈total/#{@batch_size}⌉ — or the same
  `{:error, :empty_runbook | {:step_no_runners, n} | {:fan_out_too_large, max}}`
  a dispatch would hit.
  """
  def resolve_plan(%Runbook{} = runbook, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Emisar.Runs.Authorizer.dispatch_run_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id),
         steps = expand(runbook),
         :ok <- ensure_steps(steps),
         :ok <- ensure_unique_step_ids(steps),
         {:ok, work_list} <- resolve_work_list(runbook.account_id, steps) do
      total = length(work_list)
      {:ok, %{plan: build_plan(work_list), total: total, waves: ceil(total / @batch_size)}}
    end
  end

  @doc """
  Called from runner-result finalization whenever a run reaches a terminal
  state. When the finished run's whole wave is terminal and nothing in
  the execution failed, dispatches the next wave of `#{@batch_size}`
  work-list items; any failed/denied/cancelled run or row-less dispatch
  failure halts the execution (in-flight peers still finish naturally). Safe under concurrent
  finishers: the `(execution, step, runner)` unique index makes the
  losing dispatcher skip already-claimed slots.
  """
  def dispatch_next_batch(
        %Emisar.Runs.ActionRun{
          runbook_id: runbook_id,
          runbook_execution_id: execution_id
        } = run
      )
      when is_binary(runbook_id) and is_binary(execution_id) do
    case peek_runbook_by_account_id(run.account_id, runbook_id) do
      %Runbook{} = runbook ->
        existing = Emisar.Runs.list_runs_for_runbook_execution(run.account_id, execution_id)

        cond do
          Enum.any?(existing, &failed_run?/1) -> :noop
          Enum.any?(existing, &in_flight_run?/1) -> :noop
          true -> continue_execution(runbook, run, existing)
        end

      nil ->
        :noop
    end
  end

  def dispatch_next_batch(_run), do: :noop

  # The engine continues after the terminal runner result commits, where no user
  # is in scope. Rather than trust a nil membership (which would unscope every
  # later wave), it loads the durable execution record and REVALIDATES the
  # authorization anchor before dispatching: the initiating membership must
  # still be active (suspended/deleted → halt), and each runner is re-checked
  # against that membership's CURRENT scope by `dispatch_run_for_account`
  # (scope revoked mid-execution → that runner is refused). Work is taken from
  # the FROZEN work-list resolved at the first wave, so runners added to a
  # selected group after dispatch are never picked up.
  defp continue_execution(%Runbook{} = runbook, %Emisar.Runs.ActionRun{} = finished, existing) do
    with %RunbookExecution{status: :active} = execution <-
           peek_execution(finished.account_id, finished.runbook_execution_id),
         %Emisar.Accounts.Membership{} <-
           Emisar.Accounts.peek_active_membership(
             execution.account_id,
             execution.initiating_membership_id
           ) do
      descriptor = %{
        id: execution.id,
        reason: execution.reason,
        user_id: execution.requested_by_id,
        membership_id: execution.initiating_membership_id,
        operation_id: execution.operation_id
      }

      dispatched = MapSet.new(existing, &{&1.runbook_step_id, &1.runner_id})
      steps = expand(runbook)

      execution.work_list
      |> frozen_items(steps)
      |> Enum.reject(fn {step, idx, runner_id} ->
        MapSet.member?(dispatched, {step_id_for(step, idx), runner_id})
      end)
      |> Enum.take(@batch_size)
      |> Enum.each(fn item ->
        dispatch_item(
          runbook,
          descriptor,
          item,
          &Emisar.Runs.dispatch_run_for_account(&1, runbook.account_id)
        )
      end)

      :noop
    else
      _ -> :noop
    end
  end

  # The changeset caps step + per-step selector count, but groups resolve to an
  # unknown number of active runners — so the materialized fan-out is bounded
  # here, before the full work-list (and the plan + LV assigns built from it)
  # exists. A fleet large enough to blow the cap should target groups across
  # several runbooks rather than one giant execution.
  # Steps × each step's own runners, step-major: step 1 fans out across
  # its runners before step 2 starts claiming wave slots. Fail-fast — a
  # step whose group resolves to no active runners aborts the whole
  # dispatch (`{:step_no_runners, n}`) so the operator fixes it rather
  # than getting a silently-skipped step. Accumulates per-step lists and
  # concats once (not `acc ++ rows` per step — that's quadratic).
  defp resolve_work_list(account_id, steps, opts \\ []) do
    max_runners_per_step = expansion_limit(opts, :max_runners_per_step, @max_fan_out)
    max_fan_out = expansion_limit(opts, :max_fan_out, @max_fan_out)
    runners_by_group = active_runner_ids_by_group(account_id, steps)

    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], 0}, fn {step, idx}, {:ok, acc, count} ->
      case step_runner_ids(step, runners_by_group) do
        [] ->
          {:halt, {:error, {:step_no_runners, idx + 1}}}

        runner_ids when length(runner_ids) > max_runners_per_step ->
          {:halt, {:error, {:step_fan_out_too_large, max_runners_per_step}}}

        runner_ids ->
          count = count + length(runner_ids)

          if count > max_fan_out do
            {:halt, {:error, {:fan_out_too_large, max_fan_out}}}
          else
            {:cont, {:ok, [Enum.map(runner_ids, &{step, idx, &1}) | acc], count}}
          end
      end
    end)
    |> case do
      {:ok, acc, _count} -> {:ok, acc |> Enum.reverse() |> Enum.concat()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expansion_limit(opts, key, ceiling) do
    case Keyword.get(opts, key, ceiling) do
      value when is_integer(value) and value > 0 -> min(value, ceiling)
      _invalid -> ceiling
    end
  end

  # Rehydrate the frozen work-list (persisted at the first wave) into dispatch
  # items, re-reading each step's action/args from the immutable runbook version
  # by index. A persisted index with no matching step (the runbook version went
  # away) contributes nothing. Continuation dispatches ONLY from this frozen set
  # — never re-resolving groups — so runners added to a group mid-execution are
  # not picked up.
  defp frozen_items(work_list, steps) do
    for %{"step_index" => idx, "runner_id" => runner_id} <- work_list,
        step = Enum.at(steps, idx),
        not is_nil(step),
        do: {step, idx, runner_id}
  end

  # Group targets resolve through one Runners-domain read, then each step pulls
  # from that grouped result. A `runner_id` selector still passes through
  # directly; dispatch_run re-validates each runner before enqueueing.
  defp active_runner_ids_by_group(account_id, steps) do
    groups =
      steps
      |> Enum.flat_map(&step_groups/1)
      |> Enum.uniq()

    account_id
    |> Emisar.Runners.list_active_runners_in_groups(groups)
    |> Enum.group_by(& &1.group, & &1.id)
  end

  defp step_groups(step) do
    case StepSelector.parse(step["runner_selector"]) do
      {"group", groups} -> groups
      _ -> []
    end
  end

  defp step_runner_ids(step, runners_by_group) do
    case StepSelector.parse(step["runner_selector"]) do
      {"runner_id", [_ | _] = ids} ->
        ids

      {"group", [_ | _] = groups} ->
        groups
        |> Enum.flat_map(&Map.get(runners_by_group, &1, []))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  # One work-list item through the dispatcher. Returns `{:ok, run}`,
  # `:row_exists` (a policy denial wrote its denied row — the halt
  # signal — or a concurrent finisher already claimed the slot via the
  # `(execution, step, runner)` unique index), or `{:error, reason}` for
  # row-less failures, which halt the execution and are audited so the
  # failed slot has a durable trace.
  defp dispatch_item(%Runbook{} = runbook, execution, {step, idx, runner_id} = item, dispatcher) do
    case dispatcher.(step_attrs(runbook, execution, item)) do
      {:ok, _status, run} ->
        {:ok, run}

      {:error, :denied_by_policy, _reason} ->
        :row_exists

      {:error, %Ecto.Changeset{} = changeset} ->
        if claimed_by_racer?(changeset) do
          :row_exists
        else
          log_wave_dispatch_failure(runbook, execution, step, idx, runner_id, changeset)
          {:error, dispatch_failure(step, idx, runner_id, changeset)}
        end

      {:error, reason} ->
        log_wave_dispatch_failure(runbook, execution, step, idx, runner_id, reason)
        {:error, dispatch_failure(step, idx, runner_id, reason)}
    end
  end

  # A first-wave dispatch failure tagged with the (step, runner) it belongs to
  # — keyed the same way `build_plan` keys its rows (`step_id_for/2`) so the run
  # page can mark the exact placeholder row instead of leaving it grey.
  defp dispatch_failure(step, idx, runner_id, reason),
    do: %{step_id: step_id_for(step, idx), runner_id: runner_id, reason: reason}

  defp claimed_by_racer?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint_name) == "action_runs_execution_step_runner_index"
    end)
  end

  defp log_wave_dispatch_failure(%Runbook{} = runbook, execution, step, idx, runner_id, reason) do
    halt_execution(runbook, execution)

    Audit.record(
      Audit.Events.runbook_step_dispatch_failed(
        runbook,
        execution.id,
        step_id_for(step, idx),
        runner_id,
        reason
      )
    )
  end

  # A row-less dispatch failure is otherwise invisible to the continuation,
  # which derives its halt decision from action run rows. Update only an active
  # execution so concurrent finishers cannot reopen it after the first failure.
  defp halt_execution(%Runbook{} = runbook, execution) do
    RunbookExecution.Query.by_account_id(runbook.account_id)
    |> RunbookExecution.Query.by_id(execution.id)
    |> RunbookExecution.Query.active()
    |> Repo.update_all(set: [status: :halted, halted_at: DateTime.utc_now()])
  end

  defp ensure_steps([]), do: {:error, :empty_runbook}
  defp ensure_steps(_steps), do: :ok

  # The publish gate (Runbook.Changeset) rejects colliding step ids, but a draft
  # can be test-run without publishing — so dispatch refuses LOUDLY rather than
  # let the `{step_id, runner}` unique index silently collapse two distinct steps
  # into one (the second reads as already-dispatched and is skipped). `step_id_for`
  # is the dispatch identity, so dedup on exactly that.
  defp ensure_unique_step_ids(steps) do
    ids =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {step, idx} -> step_id_for(step, idx) end)

    if ids == Enum.uniq(ids), do: :ok, else: {:error, :duplicate_step_ids}
  end

  # `:denied` is terminal (a policy refusal), so it's a non-success terminal —
  # it halts the waves behind it without a special case here.
  defp failed_run?(%Emisar.Runs.ActionRun{status: status}),
    do: Emisar.Runs.ActionRun.terminal?(status) and status != :success

  defp in_flight_run?(%Emisar.Runs.ActionRun{status: status}),
    do: not Emisar.Runs.ActionRun.terminal?(status)

  # -- Authorization ---------------------------------------------------

  @doc "True when the subject may view runbooks (the console nav + section gate)."
  def subject_can_view_runbooks?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_runbooks_permission())

  @doc "Whether `subject` may manage runbooks (admin+)."
  def subject_can_manage_runbooks?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_runbooks_permission())

  # Internal lookup (no Subject) for the runbook engine — `Runs`
  # already authorized at dispatch time, this just continues that flow.
  # Returns nil-or-struct because the caller is a continuation cb where
  # "runbook went away mid-flight" is a meaningful state to no-op on.
  defp peek_runbook_by_account_id(account_id, id) do
    Runbook.Query.not_deleted()
    |> Runbook.Query.by_account_id(account_id)
    |> Runbook.Query.by_id(id)
    |> Repo.peek()
  end

  # Persist the durable execution record — the authorization anchor (initiating
  # membership) + the frozen authorized work-list — once, at the first wave.
  # Returns the in-memory dispatch descriptor the wave loop + every continuation
  # share. Already inside `dispatch_runbook`'s authorized + account-scoped flow.
  defp create_execution(
         %Runbook{} = runbook,
         reason,
         %Subject{} = subject,
         work_list
       ) do
    id = Repo.generate_id()

    attrs = %{
      id: id,
      account_id: runbook.account_id,
      runbook_id: runbook.id,
      initiating_membership_id: subject.membership_id,
      requested_by_id: Subject.user_id(subject),
      api_key_id: Subject.api_key_id(subject),
      reason: reason,
      work_list: freeze_work_list(work_list)
    }

    Multi.new()
    |> Multi.insert(:execution, RunbookExecution.Changeset.create(attrs))
    |> Multi.insert(:audit, fn %{execution: execution} ->
      Audit.Events.runbook_dispatched(
        subject,
        runbook,
        execution,
        length(work_list),
        ceil(length(work_list) / @batch_size)
      )
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{execution: %RunbookExecution{} = execution}} ->
        {:ok, execution_descriptor(execution)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The in-memory dispatch descriptor the wave loop + every continuation share:
  # the id + the frozen authorization anchors read back off the persisted row.
  defp execution_descriptor(%RunbookExecution{} = execution) do
    %{
      id: execution.id,
      reason: execution.reason,
      user_id: execution.requested_by_id,
      membership_id: execution.initiating_membership_id,
      operation_id: execution.operation_id
    }
  end

  # Internal lookup (no Subject) for the continuation callback — account-scoped
  # nil-or-struct (the execution row can be gone if the account/runbook was
  # deleted mid-flight, a meaningful no-op state).
  defp peek_execution(account_id, execution_id) do
    RunbookExecution.Query.by_account_id(account_id)
    |> RunbookExecution.Query.by_id(execution_id)
    |> Repo.peek()
  end

  # Reduce the resolved work-list (`{step, idx, runner_id}`) to the persisted
  # frozen form — only the index + runner, since the step content is re-read
  # from the immutable runbook version on continuation.
  defp freeze_work_list(work_list) do
    Enum.map(work_list, fn {_step, idx, runner_id} ->
      %{"step_index" => idx, "runner_id" => runner_id}
    end)
  end

  defp ensure_membership(%Subject{membership_id: id}) when is_binary(id), do: :ok
  defp ensure_membership(_), do: {:error, :membership_required}

  defp step_attrs(%Runbook{} = runbook, execution, {step, idx, runner_id}) do
    %{
      runner_id: runner_id,
      action_id: step["action"] || step["action_id"],
      args: step["args"] || %{},
      # The raw operator reason comes from the execution descriptor, not
      # a prior run's already-prefixed `reason` — re-prefixing that would
      # nest "runbook: …" wrappers wave after wave.
      reason:
        "runbook: #{runbook.title} • step #{idx + 1}/#{length(expand(runbook))} — #{execution.reason}",
      source: "runbook",
      requested_by_id: execution.user_id,
      # The initiating membership, threaded on EVERY wave (continuation
      # included) — `Runs.dispatch_run_for_account` rejects a runner outside
      # this membership's current runner scope, so a scope revoked
      # mid-execution stops later waves. Never nil on the runbook path.
      requested_by_membership_id: execution.membership_id,
      runbook_id: runbook.id,
      runbook_step_id: step_id_for(step, idx),
      runbook_execution_id: execution.id,
      operation_id: execution.operation_id,
      pack_ref: step["pack_ref"]
    }
  end

  defp step_id_for(step, idx), do: step["id"] || "step_#{idx + 1}"

  # The full resolved work-list as lightweight plan rows for the dispatch UI:
  # every (step, runner) the execution will run, keyed the same way the runs
  # are (`step_id_for/2` ↔ a run's `runbook_step_id`), so the LiveView renders
  # the whole plan up front and flips each row to its live run as runs arrive.
  defp build_plan(work_list) do
    Enum.map(work_list, fn {step, idx, runner_id} ->
      %{
        step_id: step_id_for(step, idx),
        step_index: idx,
        action_id: step["action"] || step["action_id"],
        runner_id: runner_id
      }
    end)
  end
end
