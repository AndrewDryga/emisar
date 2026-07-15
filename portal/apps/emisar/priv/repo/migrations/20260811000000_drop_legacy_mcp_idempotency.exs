defmodule Emisar.Repo.Migrations.DropLegacyMcpIdempotency do
  use Ecto.Migration

  def change do
    drop_if_exists index(:action_runs, [:api_key_id, :idempotency_key],
                     name: :action_runs_api_key_idempotency_key_index
                   )

    alter table(:action_runs) do
      remove :idempotency_key, :string
    end

    drop_if_exists index(:runbook_executions, [:api_key_id, :idempotency_key],
                     name: :runbook_executions_api_key_idempotency_key_index
                   )

    alter table(:runbook_executions) do
      remove :idempotency_key, :string
    end
  end
end
