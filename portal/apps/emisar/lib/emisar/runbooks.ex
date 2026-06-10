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

  @doc "Whether `subject` may manage runbooks (admin+)."
  def subject_can_manage_runbooks?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_runbooks_permission())

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
      user_id = subject_user_id(subject)

      Multi.new()
      |> Multi.insert(
        :runbook,
        Runbook.Changeset.create(account.id, user_id, attrs)
      )
      |> Multi.insert(:audit, fn %{runbook: rb} ->
        Audit.changeset(rb.account_id, "runbook.created",
          actor_kind: "user",
          actor_id: user_id,
          subject_kind: "runbook",
          subject_id: rb.id,
          subject_label: rb.title || rb.name,
          payload: %{name: rb.name, title: rb.title, version: rb.version}
        )
      end)
      |> Repo.commit_multi(after_commit: &broadcast_runbook_change(&1, "runbook.created"))
      |> case do
        {:ok, %{runbook: rb}} -> {:ok, rb}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp broadcast_runbook_change(%{runbook: rb}, event_type) do
    Emisar.PubSub.broadcast_account_list(rb.account_id, :runbook, event_type, rb.id)
    :ok
  end

  def save_new_version(%Runbook{} = old, attrs, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ) do
      user_id = subject_user_id(subject)

      Multi.new()
      |> Multi.insert(:runbook, Runbook.Changeset.new_version(old, user_id, attrs))
      |> Multi.insert(:audit, fn %{runbook: rb} ->
        Audit.changeset(rb.account_id, "runbook.updated",
          actor_kind: "user",
          actor_id: user_id,
          subject_kind: "runbook",
          subject_id: rb.id,
          subject_label: rb.title || rb.name,
          payload: %{
            name: rb.name,
            title: rb.title,
            from_version: old.version,
            to_version: rb.version
          }
        )
      end)
      |> Repo.commit_multi(after_commit: &broadcast_runbook_change(&1, "runbook.updated"))
      |> case do
        {:ok, %{runbook: rb}} -> {:ok, rb}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def publish(%Runbook{} = rb, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ) do
      user_id = subject_user_id(subject)

      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(rb.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runbook.Query,
        with: &Runbook.Changeset.update(&1, %{status: "published"}),
        audit: fn published ->
          Audit.changeset(published.account_id, "runbook.published",
            actor_kind: "user",
            actor_id: user_id,
            subject_kind: "runbook",
            subject_id: published.id,
            subject_label: published.title || published.name,
            payload: %{name: published.name, version: published.version}
          )
        end,
        after_commit: fn published ->
          broadcast_runbook_change(%{runbook: published}, "runbook.published")
        end
      )
    end
  end

  # System actors (Subject.system/1) carry `:system` as their actor and
  # have no user id — leaving `created_by_id` nil is the right shape
  # for seed-time / worker-time creation.
  defp subject_user_id(%Subject{actor: %{id: id}}), do: id
  defp subject_user_id(%Subject{actor: :system}), do: nil

  # -- Expansion + dispatch (internal — called by Runs / executor) ----

  @doc """
  Expand a runbook into the ordered list of step descriptors that the
  cloud's executor will dispatch.
  """
  def expand(%Runbook{definition: %{"steps" => steps}}) when is_list(steps), do: steps
  def expand(_), do: []

  @doc """
  Dispatch the first step of a runbook. Subsequent steps fire from
  `dispatch_next_step/1` when each step's run reaches a successful
  terminal state. Subject-gated like any other public mutation —
  rejected if the actor can't dispatch_run on this account.
  """
  def dispatch_runbook(%Runbook{} = runbook, runner_id, reason, %Subject{} = subject)
      when is_binary(runner_id) and is_binary(reason) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Emisar.Runs.Authorizer.dispatch_run_permission()
           ) do
      steps = expand(runbook)

      if steps == [] do
        {:error, :empty_runbook}
      else
        step = hd(steps)
        dispatch_step(runbook, runner_id, subject_user_id(subject), reason, step, 0, subject)
      end
    end
  end

  @doc """
  Called from `Runs.mark_finished` whenever a run reaches a terminal
  state. On success → dispatch the next step. Non-success stops the
  runbook (failed step is visible on the runbook detail page).
  """
  def dispatch_next_step(
        %Emisar.Runs.ActionRun{
          runbook_id: rb_id,
          runbook_step_id: step_id,
          status: "success"
        } = run
      )
      when is_binary(rb_id) and is_binary(step_id) do
    case peek_runbook_by_account_id(run.account_id, rb_id) do
      %Runbook{} = runbook ->
        steps = expand(runbook)

        idx =
          steps
          |> Enum.with_index()
          |> Enum.find_value(fn {step, i} -> if step_id_for(step, i) == step_id, do: i end)

        next_idx = if is_integer(idx), do: idx + 1

        if next_idx && next_idx < length(steps) do
          # System subject — the runbook engine continues the chain in
          # the post-`mark_finished` callback, where no user is in
          # scope; the original dispatch was already authorized.
          system = Subject.system(%Emisar.Accounts.Account{id: run.account_id})

          dispatch_step(
            runbook,
            run.runner_id,
            run.requested_by_id,
            run.reason,
            Enum.at(steps, next_idx),
            next_idx,
            system
          )
        else
          :noop
        end

      _ ->
        :noop
    end
  end

  def dispatch_next_step(_), do: :noop

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

  defp dispatch_step(runbook, runner_id, user_id, reason, step, idx, %Subject{} = subject) do
    Emisar.Runs.dispatch_run(
      %{
        runner_id: runner_id,
        action_id: step["action"] || step["action_id"],
        args: step["args"] || %{},
        opts: step["opts"] || %{},
        reason:
          "runbook: #{runbook.title} • step #{idx + 1}/#{length(expand(runbook))} — #{reason}",
        source: "runbook",
        requested_by_id: user_id,
        # The operator's membership at dispatch time — `Runs.dispatch_run`
        # rejects if the runner falls outside this membership's runner
        # scope. nil on continuation (Subject.system) bypasses the check
        # because the originating dispatch already validated scope.
        requested_by_membership_id: subject.membership_id,
        runbook_id: runbook.id,
        runbook_step_id: step_id_for(step, idx)
      },
      subject
    )
  end

  defp step_id_for(step, idx), do: step["id"] || "step_#{idx + 1}"
end
