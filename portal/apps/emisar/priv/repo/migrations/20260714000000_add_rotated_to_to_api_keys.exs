defmodule Emisar.Repo.Migrations.AddRotatedToToApiKeys do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      # Successor minted by auto-rotation — non-nil marks the key as
      # superseded and is the at-most-once guard for response-carried
      # rotation at the MCP boundary.
      add :rotated_to_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
