defmodule EmisarWeb.SitemapController do
  @moduledoc """
  GET /sitemap.xml — the marketing + docs surface only. App/auth
  routes are disallowed in robots.txt and not listed here.
  """
  use EmisarWeb, :controller
  alias Emisar.Catalog

  @base "https://emisar.dev"

  @paths [
    "/",
    "/about",
    "/changelog",
    "/pricing",
    "/support",
    "/security",
    "/privacy",
    "/terms",
    "/dpa",
    "/refund-policy",
    "/docs",
    "/packs",
    "/use-cases",
    "/use-cases/csi-data-loss",
    "/use-cases/ingress-502",
    "/compare/raw-ssh-for-ai",
    "/compare/custom-mcp-server",
    "/compare/copy-paste-ai-ops",
    "/zero-trust",
    "/trust",
    "/how-it-works",
    "/guides"
  ]

  @doc """
  The canonical marketing/docs paths: the static routes above, every page from
  the documentation navigation, and one entry per published guide. Deriving
  both collections prevents a new public page from being omitted here. This is
  also the source of truth for the no-orphan link test.
  """
  def paths do
    docs_paths = Enum.map(EmisarWeb.DocsNav.flat(), & &1.path)
    @paths ++ docs_paths ++ EmisarWeb.MarketingController.guide_paths()
  end

  def show(conn, _params) do
    # Static marketing routes + derived guide paths + a synthesized entry per
    # published pack (so /packs/linux-core etc. show up in search engines
    # without having to hand-maintain a list here).
    pack_paths = Enum.map(Catalog.list_published_packs(), &"/packs/#{&1.id}")

    urls =
      Enum.map_join(paths() ++ pack_paths, "\n", fn path ->
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
