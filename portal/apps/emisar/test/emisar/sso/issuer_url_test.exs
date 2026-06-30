defmodule Emisar.SSO.IssuerUrlTest do
  @moduledoc """
  The SSRF guard for operator-supplied OIDC issuers. The issuer is fetched
  (discovery + every login) from the portal's egress, so a private/loopback/
  metadata target must be rejected before any request leaves.
  """
  use ExUnit.Case, async: true
  alias Emisar.SSO.IssuerUrl

  describe "validate/1" do
    test "accepts a public https issuer, returning it unchanged" do
      assert IssuerUrl.validate("https://accounts.google.com") ==
               {:ok, "https://accounts.google.com"}

      assert IssuerUrl.validate("https://idp.test") == {:ok, "https://idp.test"}
    end

    test "accepts a public IP literal (v4 and v6)" do
      assert IssuerUrl.validate("https://8.8.8.8") == {:ok, "https://8.8.8.8"}

      assert IssuerUrl.validate("https://[2606:4700:4700::1111]") ==
               {:ok, "https://[2606:4700:4700::1111]"}
    end

    test "rejects a non-https scheme, a missing host, and a non-binary" do
      assert IssuerUrl.validate("http://idp.test") == {:error, :invalid_issuer}
      assert IssuerUrl.validate("ftp://idp.test") == {:error, :invalid_issuer}
      assert IssuerUrl.validate("not a url") == {:error, :invalid_issuer}
      assert IssuerUrl.validate("https://") == {:error, :invalid_issuer}
      assert IssuerUrl.validate(nil) == {:error, :invalid_issuer}
    end

    test "blocks loopback and localhost" do
      assert IssuerUrl.validate("https://127.0.0.1") == {:error, :blocked_issuer}
      assert IssuerUrl.validate("https://localhost") == {:error, :blocked_issuer}
      assert IssuerUrl.validate("https://db.localhost") == {:error, :blocked_issuer}
      assert IssuerUrl.validate("https://[::1]") == {:error, :blocked_issuer}
    end

    test "blocks the RFC-1918 private ranges" do
      assert IssuerUrl.validate("https://10.0.0.5") == {:error, :blocked_issuer}
      assert IssuerUrl.validate("https://172.20.1.1") == {:error, :blocked_issuer}
      assert IssuerUrl.validate("https://192.168.1.1") == {:error, :blocked_issuer}
    end

    test "blocks link-local and the cloud metadata endpoint" do
      assert IssuerUrl.validate("https://169.254.169.254") == {:error, :blocked_issuer}
      assert IssuerUrl.validate("https://0.0.0.0") == {:error, :blocked_issuer}
    end

    test "blocks IPv6 ULA, link-local, and IPv4-mapped private addresses" do
      assert IssuerUrl.validate("https://[fd00::1]") == {:error, :blocked_issuer}
      assert IssuerUrl.validate("https://[fe80::1]") == {:error, :blocked_issuer}
      # ::ffff:10.0.0.1 — a private v4 smuggled through a v6 literal.
      assert IssuerUrl.validate("https://[::ffff:10.0.0.1]") == {:error, :blocked_issuer}
    end
  end
end
