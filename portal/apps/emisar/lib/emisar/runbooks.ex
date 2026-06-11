defmodule Emisar.Runbooks do
  @moduledoc """
  Cloud-side runbooks: CRUD + expansion to action runs. A runbook is
  a workflow definition; expanding it produces an ordered sequence of
  `run_action` dispatches, one per step.

  v0.1 expansion is straight-line sequential — branching, conditional
  steps, and inline assertions are on the roadmap.
  """
  alias Ecto.Multi
  alias Emisar.{Audit, Auth, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runbooks.{Authorizer, Runbook}

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
             Authorizer.manage_runbooks_permission()
           ) do
      user_id = Subject.actor_id(subject)

      Multi.new()
      |> Multi.insert(
        :runbook,
        Runbook.Changeset.create(account.id, user_id, attrs)
      )
      |> Multi.insert(:audit, fn %{runbook: runbook} ->
        Audit.Events.runbook_created(subject, runbook)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_runbook_change(&1, "runbook.created"))
      |> case do
        {:ok, %{runbook: runbook}} -> {:ok, runbook}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Subscribe the caller to the account's runbook list changes (`{:list_changed, :runbook, …}`)."
  def subscribe_account_runbooks(account_id),
    do: Emisar.PubSub.subscribe(account_runbooks_topic(account_id))

  defp account_runbooks_topic(account_id), do: "account:#{account_id}:runbooks"

  defp broadcast_runbook_change(%{runbook: runbook}, event_type) do
    Emisar.PubSub.broadcast(
      account_runbooks_topic(runbook.account_id),
      {:list_changed, :runbook, event_type, runbook.id}
    )

    :ok
  end

  def save_new_version(%Runbook{} = old, attrs, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, old.account_id) do
      user_id = Subject.actor_id(subject)

      Multi.new()
      |> Multi.insert(:runbook, Runbook.Changeset.new_version(old, user_id, attrs))
      |> Multi.insert(:audit, fn %{runbook: runbook} ->
        Audit.Events.runbook_updated(subject, old, runbook)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_runbook_change(&1, "runbook.updated"))
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
        audit: fn published -> Audit.Events.runbook_published(subject, published) end,
        after_commit: fn published ->
          broadcast_runbook_change(%{runbook: published}, "runbook.published")
        end
      )
    end
  end

  # -- Expansion + dispatch (internal — called by Runs / executor) ----

  # Runbook steps have no conditions yet, so they're independent and can
  # run concurrently — but unbounded fan-out (steps × group members)
  # would flood runners, so the engine releases waves of this many runs
  # and waits for the wave to finish before the next.
  @batch_size 5

  @doc """
  Expand a runbook into the ordered list of step descriptors that the
  cloud's executor will dispatch.
  """
  def expand(%Runbook{definition: %{"steps" => steps}}) when is_list(steps), do: steps
  def expand(_), do: []

  @doc """
  Dispatch a runbook against `target` — `{:runner, runner_id}` or
  `{:group, group_name}` (every active runner in the group). Mints a
  `runbook_execution_id` grouping the runs, expands steps × runners into
  the work list, and dispatches the first wave of `#{@batch_size}`;
  later waves fire from `dispatch_next_batch/1` as runs finish. Any
  failed/denied run halts the waves that follow it.

  Returns `{:ok, %{execution_id: …, total: …, runs: […], errors: […]}}`
  once at least one run row exists (`errors` carries this wave's
  row-less dispatch failures), or `{:error, reason}` when nothing could
  be dispatched at all.
  """
  def dispatch_runbook(%Runbook{} = runbook, target, reason, %Subject{} = subject)
      when is_binary(reason) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Emisar.Runs.Authorizer.dispatch_run_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id),
         steps = expand(runbook),
         :ok <- ensure_steps(steps),
         dispatch = build_dispatch(target, reason),
         {:ok, runner_ids} <- resolve_target(runbook.account_id, dispatch) do
      execution = %{
        id: Repo.generate_id(),
        dispatch: dispatch,
        user_id: Subject.actor_id(subject),
        membership_id: subject.membership_id
      }

      outcomes =
        steps
        |> build_work_list(runner_ids)
        |> Enum.take(@batch_size)
        |> Enum.map(fn item ->
          dispatch_item(runbook, execution, item, fn attrs ->
            Emisar.Runs.dispatch_run(attrs, subject)
          end)
        end)

      runs = for {:ok, run} <- outcomes, do: run
      errors = for {:error, dispatch_error} <- outcomes, do: dispatch_error
      rows = length(runs) + Enum.count(outcomes, &(&1 == :row_exists))

      if rows == 0 and errors != [] do
        {:error, hd(errors)}
      else
        {:ok,
         %{
           execution_id: execution.id,
           total: length(steps) * length(runner_ids),
           runs: runs,
           errors: errors
         }}
      end
    end
  end

  @doc """
  Called from `Runs.mark_finished` whenever a run reaches a terminal
  state. When the finished run's whole wave is terminal and nothing in
  the execution failed, dispatches the next wave of `#{@batch_size}`
  work-list items; any failed/denied/cancelled run halts the execution
  (in-flight peers still finish naturally). Safe under concurrent
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

  # The engine continues from the post-`mark_finished` callback, where no
  # user is in scope; the original dispatch was already authorized, so we
  # re-enter via the account-scoped internal dispatch (no Subject to
  # forge; `requested_by_membership_id: nil` bypasses the per-membership
  # scope check first dispatch already enforced).
  defp continue_execution(%Runbook{} = runbook, %Emisar.Runs.ActionRun{} = finished, existing) do
    execution = %{
      id: finished.runbook_execution_id,
      dispatch: finished.runbook_dispatch,
      user_id: finished.requested_by_id,
      membership_id: nil
    }

    with {:ok, runner_ids} <- resolve_target(runbook.account_id, execution.dispatch) do
      dispatched = MapSet.new(existing, &{&1.runbook_step_id, &1.runner_id})

      runbook
      |> expand()
      |> build_work_list(runner_ids)
      |> Enum.reject(fn {step, idx, runner_id} ->
        MapSet.member?(dispatched, {step_id_for(step, idx), runner_id})
      end)
      |> Enum.take(@batch_size)
      |> Enum.each(fn item ->
        dispatch_item(runbook, execution, item, fn attrs ->
          Emisar.Runs.dispatch_run_for_account(attrs, runbook.account_id)
        end)
      end)
    end

    :noop
  end

  # Steps × runners, step-major: step 1 fans out across the target's
  # runners before step 2 starts claiming wave slots.
  defp build_work_list(steps, runner_ids) do
    for {step, idx} <- Enum.with_index(steps), runner_id <- runner_ids do
      {step, idx, runner_id}
    end
  end

  # One work-list item through the dispatcher. Returns `{:ok, run}`,
  # `:row_exists` (a policy denial wrote its denied row — the halt
  # signal — or a concurrent finisher already claimed the slot via the
  # `(execution, step, runner)` unique index), or `{:error, reason}` for
  # row-less failures, which are audited so a halted execution leaves a
  # trace.
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
          {:error, changeset}
        end

      {:error, reason} ->
        log_wave_dispatch_failure(runbook, execution, step, idx, runner_id, reason)
        {:error, reason}
    end
  end

  defp claimed_by_racer?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint_name) == "action_runs_execution_step_runner_index"
    end)
  end

  defp log_wave_dispatch_failure(%Runbook{} = runbook, execution, step, idx, runner_id, reason) do
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

  defp ensure_steps([]), do: {:error, :empty_runbook}
  defp ensure_steps(_steps), do: :ok

  defp build_dispatch({:runner, runner_id}, reason) when is_binary(runner_id),
    do: %{"target" => %{"runner_id" => runner_id}, "reason" => reason}

  defp build_dispatch({:group, group}, reason) when is_binary(group),
    do: %{"target" => %{"group" => group}, "reason" => reason}

  # Group membership is resolved at every wave, so runners added to the
  # group mid-execution pick up remaining steps and removed runners stop
  # getting work. `dispatch_run` re-validates each runner per item.
  defp resolve_target(_account_id, %{"target" => %{"runner_id" => runner_id}}),
    do: {:ok, [runner_id]}

  defp resolve_target(account_id, %{"target" => %{"group" => group}}) do
    case Emisar.Runners.list_active_runners_in_group(account_id, group) do
      [] -> {:error, :no_runners_in_group}
      runners -> {:ok, Enum.map(runners, & &1.id)}
    end
  end

  defp failed_run?(%Emisar.Runs.ActionRun{status: :denied}), do: true

  defp failed_run?(%Emisar.Runs.ActionRun{status: status}),
    do: Emisar.Runs.ActionRun.terminal?(status) and status != :success

  defp in_flight_run?(%Emisar.Runs.ActionRun{status: :denied}), do: false

  defp in_flight_run?(%Emisar.Runs.ActionRun{status: status}),
    do: not Emisar.Runs.ActionRun.terminal?(status)

  # -- Authorization ---------------------------------------------------

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

  defp step_attrs(%Runbook{} = runbook, execution, {step, idx, runner_id}) do
    %{
      runner_id: runner_id,
      action_id: step["action"] || step["action_id"],
      args: step["args"] || %{},
      opts: step["opts"] || %{},
      # The raw operator reason comes from the execution descriptor, not
      # a prior run's already-prefixed `reason` — re-prefixing that would
      # nest "runbook: …" wrappers wave after wave.
      reason:
        "runbook: #{runbook.title} • step #{idx + 1}/#{length(expand(runbook))} — #{execution.dispatch["reason"]}",
      source: "runbook",
      requested_by_id: execution.user_id,
      # The operator's membership at first dispatch — `Runs.dispatch_run`
      # rejects if the runner falls outside this membership's runner
      # scope. nil on continuation re-dispatch bypasses the check because
      # the originating dispatch already validated scope.
      requested_by_membership_id: execution.membership_id,
      runbook_id: runbook.id,
      runbook_step_id: step_id_for(step, idx),
      runbook_execution_id: execution.id,
      runbook_dispatch: execution.dispatch
    }
  end

  defp step_id_for(step, idx), do: step["id"] || "step_#{idx + 1}"
end
