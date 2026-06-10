defmodule Emisar.Catalog.RunnerAction do
  @moduledoc """
  An action advertised by a specific runner. We store the full
  runner_state ActionDescriptor as JSON so the UI and MCP tool listings
  can render exactly what the runner declared without secondary lookups.
  """
  use Emisar, :schema

  schema "runner_actions" do
    field :action_id, :string
    field :pack_id, :string
    field :pack_version, :string
    field :title, :string
    field :kind, Ecto.Enum, values: [:exec, :script]
    field :risk, Ecto.Enum, values: [:low, :medium, :high, :critical]
    field :description, :string
    field :side_effects, {:array, :string}, default: []
    field :args_schema, :map, default: %{}
    field :limits, :map, default: %{}
    field :output, :map, default: %{}
    field :examples, {:array, :map}, default: []
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :runner, Emisar.Runners.Runner, where: [deleted_at: nil]

    timestamps()
  end
end
