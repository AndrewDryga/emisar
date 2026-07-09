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
    assert descriptor["title"] == "Emisar"
    assert descriptor["version"] == "0.23.0"

    assert descriptor["remotes"] == [
             %{
               "type" => "streamable-http",
               "url" => "https://emisar.dev/api/mcp/rpc"
             }
           ]
  end
end
