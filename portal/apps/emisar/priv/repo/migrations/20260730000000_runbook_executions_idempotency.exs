defmodule Emisar.Repo.Migrations.RunbookExecutionsIdempotency do
  use Ecto.Migration

  # MCP execute_runbook idempotency. The bridge / LLM client passes
  # `Idempotency-Key: <uuid>` per JSON-RPC call; we attach it to the execution
  # row and unique-index on (api_key_id, idempotency_key) so a retried
  # execute_runbook returns the ORIGINAL governed execution instead of minting a
  # fresh one that re-runs every step (the child runs carry a new execution_id,
  # so the (execution, step, runner) index can't dedupe across executions).
  # Mirrors the single-action `action_runs_api_key_idempotency_key_index`.
  # Both columns stay null on the user-initiated (web) path — no api key, no
  # key — so the partial index never engages there.
  def change do
    alter table(:runbook_executions) do
      add :api_key_id, :binary_id
      add :idempotency_key, :string
    end

    create unique_index(:runbook_executions, [:api_key_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :runbook_executions_api_key_idempotency_key_index
           )
  end
end
