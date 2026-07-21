defmodule EmisarWeb.LLMsTxtTest do
  use EmisarWeb.ConnCase, async: true
  alias EmisarWeb.SitemapController

  @llms_path Path.expand("../../priv/static/llms.txt", __DIR__)

  test "GET /llms.txt serves the committed Markdown index as plain text" do
    conn = build_conn(:get, "/llms.txt") |> EmisarWeb.Endpoint.call([])

    assert response(conn, 200) == File.read!(@llms_path)
    assert get_resp_header(conn, "content-type") == ["text/plain"]
  end

  test "the index follows the llms.txt heading and summary structure" do
    body = File.read!(@llms_path)

    assert body =~ ~r/\A# emisar\n\n> [^\n]+\n/

    for heading <- ["Start here", "Build and operate", "Security", "Optional"] do
      assert body =~ "## #{heading}\n"
    end
  end

  test "every linked emisar page is public, canonical, and live", %{conn: conn} do
    body = File.read!(@llms_path)

    links =
      ~r{\]\((https://emisar\.dev[^)]+)\)}
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()

    assert links != []

    sitemap_paths = MapSet.new(SitemapController.paths())

    for link <- links do
      uri = URI.parse(link)

      assert uri.scheme == "https"
      assert uri.host == "emisar.dev"
      assert MapSet.member?(sitemap_paths, uri.path), "llms.txt links a non-sitemap path: #{link}"
      assert conn |> get(uri.path) |> response(200)
    end
  end
end
