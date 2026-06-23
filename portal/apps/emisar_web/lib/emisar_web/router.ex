defmodule EmisarWeb.Router do
  use EmisarWeb, :router
  import Phoenix.LiveDashboard.Router

  import EmisarWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EmisarWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug EmisarWeb.Plugs.ContentSecurityPolicy
    plug :fetch_current_user
  end

  # `noindex` on every authenticated and auth-bound route. Indexable
  # marketing/docs pages skip this pipeline.
  pipeline :noindex do
    plug :put_noindex
  end

  defp put_noindex(conn, _opts), do: Plug.Conn.assign(conn, :noindex, true)

  # Admin-only gate (separate from role-based perms). Used by /admin/live
  # so a leaked operator session cannot reach the LiveDashboard.
  pipeline :require_admin do
    plug :ensure_admin
  end

  defp ensure_admin(conn, _opts) do
    case conn.assigns[:current_user] do
      %{is_admin: true} ->
        conn

      _ ->
        conn
        |> Phoenix.Controller.put_flash(:error, "Not authorized.")
        |> Phoenix.Controller.redirect(to: "/app")
        |> Plug.Conn.halt()
    end
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Inbound SCIM 2.0 (RFC 7644). Bearer-only, CSRF-free — the IdP pushes
  # cross-origin, never a browser form. SCIM's `application/scim+json`
  # content-type resolves to the `json` extension via MIME's `+json` suffix,
  # so `:accepts ["json"]` accepts it and Plug.Parsers' :json entry parses it.
  pipeline :scim do
    plug :accepts, ["json"]
  end

  # -- Health (no logging, no session) --------------------------------

  scope "/" do
    pipe_through :api
    get "/healthz", EmisarWeb.HealthController, :index
  end

  # -- Marketing site (public, anyone) --------------------------------

  scope "/", EmisarWeb do
    pipe_through :browser

    get "/", MarketingController, :home
    get "/ai", MarketingController, :ai
    get "/pricing", MarketingController, :pricing
    get "/security", MarketingController, :security
    get "/docs", MarketingController, :docs
    get "/changelog", MarketingController, :changelog
    get "/about", MarketingController, :about
    get "/privacy", MarketingController, :privacy
    get "/terms", MarketingController, :terms
    get "/refund-policy", MarketingController, :refund
    get "/docs/connect-an-llm", MarketingController, :connect_llm
    get "/docs/mcp-reference", MarketingController, :docs_mcp_reference
    get "/docs/quickstart", MarketingController, :docs_quickstart
    get "/docs/action-packs", MarketingController, :docs_action_packs
    get "/docs/security-model", MarketingController, :docs_security_model
    get "/use-cases", MarketingController, :use_cases
    get "/use-cases/cassandra-ops", MarketingController, :usecase_cassandra
    get "/use-cases/postgres-ops", MarketingController, :usecase_postgres
    get "/use-cases/csi-data-loss", MarketingController, :usecase_csi_data_loss
    get "/compare/raw-ssh-for-ai", MarketingController, :compare_raw_ssh
    get "/compare/custom-mcp-server", MarketingController, :compare_custom_mcp
    get "/zero-trust", MarketingController, :zero_trust
    get "/demo", MarketingController, :demo
    get "/trust", MarketingController, :trust
    get "/how-it-works", MarketingController, :how_it_works
    get "/guides", MarketingController, :guides
    get "/guides/:slug", MarketingController, :guide
    get "/packs", MarketingController, :packs
    # Machine-facing registry endpoints (consumed by `emisar pack install`).
    # Declared before "/packs/:id" so the literal segments win; Phoenix
    # matches top-to-bottom and these are more specific.
    get "/packs.json", PackRegistryController, :index
    get "/packs/suggest.json", PackRegistryController, :suggest
    get "/packs/:id/pack.tar.gz", PackRegistryController, :tarball
    get "/packs/:id", MarketingController, :pack_detail
    get "/docs/publishing-packs", MarketingController, :docs_publishing_packs
    get "/docs/policies-and-approvals", MarketingController, :docs_policies
    get "/docs/runbooks", MarketingController, :docs_runbooks
    get "/docs/teams-and-access", MarketingController, :docs_teams
    get "/docs/sso", MarketingController, :docs_sso
    get "/docs/runners", MarketingController, :docs_runners
    get "/docs/audit-and-siem", MarketingController, :docs_audit
    get "/sitemap.xml", SitemapController, :show
    get "/changelog.xml", MarketingController, :changelog_feed
    get "/install.sh", InstallController, :show
    get "/install-mcp.sh", InstallMCPController, :show
  end

  # -- Auth surface (only when signed-out) ----------------------------

  scope "/", EmisarWeb do
    pipe_through [:browser, :noindex, :redirect_if_user_is_authenticated]

    live_session :redirect_if_user_is_authenticated,
      on_mount: [{EmisarWeb.UserAuth, :mount_current_user}] do
      live "/sign_up", UserSignUpLive
      live "/sign_in", UserSignInLive
      live "/sign_in/magic", MagicLinkLive
      live "/sign_in/mfa", MfaChallengeLive

      # Per-account ("branded") sign-in — the slug picks the tenant; offers SSO + userpass + magic.
      live "/app/:account_id_or_slug/sign_in", AccountSignInLive
      live "/reset_password", ResetPasswordLive
      live "/reset_password/:token", ResetPasswordLive
    end

    post "/sign_in", UserSessionController, :create
    get "/sign_in/magic/:token", UserSessionController, :magic_link_confirm

    # SSO landing: pick a team (recent-accounts cookie + manual entry) → its branded sign-in page.
    get "/sign_in/sso", SSOSignInController, :new
    post "/sign_in/sso", SSOSignInController, :create
    get "/sign_in/sso/callback", SSOController, :callback
    get "/sign_in/sso/:provider_id", SSOController, :begin
  end

  # Email confirmation must run whether or not you're signed in — the link
  # has to consume the token either way. It previously lived under
  # :redirect_if_user_is_authenticated, which silently bounced an
  # already-signed-in user to the dashboard without ever confirming.
  scope "/", EmisarWeb do
    pipe_through [:browser, :noindex]

    get "/confirm/:token", UserConfirmationController, :confirm
  end

  # -- Authenticated product surface ----------------------------------

  scope "/app", EmisarWeb do
    pipe_through [:browser, :noindex, :require_authenticated_user]

    post "/accounts/switch", AccountSwitchController, :switch

    # Bare /app → the user's current (session-hinted, else default) account, slugged.
    # require_authenticated_user has already resolved current_account (or bounced a
    # no-membership/suspended user), so this just forwards to the canonical URL.
    get "/", AccountRedirectController, :show

    # require_sso step-up shim: :ensure_sso_compliant bounces a non-SSO session here;
    # it logs out and lands on the account's branded SSO sign-in. OUTSIDE the slug
    # live_session below, so it never re-triggers the gate (no redirect loop).
    get "/:account_id_or_slug/sso_required", SSORequiredController, :show

    # Outside the slug scope on purpose: this is where ensure_mfa_compliant
    # SENDS a non-compliant member, so it must mount without that gate.
    live_session :mfa_setup,
      on_mount: [
        {EmisarWeb.UserAuth, :ensure_authenticated}
      ] do
      live "/mfa_setup", MfaSetupLive, :new
    end

    # Every tenant page nests under the account slug (resolved id-or-slug; the slug
    # is the canonical UI form). :ensure_account_slug resolves + authorizes it from
    # the URL on every mount — a non-member/unknown ref 404s, never leaks (IL-15).
    scope "/:account_id_or_slug" do
      live_session :authenticated,
        on_mount: [
          {EmisarWeb.UserAuth, :ensure_authenticated},
          {EmisarWeb.UserAuth, :ensure_account_slug},
          {EmisarWeb.UserAuth, :ensure_sso_compliant},
          {EmisarWeb.UserAuth, :ensure_mfa_compliant},
          {EmisarWeb.UserAuth, :track_pending_approvals},
          {EmisarWeb.UserAuth, :email_confirmation}
        ] do
        live "/", DashboardLive, :index

        live "/runners", RunnersLive, :index
        live "/runners/install", RunnerInstallLive, :new
        live "/runners/:id", RunnerDetailLive, :show

        live "/runs", RunsLive, :index
        live "/runs/:id", RunDetailLive, :show
        live "/runs/new/:runner_id/:action_id", RunNewLive, :new

        live "/approvals", ApprovalsLive, :index
        live "/approvals/:id", ApprovalDetailLive, :show

        live "/runbooks", RunbooksLive, :index
        live "/runbooks/new", RunbookEditorLive, :new
        live "/runbooks/:id/edit", RunbookEditorLive, :edit
        live "/runbooks/:id/run", RunbookRunLive, :new

        live "/policies", PoliciesLive, :index

        live "/packs", PacksLive, :index

        live "/audit", AuditLive, :index
        live "/audit/:id", AuditDetailLive, :show

        live "/settings/runners/auth-keys", AuthKeysLive, :index
        live "/settings/agents", AgentsLive, :index
        live "/settings/team", TeamLive, :index
        live "/settings/sso", SSOSettingsLive, :index
        live "/settings/sso/new", SSOSettingsLive, :new
        live "/settings/billing", BillingLive, :index
        live "/settings/profile", ProfileLive, :index
      end
    end
  end

  scope "/", EmisarWeb do
    pipe_through :browser
    delete "/sign_out", UserSessionController, :delete
  end

  scope "/", EmisarWeb do
    pipe_through :browser

    live_session :onboarding,
      on_mount: [{EmisarWeb.UserAuth, :mount_current_user}] do
      live "/onboarding", OnboardingLive, :new
      # Invitation acceptance has to work whether the visitor is signed
      # in or not: a brand-new invitee sets a password here, but a
      # signed-in user invited to a NEW team should see the prompt too
      # (the previous shared scope silently bounced them to /app).
      live "/accept_invitation/:token", AcceptInvitationLive
    end
  end

  # -- Runner transport (bearer-authed) --------------------------------

  scope "/runner", EmisarWeb do
    post "/register", RunnerConnectController, :register
    get "/socket/websocket", RunnerConnectController, :websocket
  end

  # -- MCP / LLM tool surface -----------------------------------------

  scope "/api", EmisarWeb do
    pipe_through :api

    scope "/mcp" do
      # JSON-RPC 2.0 / MCP-over-HTTP. Single endpoint the stdio bridge
      # and remote-MCP clients (Claude / ChatGPT cloud connectors) use.
      post "/rpc", MCPRpcController, :handle

      # REST routes — still in use by HTTP-only integrations (OpenAI
      # function-calling shim, generic curl examples, etc.). The
      # JSON-RPC endpoint above is the canonical MCP surface.
      get "/runners", MCPController, :list_runners
      get "/tools", MCPController, :list_tools
      post "/tools/:action_id", MCPController, :run_tool
      get "/runs/:id", MCPController, :get_run
    end

    # SIEM-shaped audit export — cursor-paginated NDJSON over the same
    # API-key auth as MCP, but gated on the `audit:read` scope so log
    # shipping can be granted independently of tool-execution rights.
    get "/audit", AuditExportController, :index
  end

  # -- Inbound SCIM 2.0 directory sync --------------------------------
  #
  # The IdP pushes the directory lifecycle here (create / deactivate /
  # reactivate / delete). Each route resolves its provider from the
  # per-provider `ems-` bearer (`SCIM.Auth`) — the token's provider-scope
  # is the authorization. Discovery endpoints sit behind the same auth
  # (IdPs send the bearer when probing). Mirrors the `/api/mcp` shape:
  # bearer-only, no session, no CSRF.

  scope "/scim/v2", EmisarWeb.SCIM do
    pipe_through :scim

    get "/ServiceProviderConfig", DiscoveryController, :service_provider_config
    get "/ResourceTypes", DiscoveryController, :resource_types
    get "/Schemas", DiscoveryController, :schemas

    get "/Users", UserController, :index
    post "/Users", UserController, :create
    get "/Users/:id", UserController, :show
    patch "/Users/:id", UserController, :update
    put "/Users/:id", UserController, :replace
    delete "/Users/:id", UserController, :delete

    get "/Groups", GroupController, :index
    post "/Groups", GroupController, :create
    get "/Groups/:id", GroupController, :show
    patch "/Groups/:id", GroupController, :update
    put "/Groups/:id", GroupController, :replace
    delete "/Groups/:id", GroupController, :delete
  end

  # -- OAuth 2.1 authorization server (remote MCP clients) ------------
  #
  # Claude.ai / ChatGPT cloud connectors offer only a URL field, then
  # drive the MCP OAuth flow themselves: discover this metadata,
  # self-register (DCR), bounce the operator through the consent screen
  # with PKCE, exchange the code for tokens, and present the resulting
  # `emo-` access token to `/api/mcp/rpc`.

  scope "/", EmisarWeb do
    pipe_through :api

    # Discovery (RFC 9728 + RFC 8414) — public, unauthenticated.
    get "/.well-known/oauth-protected-resource", OAuthMetadataController, :protected_resource
    get "/.well-known/oauth-authorization-server", OAuthMetadataController, :authorization_server

    # Dynamic Client Registration + token endpoint — public (clients are
    # PKCE public clients), and deliberately CSRF-free since the MCP
    # client calls them cross-origin, not a browser form.
    post "/oauth/register", OAuthController, :register
    post "/oauth/token", OAuthController, :token
  end

  # Consent screen — the operator must be signed in; the approve/deny
  # POST rides the CSRF-protected browser pipeline.
  scope "/oauth", EmisarWeb do
    pipe_through [:browser, :noindex, :require_authenticated_user]

    get "/authorize", OAuthController, :authorize
    post "/authorize", OAuthController, :authorize_submit
  end

  # -- Provider webhooks ----------------------------------------------

  scope "/webhooks", EmisarWeb do
    pipe_through :api
    post "/paddle", PaddleWebhookController, :create
    post "/postmark", PostmarkWebhookController, :create
  end

  # -- LiveDashboard mounts -------------------------------------------

  # Exposing `ecto_repos` turns on the built-in Ecto page (queries /
  # slowest queries / pool stats) on top of the Phoenix process /
  # request / memory views. `ecto_psql_extras_options` is honored when
  # the optional `ecto_psql_extras` dep is installed; ignored otherwise.
  if Application.compile_env(:emisar_web, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: EmisarWeb.Telemetry,
        ecto_repos: [Emisar.Repo]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Production admin mount at /admin/live. Guarded by the regular auth
  # pipeline AND `:is_admin` on the user record (separate from per-
  # account role). The distinct `live_session_name` keeps it isolated
  # from the dev-routes mount.
  scope "/admin" do
    pipe_through [:browser, :noindex, :require_authenticated_user, :require_admin]

    live_dashboard "/live",
      metrics: EmisarWeb.Telemetry,
      ecto_repos: [Emisar.Repo],
      live_session_name: :admin_dashboard
  end
end
