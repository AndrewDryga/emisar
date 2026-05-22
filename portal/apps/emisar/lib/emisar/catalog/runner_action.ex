defmodule Emisar.Catalog.RunnerAction do
  @moduledoc """
  An action advertised by a specific runner. We store the full
  agent_state ActionDescriptor as JSON so the UI and MCP tool listings
  can render exactly what the runner declared without secondary lookups.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @risks ~w(low medium high critical)
  @kinds ~w(exec script)

  schema "runner_actions" do
    field :action_id, :string
    field :pack_id, :string
    field :title, :string
    field :kind, :string
    field :risk, :string
    field :description, :string
    field :side_effects, {:array, :string}, default: []
    field :args_schema, :map, default: %{}
    field :limits, :map, default: %{}
    field :output, :map, default: %{}
    field :examples, {:array, :map}, default: []
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :runner, Emisar.Runners.Runner

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :account_id, :runner_id, :action_id, :pack_id, :title, :kind, :risk,
      :description, :side_effects, :args_schema, :limits, :output, :examples,
      :first_seen_at, :last_seen_at
    ])
    |> validate_required([:account_id, :runner_id, :action_id, :title, :kind, :risk])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:risk, @risks)
    |> unique_constraint([:runner_id, :action_id])
  end

  def risks, do: @risks
  def kinds, do: @kinds
end
