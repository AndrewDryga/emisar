defmodule EmisarWeb.MCP.ActionContractRef do
  @moduledoc """
  Issues the short-lived proof that one credential lineage obtained an action contract.

  The receipt binds only the immutable action identity. Runner compatibility is
  mutable discovery data and remains authoritative at dispatch preflight.
  """

  alias Emisar.Crypto

  @salt "mcp-action-contract-ref-v1"
  @max_age_seconds 900
  @max_ref_bytes 4_096

  @doc "Signs one action-contract receipt for the authenticated credential lineage."
  @spec issue(map(), map(), String.t(), String.t()) :: String.t()
  def issue(subject, api_key, action_id, pack_ref) do
    Phoenix.Token.sign(
      EmisarWeb.Endpoint,
      @salt,
      claims(subject, api_key, action_id, pack_ref)
    )
  end

  @type rejection_reason :: :claims_mismatch | :expired | :invalid

  @doc "Verifies an action-contract receipt and returns only a bounded internal reason."
  @spec verify(map(), map(), term(), String.t(), String.t()) ::
          :ok | {:error, rejection_reason()}
  def verify(subject, api_key, contract_ref, action_id, pack_ref)
      when is_binary(contract_ref) and byte_size(contract_ref) <= @max_ref_bytes do
    expected = claims(subject, api_key, action_id, pack_ref)

    case Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, contract_ref, max_age: @max_age_seconds) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :claims_mismatch}
      {:error, :expired} -> {:error, :expired}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  def verify(_subject, _api_key, _contract_ref, _action_id, _pack_ref),
    do: {:error, :invalid}

  defp claims(subject, api_key, action_id, pack_ref) do
    %{
      "v" => 1,
      "subject_ref" => subject_ref(subject, api_key),
      "action_id" => action_id,
      "pack_ref" => pack_ref
    }
  end

  defp subject_ref(subject, api_key) do
    Crypto.hash_hex(
      "mcp-action-contract-subject-v1\0" <>
        subject.account.id <> "\0" <> api_key.credential_lineage_id
    )
  end
end
