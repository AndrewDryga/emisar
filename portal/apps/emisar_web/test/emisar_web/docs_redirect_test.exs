defmodule EmisarWeb.DocsRedirectTest do
  use EmisarWeb.ConnCase, async: true

  @moved_pages %{
    "/guides/caddy-reload-demo" => "/docs/investigate-a-service",
    "/docs/deployment" => "/docs/production",
    "/docs/connect-a-cli-client" => "/docs/connect-cli-agent",
    "/docs/upgrades" => "/docs/runner-upgrades"
  }

  test "retired documentation URLs redirect once to a canonical page", %{conn: conn} do
    for {source, destination} <- @moved_pages do
      response = conn |> recycle() |> get(source)
      assert redirected_to(response, :moved_permanently) == destination

      html = conn |> recycle() |> get(destination) |> html_response(200)
      assert html =~ ~s(<link rel="canonical" href="https://emisar.dev#{destination}">)
    end
  end

  test "query parameters cannot select a redirect destination", %{conn: conn} do
    for {source, destination} <- @moved_pages do
      response = conn |> recycle() |> get(source, %{"next" => "https://example.invalid/"})
      assert redirected_to(response, :moved_permanently) == destination
    end
  end

  test "discovery surfaces publish canonical documentation URLs", %{conn: conn} do
    for source <- ["/docs", "/sitemap.xml"] do
      body = conn |> recycle() |> get(source) |> response(200)

      for {retired, canonical} <- @moved_pages do
        refute body =~ retired
        assert body =~ canonical
      end
    end
  end

  test "the guide index omits the consolidated Caddy guide", %{conn: conn} do
    body = conn |> get("/guides") |> html_response(200)
    refute body =~ "/guides/caddy-reload-demo"
  end

  test "the curated agent guide does not advertise retired URLs", %{conn: conn} do
    body = conn |> get("/llms.txt") |> response(200)
    for retired <- Map.keys(@moved_pages), do: refute(body =~ retired)
  end

  test "removed case studies and unknown docs do not redirect to unrelated content", %{conn: conn} do
    for path <- [
          "/use-cases/cassandra-ops",
          "/use-cases/postgres-ops",
          "/docs/no-such-guide"
        ] do
      response = conn |> recycle() |> get(path)
      assert response.status == 404
      assert get_resp_header(response, "location") == []
    end
  end
end
