defmodule EmisarWeb.UrlHelpersTest do
  use ExUnit.Case, async: true

  alias EmisarWeb.UrlHelpers

  describe "derive_base_url/1" do
    test "standard ports are elided" do
      assert UrlHelpers.derive_base_url(%{
               host_uri: %URI{scheme: "https", host: "emisar.dev", port: 443}
             }) == "https://emisar.dev"

      assert UrlHelpers.derive_base_url(%{
               host_uri: %URI{scheme: "http", host: "plain.example", port: 80}
             }) == "http://plain.example"
    end

    test "non-standard ports are kept (dev)" do
      assert UrlHelpers.derive_base_url(%{
               host_uri: %URI{scheme: "http", host: "localhost", port: 4000}
             }) == "http://localhost:4000"

      # 443 only pairs with https — an http listener on 443 keeps it.
      assert UrlHelpers.derive_base_url(%{
               host_uri: %URI{scheme: "http", host: "odd.example", port: 443}
             }) == "http://odd.example:443"
    end

    test "missing scheme defaults to http, missing port adds nothing" do
      assert UrlHelpers.derive_base_url(%{
               host_uri: %URI{scheme: nil, host: "bare.example", port: nil}
             }) == "http://bare.example"
    end

    test "a socket without a host_uri falls back to the production URL" do
      assert UrlHelpers.derive_base_url(%{host_uri: :not_mounted_at_router}) ==
               "https://emisar.dev"

      assert UrlHelpers.derive_base_url(%{}) == "https://emisar.dev"
    end
  end
end
