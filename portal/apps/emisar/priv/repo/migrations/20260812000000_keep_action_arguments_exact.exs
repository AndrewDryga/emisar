defmodule Emisar.Repo.Migrations.KeepActionArgumentsExact do
  use Ecto.Migration

  def up do
    execute(
      "UPDATE action_runs SET args_raw = convert_to(args::text, 'UTF8') WHERE args_raw IS NULL"
    )

    alter table(:action_runs) do
      modify :args_raw, :binary, null: false
      add :sensitive_arg_names, {:array, :string}, null: false, default: []
      remove :args
    end
  end

  def down do
    alter table(:action_runs) do
      add :args, :map, null: false, default: fragment("'{}'::jsonb")
      remove :sensitive_arg_names
      modify :args_raw, :binary, null: true
    end

    execute("UPDATE action_runs SET args = convert_from(args_raw, 'UTF8')::jsonb")
  end
end
