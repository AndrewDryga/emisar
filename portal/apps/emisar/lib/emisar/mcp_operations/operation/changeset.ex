defmodule Emisar.MCPOperations.Operation.Changeset do
  use Emisar, :changeset
  alias Emisar.MCPOperations.Operation

  @fields ~w[
    id account_id credential_lineage_id operation_id tool fingerprint
    action_id pack_ref resource_id resource_ref
  ]a
  @operation_id ~r/\Aop_[0-7][0-9A-HJKMNP-TV-Z]{25}\z/
  @draft_result_fields ~w[draft_definition_sha256 draft_live_version]a

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
    |> validate_length(:action_id, max: 255, count: :codepoints)
    |> validate_length(:pack_ref, max: 255, count: :codepoints)
    |> validate_length(:resource_ref, max: 255, count: :codepoints)
    |> unique_constraint([:account_id, :credential_lineage_id, :operation_id],
      name: :mcp_operations_lineage_operation_index
    )
    |> check_constraint(:tool, name: :mcp_operations_tool_shape)
    |> check_constraint(:operation_id, name: :mcp_operations_identity_bounds)
  end

  def complete_draft(%Operation{tool: tool, draft_definition_sha256: nil} = operation, attrs)
      when tool in [:create_runbook_draft, :update_runbook_draft] do
    operation
    |> cast(attrs, @draft_result_fields)
    |> validate_required([:draft_definition_sha256])
    |> validate_format(:draft_definition_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:draft_live_version, greater_than: 0)
    |> check_constraint(:draft_definition_sha256, name: :mcp_operations_draft_result_shape)
  end

  def complete_draft(%Operation{} = operation, _attrs) do
    operation
    |> change()
    |> add_error(:draft_definition_sha256, "requires an unfinished draft operation")
  end
end
