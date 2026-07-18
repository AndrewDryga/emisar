defmodule EmisarWeb.SitemapControllerTest do
  @moduledoc """
  The sitemap must stay in lockstep with the marketing site: every public
  marketing page listed, nothing stale. The parity test derives the expected
  set from the router (the same filter the structural battery uses), so a page
  added to the router without a sitemap entry — or removed while its entry
  lingers — fails here instead of silently hurting SEO.
  """
  use EmisarWeb.ConnCase, async: true
  alias EmisarWeb.{PacksRegistry, SitemapController}

  # Marketing GET routes that are deliberately NOT in the sitemap (feeds).
  @non_indexable ~w(/changelog.xml)

  test "GET /sitemap.xml lists every public path, including guides and packs", %{conn: conn} do
    xml = conn |> get(~p"/sitemap.xml") |> response(200)

    all_paths = SitemapController.paths() ++ Enum.map(PacksRegistry.list(), &"/packs/#{&1.id}")

    for path <- all_paths do
      assert xml =~ "<loc>https://emisar.dev#{path}</loc>",
             "sitemap.xml is missing #{path}"
    end
  end

  test "the sitemap and the router's static marketing pages are in exact parity" do
    router_pages =
      EmisarWeb.Router.__routes__()
      |> Enum.filter(&(&1.verb == :get and &1.plug == EmisarWeb.MarketingController))
      |> Enum.map(& &1.path)
      |> Enum.reject(&(String.contains?(&1, ":") or &1 in @non_indexable))
      |> MapSet.new()

    # paths/0 = the static list + per-guide entries derived from @guides; the
    # guide entries resolve through the dynamic /guides/:slug route, so only
    # the static remainder participates in the parity check.
    sitemap_static =
      SitemapController.paths()
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(EmisarWeb.MarketingController.guide_paths()))

    missing = MapSet.difference(router_pages, sitemap_static)

    assert MapSet.size(missing) == 0,
           "marketing pages missing from the sitemap: #{inspect(Enum.sort(missing))}"

    stale = MapSet.difference(sitemap_static, router_pages)

    assert MapSet.size(stale) == 0,
           "sitemap entries with no matching marketing route: #{inspect(Enum.sort(stale))}"
  end

  test "every derived guide path resolves to a live guide page", %{conn: conn} do
    for path <- EmisarWeb.MarketingController.guide_paths() do
      assert conn |> get(path) |> html_response(200)
    end
  end
end
