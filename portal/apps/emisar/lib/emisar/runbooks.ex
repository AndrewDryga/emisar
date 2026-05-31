defmodule Emisar.Runbooks do
  @moduledoc """
  Cloud-side runbooks: CRUD + expansion to action runs. A runbook is
  a workflow definition; expanding it produces an ordered sequence of
  `run_action` dispatches, with assert/when/note steps evaluated
  cloud-side.

  v0.1 expansion is straight-line sequential — branching support is
  on the roadmap.
  """

  alias Emisar.{Auth, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runbooks.{Authorizer, Runbook}

  # -- Reads -----------------------------------------------------------

  def list_runbooks(%Subject{} = subject, opts \\ []) do
    with :ok <- Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.not_archived()
      |> Runbook.Query.ordered_by_title_version()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Runbook.Query, opts)
    end
  end

  def fetch_runbook_by_id(id, %Subject{} = subject) do
    with :ok <- Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
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

  # -- Mutations -------------------------------------------------------

  def create_runbook(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ) do
      Runbook.Changeset.create(account.id, subject_user_id(subject), Map.put(attrs, :version, 1))
      |> Repo.insert()
    end
  end

  def save_new_version(%Runbook{} = old, attrs, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ) do
      Runbook.Changeset.create(
        old.account_id,
        subject_user_id(subject),
        Map.merge(
          %{
            name: old.name,
            slug: old.slug,
            title: old.title,
            description: old.description,
            version: old.version + 1,
            status: old.status
          },
          attrs
        )
      )
      |> Repo.insert()
    end
  end

  def publish(%Runbook{} = rb, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(rb.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runbook.Query,
        with: &Runbook.Changeset.update(&1, %{status: "published"})
      )
    end
  end

  def archive(%Runbook{} = rb, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(rb.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runbook.Query, with: &Runbook.Changeset.archive/1)
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
  def dispatch_next_step(%Emisar.Runs.ActionRun{
        runbook_id: rb_id,
        runbook_step_id: step_id,
        status: "success"
      } = run)
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
        runbook_id: runbook.id,
        runbook_step_id: step_id_for(step, idx)
      },
      subject
    )
  end

  defp step_id_for(step, idx), do: step["id"] || "step_#{idx + 1}"
end
