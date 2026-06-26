defmodule Emisar.Repo.Migrations.AddActionScopeToApiKeys do
  use Ecto.Migration

  # Corrective (api_keys is on prod). Per-action allow-list on an MCP key:
  # empty = any action (today's behaviour, so existing keys are unaffected),
  # non-empty = only these action_ids may be dispatched. Enforced at the MCP
  # dispatch boundary, tightening a leaked key from "any action on the group"
  # to a bounded set.
  def change do
    alter table(:api_keys) do
      add :action_scope, {:array, :string}, null: false, default: []
    end
  end
end
