defmodule EmisarWeb.MCP.AttestationTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.Attestation

  defp valid_attestation(scope \\ %{}) do
    %{
      "version" => "emisar-attestation-v2",
      "sig" => "dispatch-signature",
      "nonce" => "nonce-1",
      "issued_at" => "2026-07-09T12:00:00Z",
      "targets" => ["runner-1"],
      "cert" => %{
        "ca_id" => "ca-acme",
        "key_id" => "operator-1",
        "public_key" => "ed25519-public-key",
        "valid_from" => "2026-07-09T00:00:00Z",
        "valid_until" => "2026-07-10T00:00:00Z",
        "serial" => "cert-1",
        "sig" => "certificate-signature",
        "scope" => scope
      }
    }
  end

  test "keeps the bounded runner trust envelope and drops unknown certificate fields" do
    attestation = put_in(valid_attestation(), ["cert", "untrusted"], "ignored")

    assert %{
             "sig" => "dispatch-signature",
             "cert" => %{"scope" => %{}, "ca_id" => "ca-acme"}
           } = Attestation.normalize(attestation)

    refute Map.has_key?(Attestation.normalize(attestation)["cert"], "untrusted")
  end

  test "rejects malformed envelopes and scopes" do
    assert Attestation.normalize(%{}) == nil
    assert Attestation.normalize("") == nil

    assert Attestation.normalize(
             put_in(valid_attestation(), ["cert", "scope"], %{"unknown" => "x"})
           ) == nil

    assert Attestation.normalize(
             put_in(valid_attestation(), ["cert", "scope"], %{"labels" => "bad"})
           ) == nil
  end

  test "rejects fields beyond the relay bound" do
    attestation = put_in(valid_attestation(), ["cert", "public_key"], String.duplicate("a", 513))
    assert Attestation.normalize(attestation) == nil
  end

  test "extract distinguishes an absent envelope from malformed supplied input" do
    assert Attestation.extract(%{}) == nil
    assert Attestation.extract(%{"attestation" => valid_attestation()}) == valid_attestation()
    assert Attestation.extract(%{"attestation" => %{}}) == :invalid
    assert Attestation.extract(%{"attestation" => nil}) == :invalid
  end
end
