defmodule EmisarWeb.MarketingLinkingTest do
  @moduledoc """
  No public marketing page may be an orphan: every page in the sitemap must be
  linked (as an internal href) from at least one other page, so users and
  crawlers can actually reach it. Catches the failure mode of adding a page to
  the router + sitemap but forgetting to link it anywhere.

  The path list is DERIVED from `SitemapController.paths/0` + the pack registry —
  the same source the sitemap itself uses — so a newly-added page (a doc, a
  guide article, a pack) is automatically required to be reachable. The old
  hand-maintained allow-list silently skipped /docs/*, /guides/*, and /packs/*,
  which let a real orphan ship green.
  """
  use EmisarWeb.ConnCase, async: true
  alias EmisarWeb.{PacksRegistry, SitemapController}

  # The pages we crawl for outbound links — the static hubs (nav, footer, the
  # /packs grid, the /guides + /docs indexes). Their union of hrefs is the link
  # graph; the leaf pack-detail pages don't need crawling (they're link targets,
  # not hubs).
  defp hub_paths, do: SitemapController.paths()

  defp all_public_paths do
    pack_paths = Enum.map(PacksRegistry.list(), &"/packs/#{&1.id}")
    SitemapController.paths() ++ pack_paths
  end

  defp links_across_pages(conn, paths) do
    paths
    |> Enum.flat_map(fn path ->
      html = conn |> get(path) |> html_response(200)

      ~r/href="(\/[^"#?]*)/
      |> Regex.scan(html)
      |> Enum.map(fn [_, href] -> href end)
    end)
    |> MapSet.new()
  end

  test "every page in the sitemap is reachable from another page (no orphans)", %{conn: conn} do
    linked = links_across_pages(conn, hub_paths())

    # Every public path except the home root must appear as a link somewhere —
    # including every doc, both guide articles, and every pack-detail page.
    orphans = Enum.reject(all_public_paths() -- ["/"], &MapSet.member?(linked, &1))

    assert orphans == [],
           "orphan pages (in the sitemap but linked from nowhere): #{inspect(orphans)}"
  end

  test "the cornerstone guides are linked from product pages, not just the /guides index",
       %{conn: conn} do
    # SEO equity: the long-form guides are the organic ranking surface, so they
    # must draw links from high-authority product pages — not sit one click deep
    # behind /guides alone. Assert each is linked from a page other than /guides.
    guides = ~w(
      /guides/give-ai-agents-safe-production-access
      /guides/ai-agents-and-ssh-the-risks
    )

    sources = hub_paths() -- ["/guides"]

    for guide <- guides do
      linkers =
        Enum.filter(sources, fn from ->
          conn |> get(from) |> html_response(200) |> String.contains?(~s(href="#{guide}"))
        end)

      assert linkers != [],
             "#{guide} is only reachable from /guides — give it an inbound link from a product page"
    end
  end
end
