defmodule Emisar.Runbooks do
  @moduledoc """
  Cloud-side runbooks: CRUD + expansion to action runs. A runbook is
  a workflow definition; expanding it produces an ordered sequence of
  `run_action` dispatches, with assert/when/note steps evaluated
  cloud-side.

  v0.1 expansion is straight-line sequential — branching support is
  on the roadmap.
  """

  import Ecto.Query
  alias Emisar.Repo
  alias Emisar.Runbooks.Runbook

  def list_runbooks(account_id) do
    from(r in Runbook,
      where: r.account_id == ^account_id and is_nil(r.archived_at),
      order_by: [asc: r.title, desc: r.version]
    )
    |> Repo.all()
  end

  def get_runbook(account_id, id) do
    from(r in Runbook, where: r.account_id == ^account_id and r.id == ^id)
    |> Repo.one()
  end

  def create_runbook(account_id, user_id, attrs) do
    %Runbook{}
    |> Runbook.changeset(
      Map.merge(attrs, %{
        account_id: account_id,
        created_by_id: user_id,
        version: 1
      })
    )
    |> Repo.insert()
  end

  def save_new_version(%Runbook{} = old, attrs, user_id) do
    %Runbook{}
    |> Runbook.changeset(
      Map.merge(
        %{
          account_id: old.account_id,
          name: old.name,
          slug: old.slug,
          title: old.title,
          description: old.description,
          version: old.version + 1,
          status: old.status,
          created_by_id: user_id
        },
        attrs
      )
    )
    |> Repo.insert()
  end

  def publish(%Runbook{} = rb),
    do: rb |> Ecto.Changeset.change(status: "published") |> Repo.update()

  def archive(%Runbook{} = rb),
    do: rb |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:microsecond), status: "archived") |> Repo.update()

  @doc """
  Expand a runbook into the ordered list of step descriptors that the
  cloud's executor will dispatch. v0.1 returns the literal steps from
  the definition; later versions can evaluate `when` conditions and
  branch.
  """
  def expand(%Runbook{definition: %{"steps" => steps}}) when is_list(steps), do: steps
  def expand(_), do: []

  @doc """
  Dispatches the first step of `runbook` against `runner_id`. Subsequent
  steps fire automatically from `dispatch_next_step/1` when each step's
  run reaches a successful terminal state.

  Returns `{:ok, first_run}` or `{:error, reason}` from the underlying
  Runs.dispatch/2. Errors from later steps surface on the dashboard as
  per-step failed runs.
  """
  def dispatch_runbook(%Runbook{} = runbook, runner_id, user_id, reason)
      when is_binary(runner_id) and is_binary(reason) do
    steps = expand(runbook)
    if steps == [] do
      {:error, :empty_runbook}
    else
      step = hd(steps)
      dispatch_step(runbook, runner_id, user_id, reason, step, 0)
    end
  end

  @doc """
  Called from `Runs.mark_finished` whenever a run reaches a terminal
  state. If the finished run belongs to a runbook AND it succeeded, we
  dispatch the next step. A non-success result stops the runbook
  (operators see the failed step on the runbook detail page).
  """
  def dispatch_next_step(%Emisar.Runs.ActionRun{
        runbook_id: rb_id,
        runbook_step_id: step_id,
        status: "success"
      } = run)
      when is_binary(rb_id) and is_binary(step_id) do
    case get_runbook(run.account_id, rb_id) do
      %Runbook{} = runbook ->
        steps = expand(runbook)

        idx =
          steps
          |> Enum.with_index()
          |> Enum.find_value(fn {step, i} -> if step_id?(step, i, step_id), do: i end)

        cond do
          is_nil(idx) -> :noop
          idx + 1 >= length(steps) -> :noop
          true ->
            next = Enum.at(steps, idx + 1)
            dispatch_step(runbook, run.runner_id, run.requested_by_id, run.reason, next, idx + 1)
        end

      _ ->
        :noop
    end
  end

  def dispatch_next_step(_), do: :noop

  defp dispatch_step(runbook, runner_id, user_id, reason, step, idx) do
    Emisar.Runs.dispatch(runbook.account_id, %{
      runner_id: runner_id,
      action_id: step["action"] || step["action_id"],
      args: step["args"] || %{},
      opts: step["opts"] || %{},
      reason: "runbook: #{runbook.title} • step #{idx + 1}/#{length(expand(runbook))} — #{reason}",
      source: "runbook",
      requested_by_id: user_id,
      runbook_id: runbook.id,
      runbook_step_id: step_id_for(step, idx)
    })
  end

  # Steps may declare an explicit `id:` in YAML or rely on positional
  # numbering. Whichever form we persist on the run row at dispatch
  # time, `dispatch_next_step` must reproduce the same string when
  # looking the step up — otherwise the chain stops after step 1.
  defp step_id_for(step, idx), do: step["id"] || "step_#{idx + 1}"

  defp step_id?(step, idx, id), do: step_id_for(step, idx) == id
end
