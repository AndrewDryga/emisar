defmodule EmisarWeb.MCPRegistryTest do
  use EmisarWeb.ConnCase, async: true

  @repo_root Path.expand("../../..", File.cwd!())
  @auth_record_path Path.join(
                      @repo_root,
                      "portal/apps/emisar_web/priv/static/.well-known/mcp-registry-auth"
                    )

  test "GET /.well-known/mcp-registry-auth serves the committed domain proof" do
    conn = build_conn(:get, "/.well-known/mcp-registry-auth") |> EmisarWeb.Endpoint.call([])
    body = response(conn, 200)

    assert body == File.read!(@auth_record_path)
    assert body =~ ~r/^v=MCPv1; k=ed25519; p=[A-Za-z0-9+\/=]+\n$/
  end

  test "server.json declares the OAuth-protected remote MCP server" do
    descriptor = @repo_root |> Path.join("server.json") |> File.read!() |> Jason.decode!()

    assert descriptor["name"] == "dev.emisar/emisar"
    # Lowercase on purpose — the brand renders lowercase everywhere.
    assert descriptor["title"] == "emisar"

    assert descriptor["description"] ==
             "Governed MCP for real infrastructure actions — gated, approved, audited."

    assert String.length(descriptor["description"]) <= 100

    # The product line has ONE version source (portal/VERSION); server.json
    # rides it, and the publish workflow re-stamps it from the release tag.
    product_version = @repo_root |> Path.join("portal/VERSION") |> File.read!() |> String.trim()
    assert descriptor["version"] == product_version

    assert descriptor["remotes"] == [
             %{
               "type" => "streamable-http",
               "url" => "https://emisar.dev/api/mcp/rpc"
             }
           ]
  end
end
