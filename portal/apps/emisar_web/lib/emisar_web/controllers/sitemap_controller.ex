defmodule EmisarWeb.SitemapController do
  @moduledoc """
  GET /sitemap.xml — the marketing + docs surface only. App/auth
  routes are disallowed in robots.txt and not listed here.
  """
  use EmisarWeb, :controller

  @base "https://emisar.com"

  @paths [
    "/",
    "/about",
    "/pricing",
    "/security",
    "/privacy",
    "/terms",
    "/docs",
    "/docs/quickstart",
    "/docs/action-packs",
    "/docs/security-model",
    "/docs/connect-an-llm",
    "/use-cases/cassandra-ops",
    "/use-cases/postgres-ops",
    "/compare/raw-ssh-for-ai"
  ]

  def show(conn, _params) do
    today = Date.utc_today() |> Date.to_iso8601()

    urls =
      Enum.map(@paths, fn path ->
        """
          <url>
            <loc>#{@base}#{path}</loc>
            <lastmod>#{today}</lastmod>
            <changefreq>weekly</changefreq>
          </url>\
        """
      end)
      |> Enum.join("\n")

    body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{urls}
    </urlset>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end
end
