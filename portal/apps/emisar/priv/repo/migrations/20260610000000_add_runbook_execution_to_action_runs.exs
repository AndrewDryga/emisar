defmodule Emisar.Repo.Migrations.AddRunbookExecutionToActionRuns do
  use Ecto.Migration

  def change do
    alter table(:action_runs) do
      # Groups every run minted by one runbook invocation. The runbook
      # engine derives its wave state (dispatched / in-flight / failed)
      # entirely from the execution's run rows, so this is the only
      # execution identity that exists.
      add :runbook_execution_id, :binary_id
      # The invocation's dispatch descriptor — target (%{"runner_id" => …}
      # or %{"group" => …}) + the operator's raw reason — duplicated on
      # every run so a continuation can rebuild the work list from any
      # finished run without an execution table.
      add :runbook_dispatch, :map
    end

    create index(:action_runs, [:account_id, :runbook_execution_id],
             where: "runbook_execution_id IS NOT NULL"
           )

    # Race backstop: two runs of the same wave finishing concurrently both
    # try to dispatch the next wave; the loser's insert hits this index and
    # the engine skips the already-claimed (step, runner) slot.
    create unique_index(:action_runs, [:runbook_execution_id, :runbook_step_id, :runner_id],
             where: "runbook_execution_id IS NOT NULL",
             name: :action_runs_execution_step_runner_index
           )
  end
end
