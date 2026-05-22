defmodule Emisar.Policies.Policy do
  @moduledoc """
  A policy bundle that decides whether (and how) an action call may
  proceed. The runner doesn't see this; cloud evaluates it before
  sending `run_action`. Versioned — each save is a new row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "policies" do
    field :name, :string
    field :description, :string
    field :version, :integer, default: 1
    field :is_default, :boolean, default: false
    field :rules, :map, default: %{"allow" => [], "deny" => [], "require_approval" => []}
    field :archived_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :created_by, Emisar.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:account_id, :name, :description, :rules, :is_default, :created_by_id, :version])
    |> validate_required([:account_id, :name, :rules])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_rules()
    |> unique_constraint([:account_id, :name, :version])
  end

  defp validate_rules(changeset) do
    case get_change(changeset, :rules) do
      nil ->
        changeset

      rules when is_map(rules) ->
        keys = Map.keys(rules)
        valid = ["allow", "deny", "require_approval", "expose"]

        if Enum.all?(keys, &(&1 in valid)) do
          changeset
        else
          add_error(changeset, :rules, "unknown rule sections: #{inspect(keys -- valid)}")
        end

      _ ->
        add_error(changeset, :rules, "must be a JSON object")
    end
  end
end
