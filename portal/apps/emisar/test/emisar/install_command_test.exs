defmodule Emisar.InstallCommandTest do
  use ExUnit.Case, async: true
  alias Emisar.InstallCommand

  test "HTTPS uses an HTTPS-only fetch and redirect policy" do
    assert {:ok, "https://emisar.dev", command} =
             InstallCommand.fetch("https://emisar.dev/", :runner)

    assert command ==
             "curl --proto '=https' --proto-redir '=https' --globoff -fsSL https://emisar.dev/install.sh"
  end

  test "local and private HTTP origins allow only an initial HTTP hop" do
    allowed = [
      "http://localhost:4000",
      "http://portal.localhost",
      "http://127.0.0.1",
      "http://127.255.255.255",
      "http://10.0.0.1",
      "http://172.16.0.1",
      "http://172.31.255.255",
      "http://192.168.0.1",
      "http://[::1]:4000",
      "http://[fc00::1]",
      "http://[fdff:ffff::1]"
    ]

    for base <- allowed do
      assert {:ok, ^base, command} = InstallCommand.fetch(base, :mcp)

      assert command ==
               "curl --proto '=http,https' --proto-redir '=https' --globoff -fsSL #{base}/install-mcp.sh"
    end
  end

  test "public, named, and non-private HTTP origins are refused" do
    refused = [
      "http://emisar.dev",
      "http://runners.internal:4000",
      "http://notlocalhost",
      "http://localhost.example",
      "http://0.0.0.0",
      "http://100.64.0.1",
      "http://169.254.169.254",
      "http://172.15.255.255",
      "http://172.32.0.0",
      "http://192.0.2.1",
      "http://224.0.0.1",
      "http://[fe80::1]",
      "http://[ff00::1]"
    ]

    for base <- refused do
      assert InstallCommand.fetch(base, :runner) == {:error, :insecure_base_url}
    end
  end

  test "alternate IPv4 spellings and non-origins are invalid" do
    invalid = [
      "http://127.1",
      "http://2130706433",
      "http://0x7f000001",
      "http://0177.0.0.1",
      "https://user:pass@emisar.dev",
      "https://emisar.dev/install",
      "https://emisar.dev//",
      "https://emisar.dev?x=1",
      "https://emisar.dev#fragment",
      "https://emisar.dev:99999",
      "file:///tmp/install.sh",
      "emisar.dev",
      "",
      nil
    ]

    for base <- invalid do
      assert InstallCommand.fetch(base, :runner) == {:error, :invalid_base_url}
    end
  end
end
