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

    test "IPv6 literals are bracketed" do
      assert UrlHelpers.derive_base_url(%{
               host_uri: %URI{scheme: "http", host: "::1", port: 4000}
             }) == "http://[::1]:4000"

      assert UrlHelpers.derive_base_url(%Plug.Conn{
               scheme: :http,
               host: "fc00::1",
               port: 4000
             }) == "http://[fc00::1]:4000"
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

  describe "mcp_install_command/1" do
    test "the hosted portal keeps the minimal command" do
      assert UrlHelpers.mcp_install_command("https://emisar.dev") ==
               {:ok,
                "curl --proto '=https' --proto-redir '=https' --globoff -fsSL https://emisar.dev/install-mcp.sh | sudo bash"}

      assert UrlHelpers.mcp_install_command("https://emisar.dev/") ==
               {:ok,
                "curl --proto '=https' --proto-redir '=https' --globoff -fsSL https://emisar.dev/install-mcp.sh | sudo bash"}
    end

    test "any other portal rides its base URL in as EMISAR_URL" do
      assert UrlHelpers.mcp_install_command("http://localhost:4000") ==
               {:ok,
                "curl --proto '=http,https' --proto-redir '=https' --globoff -fsSL http://localhost:4000/install-mcp.sh | sudo EMISAR_URL=http://localhost:4000 bash"}
    end

    test "public HTTP is refused" do
      assert UrlHelpers.mcp_install_command("http://emisar.dev") ==
               {:error, :insecure_base_url}
    end
  end
end
