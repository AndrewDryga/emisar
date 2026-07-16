defmodule Emisar.MCPOperations do
  @moduledoc """
  Authorization and persistence boundary for MCP mutation identities.

  An operation belongs to one account and API-key rotation lineage. The fixed
  recovery snapshot is deliberately independent of current runner scope: scope
  can revoke future work without hiding whether an earlier mutation committed.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.{ApiKeys, Auth, Crypto, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.MCPOperations.{Authorizer, Operation}

  @crockford_alphabet "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    Supervisor.init([job_module("ReplayRetention")], strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  @doc """
  Derives the stable operation identity for a native MCP mutation request.

  The exact request body is bound to the authenticated credential lineage. An
  identical transport retry therefore reaches the same operation reservation,
  while a changed request or another lineage cannot collide with it. The ID is
  correlation metadata, not a capability.
  """
  def operation_id(request_body, %Subject{account: account, actor: %ApiKeys.ApiKey{} = key})
      when is_binary(request_body) do
    digest =
      [
        "emisar-native-mcp-operation-v1",
        account.id,
        key.credential_lineage_id,
        request_body
      ]
      |> Enum.join("\0")
      |> Crypto.hash()

    "op_" <> encode_operation_digest(binary_part(digest, 0, 16))
  end

  @doc """
  Adds an atomic operation reservation to `multi`.

  Requires the MCP operation reserve permission. The `:mcp_operation` result is
  `%{operation: operation, fresh?: boolean}`. An identical replay returns the
  winner; different facts under the same lineage-local ID abort with
  `:operation_conflict`.
  """
  def reserve_in_multi(
        %Multi{} = multi,
        attrs,
        %Subject{actor: %ApiKeys.ApiKey{} = key} = subject
      )
      when is_map(attrs) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.reserve_operations_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, key.account_id) do
      id = Repo.generate_id()

      operation_attrs =
        attrs
        |> Map.put(:id, id)
        |> Map.put(:account_id, subject.account.id)
        |> Map.put(:credential_lineage_id, key.credential_lineage_id)

      operation_changeset = Operation.Changeset.reserve(operation_attrs)

      multi =
        Multi.run(multi, :mcp_operation, fn repo, _changes ->
          reserve(repo, operation_changeset, operation_attrs, id)
        end)

      {:ok, multi}
    end
  end

  def reserve_in_multi(%Multi{}, _attrs, %Subject{}), do: {:error, :unauthorized}

  @doc """
  Fetches one minimal recovery record for the authenticated key lineage.

  Requires the MCP operation view permission. Missing, foreign-account, and
  other-lineage records all return `:not_found`.
  """
  def fetch_recovery(operation_id, %Subject{actor: %ApiKeys.ApiKey{} = key} = subject)
      when is_binary(operation_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_operations_permission()
           ) do
      Operation.Query.all()
      |> Operation.Query.by_operation_id(operation_id)
      |> Operation.Query.by_lineage_id(key.credential_lineage_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Operation.Query)
    end
  end

  def fetch_recovery(_operation_id, %Subject{}), do: {:error, :unauthorized}

  @doc """
  Fetches an exact committed mutation for replay.

  `:not_found` means the caller may proceed with current preflight and an atomic
  reservation. Reusing an existing identity with different immutable facts is
  always an operation conflict, even if mutable catalog state has since changed.
  """
  def fetch_matching_replay(%{operation_id: operation_id} = expected, %Subject{} = subject)
      when is_binary(operation_id) do
    with {:ok, operation} <- fetch_recovery(operation_id, subject) do
      if same_facts?(operation, expected),
        do: {:ok, operation},
        else: {:error, :operation_conflict}
    end
  end

  def fetch_matching_replay(_expected, %Subject{}), do: {:error, :not_found}

  @doc """
  Derives the stable UUID owned by one lineage-local resource operation.

  The operation registry and resource insert share this identity, so concurrent
  first attempts cannot disagree about which draft or execution won. This is an
  internal persistence identity, not a capability or authentication token.
  """
  def resource_id(operation_id, tool, %Subject{actor: %ApiKeys.ApiKey{} = key} = subject)
      when is_binary(operation_id) and tool in [:execute_runbook, :create_runbook_draft] do
    seed =
      Enum.join(
        [
          "emisar-mcp-resource-v1",
          subject.account.id,
          key.credential_lineage_id,
          Atom.to_string(tool),
          operation_id
        ],
        "\0"
      )

    hex = Emisar.Crypto.hash_hex(seed)

    String.slice(hex, 0, 8) <>
      "-" <>
      String.slice(hex, 8, 4) <>
      "-5" <>
      String.slice(hex, 13, 3) <>
      "-8" <>
      String.slice(hex, 17, 3) <>
      "-" <> String.slice(hex, 20, 12)
  end

  defp encode_operation_digest(<<value::unsigned-big-integer-size(128)>>) do
    {_remaining, encoded} =
      Enum.reduce(1..26, {value, []}, fn _index, {remaining, encoded} ->
        digit = rem(remaining, 32)
        character = binary_part(@crockford_alphabet, digit, 1)
        {div(remaining, 32), [character | encoded]}
      end)

    IO.iodata_to_binary(encoded)
  end

  defp reserve(repo, changeset, expected, id) do
    case repo.insert(changeset,
           on_conflict: [set: [updated_at: DateTime.utc_now()]],
           conflict_target: [:account_id, :credential_lineage_id, :operation_id],
           returning: true
         ) do
      {:ok, %Operation{id: ^id} = operation} ->
        {:ok, %{operation: operation, fresh?: true}}

      {:ok, %Operation{} = operation} ->
        if same_facts?(operation, expected),
          do: {:ok, %{operation: operation, fresh?: false}},
          else: {:error, :operation_conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp same_facts?(operation, expected) do
    Enum.all?(~w[tool fingerprint action_id pack_ref resource_id resource_ref]a, fn field ->
      Map.get(operation, field) == Map.get(expected, field)
    end)
  end
end
