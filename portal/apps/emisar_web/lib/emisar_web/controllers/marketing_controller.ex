defmodule EmisarWeb.MarketingController do
  @moduledoc """
  Public marketing pages: home, pricing, security, docs, changelog, about.

  These are served by Phoenix controllers (not LiveView) so they remain
  cacheable static-ish HTML, render instantly, and require no JS.

  All SEO meta tags (page_title, meta_description, canonical_url, og_*,
  optional json_ld) flow into `layouts/root.html.heex` via assigns.
  Pages are defined declaratively in @pages and the per-action defs are
  generated below — keeps "add a page" to one row, and prevents drift
  between routes, sitemap, and per-page metadata.
  """
  use EmisarWeb, :controller

  plug :put_layout, html: {EmisarWeb.Layouts, :app}

  @base "https://emisar.dev"

  # path | action | template | page_title | meta_description
  @pages [
    {"/pricing", :pricing, :pricing, "Pricing",
     "Free for 3 runners. $20/runner/month on the standard plan. Unlimited users on every plan."},
    {"/security", :security, :security, "Security & compliance",
     "emisar's security model: pre-approved actions, redacted output, hash-chained audit, no SSH — designed for letting AI run production commands safely."},
    {"/docs", :docs, :docs, "Docs",
     "Documentation, action pack format, security model, and integration guides for emisar."},
    {"/changelog", :changelog, :changelog, "Changelog", nil},
    {"/about", :about, :about, "About", "Why emisar exists and how we built it."},
    {"/privacy", :privacy, :privacy, "Privacy Policy", nil},
    {"/terms", :terms, :terms, "Terms of Service", nil},
    {"/docs/connect-an-llm", :connect_llm, :connect_llm, "Connect an LLM",
     "Wire emisar into Claude Code, Claude Desktop, Cursor, Gemini CLI, or Codex CLI with one MCP config."},
    {"/docs/quickstart", :docs_quickstart, :docs_quickstart, "Quickstart — install the runner + run uptime",
     "5-minute quickstart: install the emisar runner on a Linux host, register an enrollment key, run linux.uptime from the dashboard."},
    {"/docs/action-packs", :docs_action_packs, :docs_action_packs, "Action packs — YAML reference",
     "Full YAML schema reference for action packs: how to declare actions, argument validation, limits, redaction, and side-effects."},
    {"/docs/security-model", :docs_security_model, :docs_security_model, "Security model",
     "The emisar trust boundary: pre-approved actions only, server-side re-validation, hash-chained audit, redaction before egress, and what we are explicitly not."},
    {"/use-cases/cassandra-ops", :usecase_cassandra, :usecase_cassandra,
     "Cassandra ops — letting an LLM run nodetool safely",
     "How to let an AI agent run nodetool repair / status against your Cassandra cluster without giving it SSH, using a declared action pack."},
    {"/use-cases/postgres-ops", :usecase_postgres, :usecase_postgres,
     "Postgres ops — read-only triage + slow-query kill",
     "Pre-approved Postgres action pack: pg_replication_lag, list-slow-queries, kill-pid. Read-only triage actions go through with no approval; killing a query needs one click."},
    {"/compare/raw-ssh-for-ai", :compare_raw_ssh, :compare_raw_ssh,
     "Why not just give the LLM SSH? — honest comparison",
     "Comparison: raw SSH-for-AI agents vs an emisar action pack. Both run real commands; the difference is whose recovery you're betting on."},
    {"/docs/publishing-packs", :docs_publishing_packs, :docs_publishing_packs,
     "Publishing an action pack",
     "How to author and publish an emisar action pack: pack.yaml, action YAMLs, validation rules, version + hash, and PR workflow to land in the registry."}
  ]

  # The home page has bespoke JSON-LD; keep it as its own def. Every
  # other page is generated below from @pages.
  def home(conn, _params) do
    # `logo` is intentionally omitted until we ship priv/static/images/og/emisar-card.png.
    # Schema.org accepts Organization without a logo; better than referencing a 404.
    org_ld =
      Jason.encode!(%{
        "@context" => "https://schema.org",
        "@graph" => [
          %{
            "@type" => "Organization",
            "name" => "emisar",
            "url" => @base,
            "description" =>
              "Give AI tools approved infrastructure actions, not SSH. Policy-gated, hash-chained audit, approval workflow."
          },
          %{
            "@type" => "SoftwareApplication",
            "name" => "emisar",
            "applicationCategory" => "DeveloperApplication",
            "operatingSystem" => "Linux",
            "url" => @base,
            "offers" => %{
              "@type" => "Offer",
              "priceCurrency" => "USD",
              "price" => "0",
              "description" => "Free for up to 3 runners"
            }
          }
        ]
      })

    render(conn, :home,
      page_title: "Give AI tools approved infrastructure actions, not SSH",
      meta_description:
        "emisar lets your LLM (Claude Code, Cursor, Gemini, Codex) call exactly the operational actions you've declared — with policy, approvals, and a hash-chained audit log.",
      canonical_url: @base <> "/",
      json_ld: org_ld
    )
  end

  # Generate one `def <action>(conn, _)` per row. Keeping this in module
  # body (not a macro) so the action names show up directly in routes,
  # stacktraces, and grep.
  for {path, action, template, title, description} <- @pages do
    base_attrs = [page_title: title, canonical_url: @base <> path]

    attrs =
      if description, do: Keyword.put(base_attrs, :meta_description, description), else: base_attrs

    template_atom = template
    attrs_literal = Macro.escape(attrs)

    def unquote(action)(conn, _params) do
      render(conn, unquote(template_atom), unquote(attrs_literal))
    end
  end

  # -- Packs registry -------------------------------------------------
  #
  # `/packs` lists every published pack; `/packs/:id` is the per-pack
  # detail page (description, actions, install snippet, source link).
  # The registry data is hardcoded in `EmisarWeb.PacksRegistry`; future
  # work may load from a remote manifest so third-party packs can list
  # themselves without a code change.

  def packs(conn, _params) do
    render(conn, :packs,
      packs: EmisarWeb.PacksRegistry.list(),
      page_title: "Action packs registry",
      meta_description:
        "Browse the registry of action packs you can install on your emisar runner: linux-core, cassandra, showcase. Each pack ships a typed catalog of actions an LLM can call.",
      canonical_url: @base <> "/packs"
    )
  end

  def pack_detail(conn, %{"id" => id}) do
    case EmisarWeb.PacksRegistry.get(id) do
      nil ->
        conn
        |> Plug.Conn.put_status(:not_found)
        |> put_view(html: EmisarWeb.ErrorHTML)
        |> render(:"404")

      pack ->
        render(conn, :pack_detail,
          pack: pack,
          page_title: "#{pack.name} pack",
          meta_description: pack.description,
          canonical_url: @base <> "/packs/" <> pack.id
        )
    end
  end
end
