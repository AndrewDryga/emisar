defmodule Emisar.Repo.Migrations.WidenPolicyDecisionSnapshots do
  use Ecto.Migration

  def change do
    # The policy decision a run or runbook item snapshots quotes the matched rule
    # by name (or by its action pattern when it has none), so a valid rule name of
    # a couple of hundred characters made the explanation outgrow the varchar(255)
    # these columns were created with. Postgres raised 22001 inside dispatch: the
    # run row was never written, and a denied attempt lost its denial receipt.
    # The explanation and the rule identities are audit evidence, so they are kept
    # whole rather than truncated. Widening is data-safe.
    alter table(:action_runs) do
      modify :policy_reason, :text, from: :string
      modify :matched_rules, {:array, :text}, from: {:array, :string}
    end

    alter table(:runbook_execution_items) do
      modify :policy_reason, :text, from: :string
      modify :matched_rules, {:array, :text}, from: {:array, :string}
    end
  end
end
