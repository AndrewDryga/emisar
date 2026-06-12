defmodule EmisarWeb.SitemapController do
  @moduledoc """
  GET /sitemap.xml — the marketing + docs surface only. App/auth
  routes are disallowed in robots.txt and not listed here.
  """
  use EmisarWeb, :controller

  @base "https://emisar.dev"

  @paths [
    "/",
    "/about",
    "/changelog",
    "/pricing",
    "/security",
    "/privacy",
    "/terms",
    "/refund-policy",
    "/docs",
    "/docs/quickstart",
    "/docs/action-packs",
    "/docs/publishing-packs",
    "/docs/policies-and-approvals",
    "/docs/runbooks",
    "/docs/teams-and-access",
    "/docs/runners",
    "/docs/audit-and-siem",
    "/docs/security-model",
    "/docs/connect-an-llm",
    "/packs",
    "/use-cases/cassandra-ops",
    "/use-cases/postgres-ops",
    "/use-cases/csi-data-loss",
    "/compare/raw-ssh-for-ai",
    "/compare/custom-mcp-server",
    "/zero-trust"
  ]

  def show(conn, _params) do
    # Static marketing routes + a synthesized entry per published pack
    # (so /packs/linux-core etc. show up in search engines without
    # having to hand-maintain a list here).
    pack_paths = Enum.map(EmisarWeb.PacksRegistry.list(), &"/packs/#{&1.id}")

    urls =
      Enum.map_join(@paths ++ pack_paths, "\n", fn path ->
        """
          <url>
            <loc>#{@base}#{path}</loc>
            <changefreq>weekly</changefreq>
          </url>\
        """
      end)

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
