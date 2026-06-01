defmodule EmisarWeb.Router do
  use EmisarWeb, :router

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
    plug EmisarWeb.Plugs.AuditContext
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
    plug EmisarWeb.Plugs.AuditContext
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
    get "/pricing", MarketingController, :pricing
    get "/security", MarketingController, :security
    get "/docs", MarketingController, :docs
    get "/changelog", MarketingController, :changelog
    get "/about", MarketingController, :about
    get "/privacy", MarketingController, :privacy
    get "/terms", MarketingController, :terms
    get "/docs/connect-an-llm", MarketingController, :connect_llm
    get "/docs/quickstart", MarketingController, :docs_quickstart
    get "/docs/action-packs", MarketingController, :docs_action_packs
    get "/docs/security-model", MarketingController, :docs_security_model
    get "/use-cases/cassandra-ops", MarketingController, :usecase_cassandra
    get "/use-cases/postgres-ops", MarketingController, :usecase_postgres
    get "/compare/raw-ssh-for-ai", MarketingController, :compare_raw_ssh
    get "/packs", MarketingController, :packs
    get "/packs/:id", MarketingController, :pack_detail
    get "/docs/publishing-packs", MarketingController, :docs_publishing_packs
    get "/sitemap.xml", SitemapController, :show
    get "/install.sh", InstallController, :show
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
      live "/reset_password", ResetPasswordLive
      live "/reset_password/:token", ResetPasswordLive
    end

    post "/sign_in", UserSessionController, :create
    get "/sign_in/magic/:token", UserSessionController, :magic_link_confirm
    get "/confirm/:token", UserConfirmationController, :confirm
  end

  # -- Authenticated product surface ----------------------------------

  scope "/app", EmisarWeb do
    pipe_through [:browser, :noindex, :require_authenticated_user]

    post "/accounts/switch", AccountSwitchController, :switch

    live_session :authenticated,
      on_mount: [
        {EmisarWeb.UserAuth, :ensure_authenticated},
        {EmisarWeb.UserAuth, :ensure_mfa_compliant},
        {EmisarWeb.UserAuth, :audit_meta},
        {EmisarWeb.UserAuth, :track_pending_approvals}
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
      live "/agents", AgentsLive, :index
      live "/settings/team", TeamLive, :index
      live "/settings/billing", BillingLive, :index
      live "/settings/profile", ProfileLive, :index
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
      get "/runners", McpController, :list_runners
      get "/tools", McpController, :list_tools
      post "/tools/:action_id", McpController, :run_tool
      get "/runs/:id", McpController, :get_run
    end

    # SIEM-shaped audit export — cursor-paginated NDJSON over the same
    # API-key auth as MCP, but gated on the `audit:read` scope so log
    # shipping can be granted independently of tool-execution rights.
    get "/audit", AuditExportController, :index
  end

  # -- Paddle webhook -------------------------------------------------

  scope "/webhooks", EmisarWeb do
    pipe_through :api
    post "/paddle", PaddleWebhookController, :create
  end

  # -- LiveDashboard mounts -------------------------------------------

  import Phoenix.LiveDashboard.Router

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
