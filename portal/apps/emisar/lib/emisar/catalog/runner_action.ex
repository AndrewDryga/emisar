defmodule Emisar.Catalog.RunnerAction do
  @moduledoc """
  An action advertised by a specific runner. We store the full
  runner_state ActionDescriptor as JSON so the UI and MCP tool listings
  can render exactly what the runner declared without secondary lookups.
  """
  use Emisar, :schema

  schema "catalog_runner_actions" do
    field :action_id, :string
    field :pack_id, :string
    field :pack_version, :string
    field :pack_hash, :string
    field :title, :string
    field :summary, :string
    field :kind, Ecto.Enum, values: [:exec, :script]
    field :risk, Ecto.Enum, values: [:low, :medium, :high, :critical]
    field :description, :string
    field :side_effects, {:array, :string}, default: []
    field :args_schema, :map, default: %{}
    field :output_schema, :map
    field :examples, {:array, :map}, default: []
    field :search_terms, {:array, :string}, default: []
    # Mutable host evidence. Nil means an older runner did not advertise this
    # fact; false can only remove this action from otherwise trusted targets.
    field :primary_executable_available, :boolean
    field :missing_executable, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    # Filled by the runner-detail catalog read. Nil means dispatch is allowed;
    # the transaction still rechecks the exact pack trust before creating a run.
    field :dispatch_block_reason, Ecto.Enum,
      values: [:pack_untrusted, :pack_retired],
      virtual: true

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :runner, Emisar.Runners.Runner, where: [deleted_at: nil]

    timestamps()
  end
end
