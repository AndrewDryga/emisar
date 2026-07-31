defmodule Emisar.Repo.Migrations.FreezeRunbookTargetSelection do
  use Ecto.Migration

  def change do
    alter table(:runbook_execution_items) do
      add :target_selection, :string, null: false, default: "all"
      add :target_group, :string
    end

    create constraint(:runbook_execution_items, :runbook_execution_items_target_selection_check,
             check: "target_selection IN ('all', 'random_one')"
           )

    create constraint(
             :runbook_execution_items,
             :runbook_execution_items_target_selection_group_check,
             check:
               "(target_selection = 'all' AND target_group IS NULL) OR " <>
                 "(target_selection = 'random_one' AND target_group IS NOT NULL)"
           )

    execute(
      "ALTER TABLE runbook_execution_items ALTER COLUMN target_selection DROP DEFAULT",
      "ALTER TABLE runbook_execution_items ALTER COLUMN target_selection SET DEFAULT 'all'"
    )
  end
end
