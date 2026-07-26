defmodule Emisar.Fixtures.MCPOperations do
  @moduledoc """
  Bridge-operation test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.MCPOperations.create_operation/1`.
  """

  alias Emisar.{Fixtures, MCPOperations, Repo}

  def create_operation(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id

    base = %{
      id: Repo.generate_id(),
      account_id: account_id,
      credential_lineage_id: Ecto.UUID.generate(),
      operation_id: "op_724NN9NMDZ1T76NARWCKM5A0D6",
      tool: :run_action,
      fingerprint: String.duplicate("a", 64),
      action_id: "restart-service",
      pack_ref: "linux-core@1.0.0/sha256:" <> String.duplicate("b", 64)
    }

    attrs = Map.merge(base, attrs)
    Repo.insert!(MCPOperations.Operation.Changeset.reserve(attrs))
  end
end
