defmodule Emisar.Repo.Migrations.ApiKeyRunnerGroupFilter do
  use Ecto.Migration

  def change do
    # `runner_group_filter` is a parallel allowlist to `runner_filter`.
    # An API key allows a runner if the runner's id is in `runner_filter`
    # OR its group is in `runner_group_filter`. Empty both = all runners
    # (current behavior — backward-compatible default).
    #
    # Group targeting lets operators say "this Claude key can call any
    # cassandra runner" without having to update the filter every time
    # a new cassandra runner is installed.
    alter table(:api_keys) do
      add :runner_group_filter, {:array, :string}, default: [], null: false
    end
  end
end
