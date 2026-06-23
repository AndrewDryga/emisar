defmodule EmisarWeb.MarketingStructuralTest do
  @moduledoc """
  Per-page structural guarantees that hold across the whole indexable
  marketing surface — the lean-JS split, the self-referential canonical
  tag, junk-query-param resilience, BreadcrumbList structured data, and
  the title/OG head — asserted with one parametrized loop per family so a
  new page inherits the coverage by being added to `@indexable_routes`.

  Companion to `marketing_test.exs` (per-page copy + the CSP/indexable
  loop) and `js_bundle_test.exs` (the marketing-vs-app bundle split on a
  representative page); this file is the breadth pass over every page.
  """
  use EmisarWeb.ConnCase, async: true

  # The full public, server-rendered marketing surface — every route in
  # the :browser pipeline that deliberately skips :noindex (router.ex).
  # Mirrors `marketing_test.exs` @routes. Each is controller-rendered, so
  # each must load the lean bundle, carry a self-canonical, ignore junk
  # query params, and emit a complete <title>/OG head.
  @indexable_routes ~w(
    /
    /ai
    /pricing
    /security
    /docs
    /docs/quickstart
    /docs/action-packs
    /docs/security-model
    /docs/signed-dispatch
    /docs/connect-an-llm
    /docs/publishing-packs
    /docs/policies-and-approvals
    /docs/runbooks
    /docs/teams-and-access
    /docs/sso
    /docs/runners
    /docs/audit-and-siem
    /changelog
    /about
    /privacy
    /terms
    /refund-policy
    /packs
    /packs/postgres
    /packs/cassandra
    /use-cases
    /use-cases/cassandra-ops
    /use-cases/postgres-ops
    /use-cases/csi-data-loss
    /compare/raw-ssh-for-ai
    /compare/custom-mcp-server
    /zero-trust
    /how-it-works
    /trust
    /dpa
    /docs/mcp-reference
    /guides
    /guides/give-ai-agents-safe-production-access
  )

  # The pages that emit a BreadcrumbList block. Home / /ai / /pricing carry
  # bespoke JSON-LD graphs (Organization / SoftwareApplication / Product /
  # FAQPage) with NO breadcrumb, so they're excluded — asserting a tag a
  # page doesn't emit would be a false failure. Everything else (every
  # @pages-generated page + the use-cases hub + the packs + changelog pages)
  # derives a Home → [Docs →] page breadcrumb from its path.
  @breadcrumb_routes @indexable_routes -- ~w(/ /ai /pricing)

  # MarketingController GET routes that are NOT indexable HTML pages (feeds), so
  # they're excluded from the @indexable_routes parity guard below.
  @non_indexable_marketing ~w(/changelog.xml)

  describe "route coverage parity (no marketing page drifts out of the battery)" do
    # The structural battery only protects pages listed in @indexable_routes, and
    # that list is hand-synced with the router — so a page added to the router
    # without being added here would silently escape every check (exactly how
    # /dpa, /trust, /how-it-works, /docs/mcp-reference, /guides slipped through
    # until Phase-6 discovery). This guard fails the moment it happens again.
    test "every static marketing page is in @indexable_routes" do
      router_pages =
        EmisarWeb.Router.__routes__()
        |> Enum.filter(&(&1.verb == :get and &1.plug == EmisarWeb.MarketingController))
        |> Enum.map(& &1.path)
        |> Enum.reject(&(String.contains?(&1, ":") or &1 in @non_indexable_marketing))
        |> MapSet.new()

      missing = MapSet.difference(router_pages, MapSet.new(@indexable_routes))

      assert MapSet.size(missing) == 0,
             "marketing pages live in the router but are missing from @indexable_routes — add " <>
               "them so the structural + breadcrumb battery covers them: " <>
               inspect(Enum.sort(MapSet.to_list(missing)))
    end

    test "each dynamic marketing page family has a concrete representative covered" do
      for family <- ["/guides/", "/packs/"] do
        assert Enum.any?(@indexable_routes, &String.starts_with?(&1, family)),
               "no concrete #{family}:slug page in @indexable_routes — the structural battery " <>
                 "never exercises an individual #{family} page"
      end
    end
  end

  describe "UX & accessibility baseline on every marketing page" do
    # A visitor, a screen reader, and a crawler all need: exactly one h1 (heading
    # hierarchy), a skip-to-content link, a lang attribute, navigable chrome (nav +
    # footer), and alt text on every image. This is the testable UX/a11y floor — it
    # catches the regressions that hurt real users and SEO (not a substitute for
    # design review, which is the marketing loop's + ux-designer's domain).
    for route <- @indexable_routes do
      test "GET #{route} meets the UX/a11y baseline", %{conn: conn} do
        html = conn |> get(unquote(route)) |> html_response(200)

        h1s = length(String.split(html, "<h1")) - 1
        assert h1s == 1, "#{unquote(route)} has #{h1s} <h1> (need exactly one)"

        assert html =~ "#main-content", "#{unquote(route)}: no skip-to-content link"
        assert html =~ ~r/<html[^>]*\slang=/, "#{unquote(route)}: no <html lang=>"
        assert html =~ "<nav", "#{unquote(route)}: no <nav>"
        assert html =~ "<footer", "#{unquote(route)}: no <footer>"

        assert html =~ ~r/<meta[^>]+name="viewport"/,
               "#{unquote(route)}: no viewport meta (mobile)"

        imgs = List.flatten(Regex.scan(~r/<img\b[^>]*>/, html))
        without_alt = Enum.reject(imgs, &(&1 =~ ~r/\salt=/))

        assert without_alt == [],
               "#{unquote(route)}: <img> without alt (decorative → alt=\"\"): #{inspect(without_alt)}"
      end
    end
  end

  describe "lean JS bundle on every controller-rendered marketing page" do
    # The static marketing site has no LiveView socket, so it must load
    # only the lean `marketing.js` and never the full `app.js` (LiveSocket
    # + hooks + topbar it would never use). The split is driven by the
    # `@app_js?` assign, set on live renders and absent on controller
    # renders — so a regression that flipped a marketing page to a LiveView
    # (or wired app.js into the marketing branch) would surface here.
    #
    for route <- @indexable_routes do
      test "GET #{route} loads marketing.js and not app.js", %{conn: conn} do
        html = conn |> get(unquote(route)) |> html_response(200)
        assert html =~ "/assets/marketing.js", "missing marketing.js on #{unquote(route)}"
        refute html =~ "/assets/app.js"
      end
    end
  end

  describe "self-referential canonical on every indexable page" do
    # Every marketing action sets `canonical_url: @base <> path`, rendered
    # by root.html.heex as `<link rel="canonical" …>`. The canonical must
    # point at the page's OWN absolute https://emisar.dev URL — a wrong or
    # missing canonical would split or sink the page's ranking. `@base <>
    # path` means the expected href is exactly "https://emisar.dev" <>
    # route for the whole list (and "https://emisar.dev/" for "/").
    #
    for route <- @indexable_routes do
      test "GET #{route} emits a canonical pointing at its own URL", %{conn: conn} do
        html = conn |> get(unquote(route)) |> html_response(200)
        expected = "https://emisar.dev" <> unquote(route)

        assert html =~ ~s(<link rel="canonical" href="#{expected}">),
               "wrong/missing canonical on #{unquote(route)} (expected #{expected})"
      end
    end
  end

  describe "junk query params are ignored on every indexable page" do
    # Marketing actions read no params (`_params`), so a crawler's or an
    # ad-tracker's `?utm_source=…&foo=1` must render the identical 200 page
    # — not error, not vary the canonical. Asserting the canonical is
    # unchanged proves the same page shell rendered, not just any 200.
    #
    for route <- @indexable_routes do
      test "GET #{route}?utm_source=x&foo=1 renders the same 200 shell", %{conn: conn} do
        clean = conn |> get(unquote(route)) |> html_response(200)
        junked = conn |> get(unquote(route) <> "?utm_source=x&foo=1") |> html_response(200)

        expected = "https://emisar.dev" <> unquote(route)
        assert junked =~ ~s(<link rel="canonical" href="#{expected}">)
        # Same canonical AND same <title> ⇒ the same page, junk dropped.
        assert marketing_title(junked) == marketing_title(clean)
      end
    end
  end

  describe "BreadcrumbList structured data is valid where emitted" do
    # The crawlable site hierarchy. Every page that emits a breadcrumb
    # carries a parseable application/ld+json block whose @type is
    # "BreadcrumbList" with at least two ordered items (Home → page, or
    # Home → Docs → page for /docs/*). Parsing the JSON (not grepping the
    # string) is what proves it's valid structured data, not just the
    # literal token in some unrelated copy.
    #
    for route <- @breadcrumb_routes do
      test "GET #{route} carries a valid BreadcrumbList", %{conn: conn} do
        html = conn |> get(unquote(route)) |> html_response(200)
        breadcrumb = find_breadcrumb(html)

        assert breadcrumb, "no BreadcrumbList JSON-LD on #{unquote(route)}"
        items = breadcrumb["itemListElement"]

        assert is_list(items) and length(items) >= 2,
               "BreadcrumbList on #{unquote(route)} needs >= 2 items, got #{inspect(items)}"

        # First crumb is always Home; positions are 1-based and ordered.
        assert hd(items)["name"] == "Home"
        positions = Enum.map(items, & &1["position"])
        assert positions == Enum.to_list(1..length(items))
      end
    end
  end

  describe "title + OpenGraph head on every indexable page" do
    # Every page needs a non-empty <title> (so it's not "Untitled" in a
    # SERP or a browser tab) and the og:title/og:description pair the root
    # layout fills from page_title/meta_description (so a shared link
    # unfurls with real text, not the bare domain). All three are
    # layout-level, so this loop is the breadth backstop for the whole
    # surface; the legal pages' exact titles are pinned separately below.
    for route <- @indexable_routes do
      test "GET #{route} has a non-empty <title> and OG title/description", %{conn: conn} do
        html = conn |> get(unquote(route)) |> html_response(200)

        title = marketing_title(html)
        assert is_binary(title) and String.trim(title) != "", "empty <title> on #{unquote(route)}"
        # The suffix proves it's the marketing head, not a stray <title>.
        assert title =~ "· emisar"

        assert html =~ ~s(property="og:title")
        assert html =~ ~s(property="og:description")
      end
    end

    # The three legal pages render through the shared `legal_page/1` and
    # set a distinct page_title + canonical each. Pinning the exact pair
    # guards against a copy/canonical mix-up between the three near-identical
    # pages (a wrong canonical on /terms pointing at /privacy, say).
    #
    test "legal pages render their exact title + own canonical", %{conn: conn} do
      for {route, title} <- [
            {"/privacy", "Privacy Policy"},
            {"/terms", "Terms of Service"},
            {"/refund-policy", "Refund Policy"}
          ] do
        html = conn |> get(route) |> html_response(200)

        assert marketing_title(html) =~ "#{title} · emisar", "wrong legal title on #{route}"
        assert html =~ ~s(<link rel="canonical" href="https://emisar.dev#{route}">)
      end
    end
  end

  # The rendered <title>, with surrounding/embedded whitespace collapsed —
  # `.live_title` wraps the title and the suffix across lines. (Named to
  # avoid the `Phoenix.LiveViewTest.page_title/1` import — that one runs the
  # text through Floki; the regex here keeps the literal suffix to assert.)
  defp marketing_title(html) do
    case Regex.run(~r{<title[^>]*>(.*?)</title>}s, html, capture: :all_but_first) do
      [title] -> title |> String.split() |> Enum.join(" ")
      nil -> nil
    end
  end

  # Parse every application/ld+json block and return the first node whose
  # @type is "BreadcrumbList" — handling both the bare-object pages and the
  # `@graph`-array pages — or nil if none emits one.
  defp find_breadcrumb(html) do
    ~r{<script type="application/ld\+json"[^>]*>(.*?)</script>}s
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.flat_map(fn [raw] ->
      case raw |> String.trim() |> Jason.decode() do
        {:ok, %{"@graph" => graph}} when is_list(graph) -> graph
        {:ok, %{} = node} -> [node]
        _ -> []
      end
    end)
    |> Enum.find(&(&1["@type"] == "BreadcrumbList"))
  end
end
