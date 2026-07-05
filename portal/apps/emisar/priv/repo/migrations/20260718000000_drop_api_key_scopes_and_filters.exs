defmodule Emisar.Repo.Migrations.DropApiKeyScopesAndFilters do
  use Ecto.Migration

  # Agent/API keys carry no per-key authorization scope anymore: `kind`
  # (:mcp | :audit_export) is the sole capability discriminator, account Policy +
  # approval decide what a key may do, and the minting operator's own
  # `UserRunnerScope` decides which runners it can reach. Drop the now-dead
  # per-key columns. `change/0` is reversible — `down` re-adds them empty.
  def change do
    alter table(:api_keys) do
      remove :scopes, {:array, :string}, default: []
      remove :runner_filter, {:array, :string}, default: []
      remove :runner_group_filter, {:array, :string}, default: []
      remove :action_scope, {:array, :string}, default: []
    end
  end
end
