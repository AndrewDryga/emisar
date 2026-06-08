defmodule Emisar.Repo.Migrations.AddClientInfo do
  use Ecto.Migration

  # MCP clients report a {name, version, ...} clientInfo at `initialize`.
  # We snapshot it onto each run (so historical runs stay accurate even as
  # a key is reused) and keep the latest per key — the api_key is the link
  # between an `initialize` and the `tools/call`s that follow it.
  def change do
    alter table(:action_runs) do
      add :client_info, :map, null: false, default: %{}
    end

    alter table(:api_keys) do
      add :last_client_info, :map, null: false, default: %{}
    end
  end
end
