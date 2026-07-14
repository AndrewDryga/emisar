defmodule Emisar.MCPOperations.Operation.Changeset do
  use Emisar, :changeset
  alias Emisar.MCPOperations.Operation

  @fields ~w[
    id account_id credential_lineage_id operation_id tool fingerprint
    action_id pack_ref resource_id resource_ref
  ]a
  @operation_id ~r/\Aop_[0-7][0-9A-HJKMNP-TV-Z]{25}\z/

  def reserve(attrs) do
    %Operation{}
    |> cast(attrs, @fields)
    |> validate_required([
      :id,
      :account_id,
      :credential_lineage_id,
      :operation_id,
      :tool,
      :fingerprint
    ])
    |> validate_format(:operation_id, @operation_id)
    |> validate_length(:fingerprint, is: 64)
    |> validate_length(:action_id, max: 255)
    |> validate_length(:pack_ref, max: 512)
    |> validate_length(:resource_ref, max: 255)
    |> unique_constraint([:account_id, :credential_lineage_id, :operation_id],
      name: :mcp_operations_lineage_operation_index
    )
    |> check_constraint(:tool, name: :mcp_operations_tool_shape)
    |> check_constraint(:operation_id, name: :mcp_operations_identity_bounds)
  end
end
