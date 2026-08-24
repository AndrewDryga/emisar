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

    test "rejects credentials, query parameters, and fragments" do
      for issuer <- [
            "https://user:CLIENT_SECRET_SENTINEL@idp.test/tenant",
            "https://idp.test/tenant?access_token=TOKEN_SENTINEL",
            "https://idp.test/tenant#TOKEN_SENTINEL"
          ] do
        assert IssuerUrl.validate(issuer) == {:error, :invalid_issuer}
      end
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

  describe "validate_endpoint/1" do
    test "allows a cross-origin OAuth endpoint with fixed query parameters" do
      assert IssuerUrl.validate_endpoint(
               "https://tokens.other-idp.test/oauth/token?tenant=acme&version=2"
             ) == :ok
    end

    test "still rejects credentials, fragments, and private hosts" do
      assert IssuerUrl.validate_endpoint("https://user:secret@idp.test/token") ==
               {:error, :invalid_issuer}

      assert IssuerUrl.validate_endpoint("https://idp.test/token#fragment") ==
               {:error, :invalid_issuer}

      assert IssuerUrl.validate_endpoint("https://127.0.0.1/token?tenant=acme") ==
               {:error, :blocked_issuer}
    end
  end

  describe "address_allowed?/1" do
    test "refuses every special-purpose range, not just the well-known four" do
      # This was a denylist and grew holes: a public hostname resolving into
      # carrier NAT, benchmarking fabric or multicast was judged safe and dialled.
      # 100.100.100.200 is Alibaba's metadata endpoint, which the old list missed
      # entirely while blocking AWS's 169.254.169.254.
      for address <- [
            {0, 0, 0, 0},
            {10, 1, 1, 1},
            {100, 100, 100, 200},
            {127, 0, 0, 1},
            {169, 254, 169, 254},
            {172, 20, 1, 1},
            {192, 0, 0, 1},
            {192, 0, 2, 5},
            {192, 168, 1, 1},
            {198, 18, 0, 1},
            {198, 51, 100, 7},
            {203, 0, 113, 7},
            # The deprecated 6to4 relay anycast prefix, which IANA marks non-global.
            {192, 88, 99, 2},
            {224, 0, 0, 1},
            {255, 255, 255, 255}
          ] do
        refute IssuerUrl.address_allowed?(address), "#{:inet.ntoa(address)} was allowed"
      end
    end

    test "refuses IPv6 that is not global unicast, including the transition ranges" do
      # 6to4 and NAT64 both encode an IPv4 address, so a v6 literal can name
      # loopback or RFC-1918 without looking like it.
      for address <- [
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1},
            {0x64, 0xFF9B, 0, 0, 0, 0, 0x0A01, 0x0101},
            {0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 0},
            # The transition prefixes are refused OUTRIGHT, not judged by the IPv4
            # address they embed: IANA marks ::ffff:0:0/96 not globally reachable and
            # 2002::/16 indeterminate, so a public-looking inner address is not a
            # reason to dial them.
            {0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808},
            {0x2002, 0x0808, 0x0808, 0, 0, 0, 0, 1},
            {0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808},
            # IANA carves special-purpose prefixes out of 2000::/3, so allowing the
            # whole /3 let these through. 2001:db8::/32 sits OUTSIDE 2001::/23,
            # which is how it survived the first attempt.
            {0x2001, 0x0002, 0, 0, 0, 0, 0, 1},
            {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
            {0x2001, 0x0020, 0, 0, 0, 0, 0, 1},
            {0x3FFF, 0, 0, 0, 0, 0, 0, 1},
            {0x3FF0, 0, 0, 0, 0, 0, 0, 1},
            {0x3FFE, 0, 0, 0, 0, 0, 0, 1}
          ] do
        refute IssuerUrl.address_allowed?(address), "#{:inet.ntoa(address)} was allowed"
      end
    end

    test "allows ordinary public addresses" do
      assert IssuerUrl.address_allowed?({93, 184, 216, 34})
      assert IssuerUrl.address_allowed?({8, 8, 8, 8})
      assert IssuerUrl.address_allowed?({0x2606, 0x2800, 0, 0, 0, 0, 0, 1})
      assert IssuerUrl.address_allowed?({0x2A00, 0x1450, 0, 0, 0, 0, 0, 1})
      assert IssuerUrl.address_allowed?({0x2620, 0, 0, 0, 0, 0, 0, 1})
    end
  end
end
