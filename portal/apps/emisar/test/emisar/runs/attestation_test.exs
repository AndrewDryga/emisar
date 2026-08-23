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
    test "accepts a bounded v5 envelope whose every relayed fact matches" do
      envelope = envelope()

      assert {:ok, attestation} = Attestation.validate([encode(envelope)], facts())
      assert Attestation.envelope(attestation) == envelope
    end

    test "absence remains valid for a runner that does not enforce signatures" do
      assert Attestation.validate([], facts()) == {:ok, nil}
    end

    test "rejects every relayed fact that disagrees with the call" do
      for {field, changed} <- [
            {"portal_origin", "https://other.example"},
            {"action_id", "db.resume"},
            {"pack_ref", "db@2/sha256:" <> String.duplicate("a", 64)},
            {"args_sha256", String.duplicate("f", 64)},
            {"runner_refs", tl(@runner_refs)},
            {"reason", "something else"},
            {"evidence_sha256", String.duplicate("e", 64)},
            {"expected_sha256", String.duplicate("d", 64)},
            {"operation_id", "op_00000000000000000000000000"},
            {"tool", "execute_runbook"},
            {"version", "emisar-attestation-v3"}
          ] do
        header = encode(Map.put(envelope(), field, changed))
        assert Attestation.validate([header], facts()) == {:error, :invalid_attestation}
      end
    end

    # The point of binding the narrative. A control plane cannot change WHAT runs
    # — that was already signed — but until v5 it could rewrite WHY an action
    # appears to be running, which is the text a human approver decides on.
    test "rejects a rewritten approver narrative" do
      rewritten = %{facts() | evidence: "routine maintenance, nothing unusual"}

      assert Attestation.validate([encode(envelope())], rewritten) ==
               {:error, :invalid_attestation}

      restated = %{facts() | expected: "no impact at all"}

      assert Attestation.validate([encode(envelope())], restated) ==
               {:error, :invalid_attestation}
    end

    # The load-bearing half: an ABSENT field still hashes, so a control plane
    # cannot invent a justification for an action the caller never justified.
    test "rejects evidence added to a call that carried none" do
      unjustified = %{facts() | evidence: nil, expected: nil}
      {:ok, signed} = Attestation.validate([encode(envelope_without_narrative())], unjustified)
      assert signed

      invented = %{unjustified | evidence: "the operator asked for this"}

      assert Attestation.validate([encode(envelope_without_narrative())], invented) ==
               {:error, :invalid_attestation}
    end

    test "rejects an args hash taken over anything but the exact argument bytes" do
      header =
        encode(
          Map.put(envelope(), "args_sha256", Crypto.hash_hex(~s({"job_id":9007199254740992})))
        )

      assert Attestation.validate([header], facts()) == {:error, :invalid_attestation}
    end

    test "rejects a duplicate key at the top level and nested in the arguments" do
      top_level =
        String.replace(
          Jason.encode!(envelope()),
          ~s("version":"emisar-attestation-v5"),
          ~s("version":"emisar-attestation-v5","version":"emisar-attestation-v5")
        )

      nested =
        String.replace(
          Jason.encode!(envelope()),
          ~s("nonce":"#{String.duplicate("2", 32)}"),
          ~s("nonce":"#{String.duplicate("2", 32)}","nonce":"#{String.duplicate("9", 32)}")
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
        # Odd-length and out-of-range signatures: the bound spans Ed25519's
        # exact 64 bytes and ECDSA P-256's variable ASN.1 length, and nothing
        # outside it.
        Map.put(envelope(), "sig", String.duplicate("1", 127)),
        Map.put(envelope(), "sig", String.duplicate("1", 126)),
        Map.put(envelope(), "sig", String.duplicate("1", 162)),
        Map.put(envelope(), "nonce", String.duplicate("2", 31)),
        Map.put(envelope(), "issued_at", "yesterday"),
        Map.put(envelope(), "reason", String.duplicate("x", 256)),
        Map.put(envelope(), "cert_chain", "not-a-list"),
        Map.put(envelope(), "cert_chain", []),
        Map.put(envelope(), "cert_chain", ["not base64!"]),
        Map.put(envelope(), "cert_chain", [
          Base.encode64("a"),
          Base.encode64("b"),
          Base.encode64("c")
        ]),
        Map.put(envelope(), "cert_chain", [String.duplicate("A", 8_193)])
      ]

      for envelope <- malformed do
        header = encode(envelope)
        assert Attestation.validate([header], facts()) == {:error, :invalid_attestation}
      end
    end

    test "rejects header ambiguity, oversize, and non-JSON payloads" do
      assert Attestation.validate(["a", "b"], facts()) == {:error, :invalid_attestation}
      assert Attestation.validate([""], facts()) == {:error, :invalid_attestation}

      assert Attestation.validate([String.duplicate("a", 16_385)], facts()) ==
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
      evidence: "grafana shows p99 at 40s since 12:10Z",
      expected: "writes pause for under a minute",
      operation_id: @operation_id,
      portal_origin: "https://emisar.example"
    }
  end

  defp envelope_without_narrative do
    %{
      envelope()
      | "evidence_sha256" => Crypto.hash_hex(""),
        "expected_sha256" => Crypto.hash_hex("")
    }
  end

  defp envelope do
    %{
      "version" => "emisar-attestation-v5",
      "tool" => "run_action",
      "portal_origin" => "https://emisar.example",
      "action_id" => "db.pause",
      "pack_ref" => "db@1/sha256:" <> String.duplicate("a", 64),
      "args_sha256" => Crypto.hash_hex(@args_raw),
      "runner_refs" => @runner_refs,
      "reason" => "maintenance",
      "evidence_sha256" => Crypto.hash_hex("grafana shows p99 at 40s since 12:10Z"),
      "expected_sha256" => Crypto.hash_hex("writes pause for under a minute"),
      "operation_id" => @operation_id,
      "sig" => String.duplicate("1", 128),
      "nonce" => String.duplicate("2", 32),
      "issued_at" => "2026-07-14T12:00:00Z",
      # The chain is opaque here by design: the portal bounds and base64-checks
      # it, and the RUNNER is the only cryptographic authority for its trust,
      # profile, and scope.
      "cert_chain" => [Base.encode64("leaf-der-bytes")]
    }
  end

  defp encode(envelope), do: envelope |> Jason.encode!() |> Base.url_encode64(padding: false)
end
