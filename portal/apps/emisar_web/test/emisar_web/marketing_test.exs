defmodule EmisarWeb.MarketingTest do
  use EmisarWeb.ConnCase, async: true

  @routes ~w(
    /
    /pricing
    /security
    /docs
    /docs/quickstart
    /docs/action-packs
    /docs/security-model
    /docs/connect-an-llm
    /docs/publishing-packs
    /changelog
    /about
    /privacy
    /terms
    /refund-policy
    /packs
    /packs/postgres
    /packs/cassandra
    /use-cases/cassandra-ops
    /use-cases/postgres-ops
    /compare/raw-ssh-for-ai
    /compare/custom-mcp-server
    /compare/slack-bots-for-ops
  )

  for route <- @routes do
    test "GET #{route} renders 200", %{conn: conn} do
      conn = get(conn, unquote(route))
      assert html_response(conn, 200)
    end
  end

  test "landing page mentions the positioning", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "emisar"
    assert html =~ "Sign in"
    assert html =~ "Start free"
    assert html =~ "pack trust"
    assert html =~ "source-available"
    refute html =~ "signed audit log"
  end

  test "pricing page mentions the three tiers", %{conn: conn} do
    html = conn |> get(~p"/pricing") |> html_response(200)
    assert html =~ "Free"
    assert html =~ "Team"
    assert html =~ "Enterprise"
    assert html =~ "365-day audit retention"
    refute html =~ "99.9% uptime SLA"
    refute html =~ "On-prem / self-hosted option"
  end

  test "pricing page emits a FAQPage with the visible questions in sync", %{conn: conn} do
    html = conn |> get(~p"/pricing") |> html_response(200)

    # The visible accordion and the FAQPage JSON-LD are driven by the same
    # list, so a question that renders must also appear in the structured data.
    assert html =~ "What counts as a"
    assert html =~ ~s("@type":"FAQPage")
    assert html =~ "How does billing work?"
  end

  test "docs states the supported deployment boundary", %{conn: conn} do
    html = conn |> get(~p"/docs") |> html_response(200)

    assert html =~ "supported product is the hosted emisar control plane today"
    refute html =~ "Run the control plane in your own VPC"
  end

  test "marketing pages include a large social preview image", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(property="og:image")
    assert html =~ "/images/og/emisar-product.webp"
    assert html =~ ~s(name="twitter:card" content="summary_large_image")
    assert html =~ ~s("FAQPage")
    refute html =~ "Phoenix.HTML.raw"
  end

  test "healthz returns 200 when the DB is reachable", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  describe "marketing nav" do
    test "ships a hamburger button + drawer for mobile viewports", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # Desktop nav is hidden on mobile (md:flex), so the drawer is
      # the only way to reach the secondary links on a phone — make
      # sure both the trigger and the drawer container are present.
      assert html =~ ~s(id="marketing-mobile-nav")
      assert html =~ "aria-label=\"Open menu\""
      assert html =~ "aria-label=\"Close menu\""
    end

    test "renders the active-page indicator on the current section", %{conn: conn} do
      # Pricing route should mark its own nav link active. The
      # indicator is the rounded indigo underline span we added.
      html = conn |> get(~p"/pricing") |> html_response(200)
      assert html =~ "bg-indigo-400"
    end
  end
end
