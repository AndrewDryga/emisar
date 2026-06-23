defmodule EmisarWeb.MarketingLinkingTest do
  @moduledoc """
  No public marketing page may be an orphan: every one must be linked (as an
  internal href) from at least one other marketing page, so users and crawlers
  can actually reach it. Catches the failure mode of adding a page to the
  router + sitemap but forgetting to link it anywhere (which happened to be a
  live risk while /demo, /trust, and /guides were being added).
  """
  use EmisarWeb.ConnCase, async: true

  @paths ~w(
    / /ai /use-cases /security /pricing /packs /docs /demo /trust /guides
    /how-it-works /about /changelog /privacy /terms /refund-policy /zero-trust
    /compare/raw-ssh-for-ai /compare/custom-mcp-server
  )

  test "every marketing page is reachable from another page (no orphans)", %{conn: conn} do
    # Collect every internal href (path only, query/fragment stripped) across
    # all pages — the union is the link graph.
    linked =
      @paths
      |> Enum.flat_map(fn path ->
        html = conn |> get(path) |> html_response(200)

        ~r/href="(\/[^"#?]*)/
        |> Regex.scan(html)
        |> Enum.map(fn [_, href] -> href end)
      end)
      |> MapSet.new()

    # Every path except the home root must appear as a link somewhere.
    orphans = Enum.reject(@paths -- ["/"], &MapSet.member?(linked, &1))

    assert orphans == [],
           "orphan marketing pages (in the router but linked from nowhere): #{inspect(orphans)}"
  end

  test "the new conversion + content pages are linked, not just routable", %{conn: conn} do
    # Belt-and-suspenders for the pages most likely to be left dangling.
    home = conn |> get(~p"/") |> html_response(200)
    footer_pages = ~w(/trust /guides /demo /changelog /packs)

    for path <- footer_pages do
      any_page_links? =
        Enum.any?(@paths, fn from ->
          conn |> get(from) |> html_response(200) |> String.contains?(~s(href="#{path}"))
        end)

      assert any_page_links?, "#{path} is not linked from any marketing page"
    end

    # /demo specifically must be reachable from the homepage's conversion path.
    assert home =~ ~s(href="/demo")
  end
end
