defmodule Emisar.Repo.Migrations.AddDispatchJustificationChain do
  use Ecto.Migration

  def change do
    # The dispatch justification grew from a single short reason into an optional
    # logical chain — reason, then the evidence that motivated the action and the
    # outcome expected to confirm it — and reason's cap rose to 2000 chars, past
    # the varchar(255) this column was created with. Widen reason to text and add
    # the two optional chain columns. Widening is data-safe; the new columns are
    # nullable, since the fields are optional everywhere.
    alter table(:action_runs) do
      modify :reason, :text, from: :string
      add :evidence, :text
      add :expected, :text
    end

    # Approval requests snapshot the dispatch justification at creation so the
    # decision surface stays self-contained even if the run is pruned; mirror the
    # run's chain columns exactly.
    alter table(:approval_requests) do
      modify :reason, :text, from: :string
      add :evidence, :text
      add :expected, :text
    end

    # runbook_executions.reason is already :text (20260623000000), so the raised
    # reason cap needs no change there.
  end
end
