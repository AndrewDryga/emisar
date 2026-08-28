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
  # Derived from the router (plus pinned dynamic representatives) — a page
  # added there joins the structural + breadcrumb battery automatically.
  @indexable_routes EmisarWeb.MarketingRoutes.battery_paths()

  # The pages that emit a BreadcrumbList block. Home and /pricing carry
  # bespoke JSON-LD graphs (Organization / Product / FAQPage) with NO
  # breadcrumb, so they're excluded — asserting a tag a page doesn't emit
  # would be a false failure. Everything else (every @pages-generated page +
  # the use-cases hub + the packs + changelog pages) derives a
  # Home → [Docs →] page breadcrumb from its path.
  @breadcrumb_routes @indexable_routes -- ~w(/ /pricing)

  describe "UX & accessibility baseline on every marketing page" do
    # A visitor, a screen reader, and a crawler all need: exactly one h1 (heading
    # hierarchy), a skip-to-content link, a lang attribute, navigable chrome (nav +
    # footer), and alt text on every image. This is the testable UX/a11y floor — it
    # catches the regressions that hurt real users and SEO (not a substitute for
    # design review, which is the marketing loop's + design-ux's domain).
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

  describe "every referenced image resolves to a real file" do
    # A wrong image path still returns 200 — the page renders, the picture is
    # just missing — so nothing else in this suite catches it. A find/replace
    # over doc paths once rewrote four screenshot srcs into a directory that
    # does not exist, and every page stayed green.
    @static_root Application.app_dir(:emisar_web, "priv/static")

    for route <- @indexable_routes do
      test "GET #{route} references only images that exist", %{conn: conn} do
        html = conn |> get(unquote(route)) |> html_response(200)

        missing =
          ~r/<img\b[^>]*\ssrc="([^"]+)"/
          |> Regex.scan(html)
          |> Enum.map(fn [_, src] -> src end)
          |> Enum.filter(&String.starts_with?(&1, "/"))
          # `~p` appends a cache-busting query in some envs; the file is the path.
          |> Enum.map(&(&1 |> String.split("?") |> hd()))
          |> Enum.uniq()
          |> Enum.reject(&File.regular?(Path.join(@static_root, &1)))

        assert missing == [],
               "#{unquote(route)}: <img src> with no file in priv/static: #{inspect(missing)}"
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

  describe "install commands open on the visitor's platform" do
    # Every docs page that publishes an install/upgrade command carries one
    # tab per OS — Linux, Windows, macOS. Every spelling ships in the HTML;
    # the server marks the tab matching the request User-Agent and hides the
    # rest, so the switch is a convenience and never a gate.
    @os_switch_routes ~w(/docs/quickstart /docs/connect-cli-agent /docs/bridge-upgrades)

    @platform_uas [
      windows:
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
          "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      macos:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:121.0) Gecko/20100101 Firefox/121.0",
      linux:
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " <>
          "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ]

    test "each desktop OS lands on its own command", %{conn: conn} do
      for route <- @os_switch_routes, {platform, user_agent} <- @platform_uas do
        html =
          conn
          |> put_req_header("user-agent", user_agent)
          |> get(route)
          |> html_response(200)

        assert visible_os_variants(html) == [platform],
               "wrong default on #{route} for #{platform}"
      end
    end

    test "an unreadable User-Agent falls back to the Linux command", %{conn: conn} do
      html =
        conn
        |> put_req_header("user-agent", "curl/8.5.0")
        |> get("/docs/quickstart")
        |> html_response(200)

      assert visible_os_variants(html) == [:linux]
    end

    test "the hidden variants stay in the page for a crawler and a reader with no JS", %{
      conn: conn
    } do
      html =
        conn
        |> put_req_header("user-agent", @platform_uas[:windows])
        |> get("/docs/quickstart")
        |> html_response(200)

      assert html =~ "install-mcp.sh | sudo bash"
      assert html =~ "install-mcp.ps1"
    end

    # The variant a visitor actually sees: ALL ship, and the tabs the switch
    # did not pick wear `hidden`.
    defp visible_os_variants(html) do
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("pre[data-os]")
      |> Enum.reject(&String.contains?(one_attribute(&1, "class"), "hidden"))
      |> Enum.map(&String.to_existing_atom(one_attribute(&1, "data-os")))
      |> Enum.uniq()
    end

    defp one_attribute(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  end

  describe "docs page shell" do
    test "actionable console destinations are direct links", %{conn: conn} do
      links_by_page = [
        {"/docs/quickstart",
         [
           {"/app/runners/install", "Runners → Connect a runner"},
           {"/app/runners", "Runners"},
           {"/app/agents", "AI agents"}
         ]},
        {"/docs/connect-cli-agent",
         [{"/app/agents/connect", "Connect an agent"}, {"/app/audit", "Audit"}]},
        {"/docs/use-a-published-pack",
         [
           {"/app/packs", "Packs"},
           {"/app/runners", "Runners"},
           {"/app/audit", "Audit"}
         ]},
        {"/docs/run-an-action",
         [
           {"/app/runners", "Runners"},
           {"/app/approvals", "Approvals"},
           {"/app/audit", "Audit"}
         ]},
        {"/docs/host-install",
         [
           {"/app/runners/install", "Runners → Connect a runner"},
           {"/app/runners", "Runners"}
         ]},
        {"/docs/runner-fleet",
         [
           {"/app/runners/install", "Runners → Connect a runner"},
           {"/app/runners/keys", "Runners → Enrollment keys"},
           {"/app/runners", "Runners"}
         ]},
        {"/docs/runner-cli", [{"/app/runners", "Runners"}, {"/app/packs", "Packs"}]},
        {"/docs/autoscaling-fleets",
         [
           {"/app/runners/keys/new", "Runners → Enrollment keys → New key"},
           {"/app/runners", "Runners"}
         ]},
        {"/docs/credentials", [{"/app/agents", "Agents"}, {"/app/audit/export", "Audit export"}]},
        {"/docs/runner-credentials",
         [
           {"/app/runners/keys", "Runners → Enrollment keys"},
           {"/app/runners", "Runners"}
         ]},
        {"/docs/containers",
         [
           {"/app/runners/install", "Runners → Connect a runner"},
           {"/app/runners", "Runners"},
           {"/app/runners/keys/new", "reusable enrollment key"}
         ]},
        {"/docs/publishing-packs", [{"/app/packs", "Packs"}, {"/app/runners", "Runners"}]},
        {"/docs/pack-registry", [{"/app/packs", "Packs"}]},
        {"/docs/pack-updates", [{"/app/packs", "Packs"}, {"/app/audit", "Audit"}]},
        {"/docs/mcp-reference", [{"/app/packs", "Packs"}, {"/app/runbooks", "Runbooks"}]},
        {"/docs/agents-and-keys", [{"/app/agents", "AI agents"}]},
        {"/docs/billing", [{"/app/billing", "Billing"}, {"/app/billing", "Settings → Billing"}]},
        {"/docs/teams-and-access",
         [
           {"/app/team/invite", "Team → Invite"},
           {"/app/team", "Team"}
         ]},
        {"/docs/policies-and-approvals",
         [{"/app/policies", "Policies"}, {"/app/approvals", "Approvals"}]},
        {"/docs/audit-and-siem",
         [{"/app/audit", "Audit"}, {"/app/audit/export", "Audit export"}]},
        {"/docs/runbooks",
         [
           {"/app/runbooks", "Runbooks"},
           {"/app/runbooks/new", "New runbook"},
           {"/app/runbooks/import", "Import runbook"}
         ]},
        {"/docs/troubleshooting", [{"/app/runners", "Runners"}]},
        {"/docs/pack-updates", [{"/app/packs", "Packs"}]},
        {"/docs/connect-cli-agent", [{"/app/agents", "AI agents"}]},
        {"/docs/runs", [{"/app/runs", "Runs"}]},
        {"/docs/production",
         [{"/app/audit", "Audit"}, {"/app/audit/export", "audit-export token"}]},
        {"/docs/signed-dispatch", [{"/app/runners", "Runners"}]},
        {"/docs/runner-upgrades",
         [
           {"/app/runs", "Runs"},
           {"/app/runners", "Runners"},
           {"/app/audit", "Audit"},
           {"/app/packs", "Packs"}
         ]},
        {"/docs/scim", [{"/app/sso", "Team → Single sign-on"}]},
        {"/docs/integrations/keycloak", [{"/app/team", "Team"}]},
        {"/docs/integrations/google-workspace", [{"/app/team", "Team"}]},
        {"/docs/integrations/jumpcloud",
         [{"/app/team", "Team"}, {"/app/sso", "Team → Single sign-on"}]},
        {"/docs/security-incidents",
         [
           {"/app/agents", "AI agents"},
           {"/app/audit", "Audit"},
           {"/app/audit/export", "Audit export"},
           {"/app/runners/keys", "Runners → Enrollment keys"},
           {"/app/runners", "Runners"},
           {"/app/runs", "Runs"},
           {"/app/packs", "Packs"},
           {"/app/sso", "Team → Single sign-on"}
         ]}
      ]

      for {page, expected_links} <- links_by_page do
        html = conn |> recycle() |> get(page) |> html_response(200)

        for {href, label} <- expected_links do
          assert_link(html, page, href, label)
        end
      end
    end

    test "every docs TOC anchor resolves to a section id on its own page", %{conn: conn} do
      # `docs_layout` renders the "On this page" rail from the page's `toc`
      # list; an entry whose id has no matching heading scrolls nowhere. The
      # route list is DocsNav itself, so a new page inherits the check.
      for page <- EmisarWeb.DocsNav.flat() do
        html = conn |> get(page.path) |> html_response(200)

        anchors =
          ~r/data-toc-link="([^"]+)"/
          |> Regex.scan(html, capture: :all_but_first)
          |> List.flatten()

        for anchor <- anchors do
          assert html =~ ~s(id="#{anchor}"),
                 "#{page.path} TOC anchor ##{anchor} has no section id"
        end
      end
    end

    test "every docs page carries quiet review provenance without a dead edit action", %{
      conn: conn
    } do
      # Review provenance belongs to the shared docs colophon. Contribution
      # affordances do not: the public repository cannot accept the commit the
      # old GitHub edit flow promised.
      for page <- EmisarWeb.DocsNav.flat() do
        html = conn |> get(page.path) |> html_response(200)

        assert html =~ ~s(data-shot="docs-review-metadata"),
               "#{page.path}: no shared review colophon"

        assert html =~ ~s(aria-label="Document maintenance"),
               "#{page.path}: review colophon has no accessible label"

        assert html =~ "Last reviewed", "#{page.path}: no review date"
        refute html =~ "Suggest a change", "#{page.path}: dead edit action returned"

        refute html =~ "github.com/andrewdryga/emisar/edit/main/",
               "#{page.path}: dead GitHub edit URL returned"
      end
    end

    test "docs_layout requires the review date and carries no dead source-path API" do
      # Compilation is the real enforcement — a `<.docs_layout>` missing the
      # date fails the build. The old source path existed only to assemble an
      # unusable edit link, so pin its removal from the shared component API.
      attrs =
        EmisarWeb.DocsComponents.__components__()
        |> get_in([:docs_layout, :attrs])

      assert Enum.any?(attrs, &(&1.name == :updated and &1.required))
      refute Enum.any?(attrs, &(&1.name == :source_path))
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

  defp assert_link(html, page, href, label) do
    labels =
      ~r{<a\b[^>]*href="#{Regex.escape(href)}"[^>]*>(.*?)</a>}s
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [contents] ->
        contents
        |> String.replace(~r/<[^>]+>/, "")
        |> String.split()
        |> Enum.join(" ")
      end)

    assert Enum.any?(labels, &String.contains?(&1, label)),
           "#{page}: expected #{inspect(label)} to link directly to #{href}; found #{inspect(labels)}"
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

  describe "plan limits stated in prose" do
    # /docs/billing renders its table from Emisar.Billing, but four more pages
    # — two of them legal — state the Free limits as sentences. Deriving those
    # would let a plan-catalog edit silently rewrite the Terms, so they stay
    # hand-written and this pins them instead: change a limit and the wording
    # fails here, to be updated deliberately.
    test "the pages that spell the Free limits agree with the billing catalog", %{conn: conn} do
      free = Emisar.Billing.plan("free")
      runners = Integer.to_string(free.runners_limit)
      members = Integer.to_string(free.members_limit)
      retention = Integer.to_string(free.audit_retention_days)

      for {path, expected} <- [
            {"/about", ["Free forever for #{runners} runners."]},
            {"/terms", ["#{members} user, #{runners} runners, #{retention}-day audit retention"]},
            {"/privacy", ["#{retention} days of audit history"]},
            {"/refund-policy", ["#{members} user, #{runners} runners, #{retention}-day"]}
          ],
          claim <- expected do
        html = conn |> get(path) |> html_response(200)

        assert html =~ claim,
               "#{path} no longer states the Free plan's own limits: expected #{inspect(claim)}"
      end
    end
  end
end
