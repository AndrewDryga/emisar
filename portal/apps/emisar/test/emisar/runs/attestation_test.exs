defmodule Emisar.Runs.AttestationTest do
  use ExUnit.Case, async: true
  alias Emisar.Crypto
  alias Emisar.Runs.Attestation

  @operation_id "op_724NN9NMDZ1T76NARWCKM5A0D6"
  @runner_refs [
    "db-a~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "db-b~bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  ]
  @args_raw ~s({ "job_id": 9007199254740993, "ratio": 1e3 })

  describe "validate/2" do
    test "accepts a bounded v4 envelope whose every relayed fact matches" do
      envelope = envelope()

      assert {:ok, attestation} = Attestation.validate([encode(envelope)], facts())
      assert Attestation.envelope(attestation) == envelope
    end

    test "absence remains valid for a runner that does not enforce signatures" do
      assert {:ok, nil} = Attestation.validate([], facts())
    end

    test "rejects every relayed fact that disagrees with the call" do
      for {field, changed} <- [
            {"portal_origin", "https://other.example"},
            {"action_id", "db.resume"},
            {"pack_ref", "db@2/sha256:" <> String.duplicate("a", 64)},
            {"args_sha256", String.duplicate("f", 64)},
            {"runner_refs", tl(@runner_refs)},
            {"reason", "something else"},
            {"operation_id", "op_00000000000000000000000000"},
            {"tool", "execute_runbook"},
            {"version", "emisar-attestation-v3"}
          ] do
        header = encode(Map.put(envelope(), field, changed))
        assert Attestation.validate([header], facts()) == {:error, :invalid_attestation}
      end
    end

    test "rejects an args hash taken over anything but the exact argument bytes" do
      header =
        encode(
          Map.put(envelope(), "args_sha256", Crypto.hash_hex(~s({"job_id":9007199254740992})))
        )

      assert Attestation.validate([header], facts()) == {:error, :invalid_attestation}
    end

    test "rejects a duplicate key at the top level and nested in the certificate" do
      top_level =
        String.replace(
          Jason.encode!(envelope()),
          ~s("version":"emisar-attestation-v4"),
          ~s("version":"emisar-attestation-v4","version":"emisar-attestation-v4")
        )

      nested =
        String.replace(
          Jason.encode!(envelope()),
          ~s("ca_id":"customer-ca"),
          ~s("ca_id":"customer-ca","ca_id":"attacker-ca")
        )

      for raw <- [top_level, nested] do
        header = Base.url_encode64(raw, padding: false)
        assert Attestation.validate([header], facts()) == {:error, :invalid_attestation}
      end
    end

    test "rejects unknown, missing, and malformed envelope fields" do
      malformed = [
        Map.put(envelope(), "extra", true),
        Map.delete(envelope(), "nonce"),
        Map.put(envelope(), "runner_refs", Enum.reverse(@runner_refs)),
        Map.put(envelope(), "runner_refs", @runner_refs ++ @runner_refs),
        Map.put(envelope(), "runner_refs", []),
        Map.put(envelope(), "sig", String.duplicate("F", 128)),
        Map.put(envelope(), "nonce", String.duplicate("2", 31)),
        Map.put(envelope(), "issued_at", "yesterday"),
        Map.put(envelope(), "reason", String.duplicate("x", 256)),
        Map.put(envelope(), "cert", "customer-ca"),
        put_in(envelope(), ["cert", "valid_until"], "soon"),
        put_in(envelope(), ["cert", "public_key"], String.duplicate("3", 63)),
        put_in(envelope(), ["cert", "scope"], %{"group" => "db", "team" => "dba"}),
        put_in(envelope(), ["cert", "scope", "labels"], %{"env" => 1})
      ]

      for envelope <- malformed do
        header = encode(envelope)
        assert Attestation.validate([header], facts()) == {:error, :invalid_attestation}
      end
    end

    test "rejects header ambiguity, oversize, and non-JSON payloads" do
      assert Attestation.validate(["a", "b"], facts()) == {:error, :invalid_attestation}
      assert Attestation.validate([""], facts()) == {:error, :invalid_attestation}

      assert Attestation.validate([String.duplicate("a", 8_193)], facts()) ==
               {:error, :invalid_attestation}

      assert Attestation.validate([Base.url_encode64("[]", padding: false)], facts()) ==
               {:error, :invalid_attestation}

      assert Attestation.validate([Jason.encode!(envelope())], facts()) ==
               {:error, :invalid_attestation}
    end
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
