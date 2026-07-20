defmodule EmisarWeb.MCP.ActionContractRefTest do
  use ExUnit.Case, async: true
  alias Emisar.Crypto
  alias EmisarWeb.MCP.ActionContractRef

  @salt "mcp-action-contract-ref-v1"
  @action_id "database.pause_job"
  @pack_ref "database@1.0.0/sha256:" <> String.duplicate("a", 64)

  test "binds the account, credential lineage, action, and immutable pack" do
    subject = subject("account-a")
    key = key("lineage-a")
    ref = ActionContractRef.issue(subject, key, @action_id, @pack_ref)

    assert :ok = ActionContractRef.verify(subject, key, ref, @action_id, @pack_ref)
    assert :ok = ActionContractRef.verify(subject, key("lineage-a"), ref, @action_id, @pack_ref)

    for {other_subject, other_key, action_id, pack_ref} <- [
          {subject("account-b"), key, @action_id, @pack_ref},
          {subject, key("lineage-b"), @action_id, @pack_ref},
          {subject, key, "database.resume_job", @pack_ref},
          {subject, key, @action_id, "database@1.0.1/sha256:" <> String.duplicate("b", 64)}
        ] do
      assert {:error, :claims_mismatch} =
               ActionContractRef.verify(other_subject, other_key, ref, action_id, pack_ref)
    end
  end

  test "rejects expired, altered, unknown, and oversized receipts" do
    subject = subject("account-a")
    key = key("lineage-a")
    claims = claims(subject, key, @action_id, @pack_ref)

    expired =
      Phoenix.Token.sign(EmisarWeb.Endpoint, @salt, claims,
        signed_at: System.system_time(:second) - 901
      )

    unknown =
      Phoenix.Token.sign(EmisarWeb.Endpoint, @salt, Map.put(claims, "v", 2))

    valid = ActionContractRef.issue(subject, key, @action_id, @pack_ref)
    altered = valid <> "x"

    assert {:error, :expired} =
             ActionContractRef.verify(subject, key, expired, @action_id, @pack_ref)

    assert {:error, :claims_mismatch} =
             ActionContractRef.verify(subject, key, unknown, @action_id, @pack_ref)

    assert {:error, :invalid} =
             ActionContractRef.verify(subject, key, altered, @action_id, @pack_ref)

    for ref <- [String.duplicate("x", 4_097), nil] do
      assert {:error, :invalid} =
               ActionContractRef.verify(subject, key, ref, @action_id, @pack_ref)
    end
  end

  defp subject(account_id), do: %{account: %{id: account_id}}
  defp key(lineage_id), do: %{credential_lineage_id: lineage_id}

  defp claims(subject, key, action_id, pack_ref) do
    %{
      "v" => 1,
      "subject_ref" =>
        Crypto.hash_hex(
          "mcp-action-contract-subject-v1\0" <>
            subject.account.id <> "\0" <> key.credential_lineage_id
        ),
      "action_id" => action_id,
      "pack_ref" => pack_ref
    }
  end
end
