defmodule EmisarWeb.MCP.AttestationTest do
  use ExUnit.Case, async: true
  alias Emisar.Crypto
  alias EmisarWeb.MCP.Attestation

  @operation_id "op_724NN9NMDZ1T76NARWCKM5A0D6"
  @runner_refs [
    "db-a~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "db-b~bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  ]
  @args_raw ~s({ "job_id": 9007199254740993, "ratio": 1e3 })

  test "accepts a bounded v4 envelope only when every relayed fact matches" do
    envelope = envelope()

    assert {:ok, ^envelope} = Attestation.extract([encode(envelope)], facts())

    for {field, changed} <- [
          {"portal_origin", "https://other.example"},
          {"action_id", "db.resume"},
          {"pack_ref", "db@2/sha256:" <> String.duplicate("a", 64)},
          {"args_sha256", String.duplicate("f", 64)},
          {"runner_refs", tl(@runner_refs)},
          {"reason", "something else"},
          {"operation_id", "op_00000000000000000000000000"}
        ] do
      assert {:error, :invalid_attestation} =
               Attestation.extract([encode(Map.put(envelope, field, changed))], facts())
    end
  end

  test "rejects duplicate fields, unknown fields, noncanonical targets, and header ambiguity" do
    raw = Jason.encode!(envelope())

    duplicate =
      String.replace(
        raw,
        ~s("version":"emisar-attestation-v4"),
        ~s("version":"emisar-attestation-v4","version":"emisar-attestation-v4")
      )

    assert {:error, :invalid_attestation} =
             Attestation.extract([Base.url_encode64(duplicate, padding: false)], facts())

    assert {:error, :invalid_attestation} =
             Attestation.extract([encode(Map.put(envelope(), "extra", true))], facts())

    assert {:error, :invalid_attestation} =
             Attestation.extract(
               [encode(Map.put(envelope(), "runner_refs", Enum.reverse(@runner_refs)))],
               facts()
             )

    assert {:error, :invalid_attestation} = Attestation.extract(["a", "b"], facts())

    assert {:error, :invalid_attestation} =
             Attestation.extract([String.duplicate("a", 8_193)], facts())
  end

  test "absence remains valid for a runner that does not enforce signatures" do
    assert {:ok, nil} = Attestation.extract([], facts())
  end

  defp facts do
    %{
      action_id: "db.pause",
      pack_ref: "db@1/sha256:" <> String.duplicate("a", 64),
      args_raw: @args_raw,
      runner_refs: Enum.reverse(@runner_refs),
      reason: "maintenance",
      operation_id: @operation_id,
      portal_origin: "https://emisar.example"
    }
  end

  defp envelope do
    %{
      "version" => "emisar-attestation-v4",
      "tool" => "run_action",
      "portal_origin" => "https://emisar.example",
      "action_id" => "db.pause",
      "pack_ref" => "db@1/sha256:" <> String.duplicate("a", 64),
      "args_sha256" => Crypto.hash_hex(@args_raw),
      "runner_refs" => @runner_refs,
      "reason" => "maintenance",
      "operation_id" => @operation_id,
      "sig" => String.duplicate("1", 128),
      "nonce" => String.duplicate("2", 32),
      "issued_at" => "2026-07-14T12:00:00Z",
      "cert" => %{
        "ca_id" => "customer-ca",
        "key_id" => "operator-key",
        "public_key" => String.duplicate("3", 64),
        "valid_from" => "2026-01-01T00:00:00Z",
        "valid_until" => "2027-01-01T00:00:00Z",
        "scope" => %{"group" => "db", "labels" => %{"env" => "prod"}},
        "serial" => "01J0CERT0000000000000000A",
        "sig" => String.duplicate("4", 128)
      }
    }
  end

  defp encode(envelope), do: envelope |> Jason.encode!() |> Base.url_encode64(padding: false)
end
