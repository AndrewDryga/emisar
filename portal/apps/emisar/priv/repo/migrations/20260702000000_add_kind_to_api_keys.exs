defmodule Emisar.Repo.Migrations.AddKindToApiKeys do
  use Ecto.Migration

  # Corrective (api_keys is on prod). Make the MCP-key vs audit-export-token
  # distinction explicit instead of inferring it from the `audit:read` scope.
  # Existing rows are back-classified by that scope; new rows default to `mcp`.
  def change do
    alter table(:api_keys) do
      add :kind, :string, null: false, default: "mcp"
    end

    execute(
      "UPDATE api_keys SET kind = 'audit_export' WHERE 'audit:read' = ANY(scopes)",
      "UPDATE api_keys SET kind = 'mcp'"
    )
  end
end
