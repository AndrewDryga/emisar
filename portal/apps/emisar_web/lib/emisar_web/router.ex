defmodule EmisarWeb.Router do
  use EmisarWeb, :router
  import Phoenix.LiveDashboard.Router
  import EmisarWeb.UserAuth

  @dev_routes Application.compile_env(:emisar_web, :dev_routes)

  @doc false
  def dev_routes?, do: @dev_routes

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EmisarWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug EmisarWeb.Plugs.ContentSecurityPolicy
    plug :fetch_current_user
    plug EmisarWeb.Plugs.Analytics
  end

  pipeline :mailbox_preview do
    plug EmisarWeb.Plugs.MailboxPreviewCSP
  end

  pipeline :live_dashboard_csp do
    plug :allow_live_dashboard_data_fonts
  end

  # LiveDashboard's same-origin stylesheet embeds its font as a data URL. Keep
  # that exception on the staff dashboard instead of widening every HTML page.
  defp allow_live_dashboard_data_fonts(conn, _opts) do
    Plug.Conn.assign(conn, :csp_extra, %{"font-src" => ["data:"]})
  end

  # `noindex` on every authenticated and auth-bound route. Indexable
  # marketing/docs pages skip this pipeline.
  pipeline :noindex do
    plug :put_noindex
  end

  defp put_noindex(conn, _opts), do: Plug.Conn.assign(conn, :noindex, true)

  # Admin-only gate (separate from role-based perms). Used by /admin/live so a
  # leaked operator session cannot reach the LiveDashboard. The plug lives in
  # `UserAuth` (imported above) beside the `:ensure_admin` on_mount it shares its
  # decision with, so the request and socket gates cannot drift.
  pipeline :require_admin do
    plug :require_admin_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Inbound SCIM 2.0 (RFC 7644). Bearer-only, CSRF-free — the IdP pushes
  # cross-origin, never a browser form. SCIM's `application/scim+json`
  # content-type resolves to the `json` extension via MIME's `+json` suffix,
  # so `:accepts ["json"]` accepts it and Plug.Parsers' :json entry parses it.
  pipeline :scim do
    # Two limits, because one cannot do both jobs. The per-credential limit is
    # the real budget, but it can only bucket what the caller PRESENTS, and a
    # fabricated token parses as happily as a real one — so rotating credentials
    # bought a fresh allowance every time. This IP cap sits in front, before any
    # parsing or authentication, and bounds that rotation. It is deliberately
    # far above what one directory pushes so a busy IdP never meets it.
    plug EmisarWeb.Plugs.RateLimit,
      bucket: "scim_ip",
      limit: 1_200,
      window_ms: 60_000,
      by: :ip

    plug EmisarWeb.Plugs.RateLimit,
      bucket: "scim",
      limit: 300,
      window_ms: 60_000,
      by: :bearer

    plug :accepts, ["json"]
  end

  # Emailed unsubscribe links: a read-only GET confirm page + a one-click POST
  # (RFC 8058 `List-Unsubscribe-Post`). CSRF-free by design — a mail provider's
  # one-click POST carries no browser session or token; the unforgeable signed
  # token in the path is the authorization, and the action only flips one
  # notification preference. Deliberately NO `fetch_session` either: nothing on
  # this surface reads it, `protect_from_forgery` would 403 the provider's
  # tokenless POST, and a session-fetching pipeline without CSRF protection is
  # exactly the shape Sobelow (rightly) flags.
  pipeline :public_unauth do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {EmisarWeb.Layouts, :root}
    plug :put_secure_browser_headers
    plug EmisarWeb.Plugs.ContentSecurityPolicy
    plug :put_noindex
  end

  @auth_live_session_keys [
    :magic_link_email,
    :magic_link_expires_at,
    :mfa_pending_user_id,
    :mfa_pending_at,
    :sso_pending_request
  ]

  # LiveView signs only the session data explicitly returned here into its
  # websocket session. These pre-auth LiveViews are fed by controller flows that
  # set short-lived markers in Plug session; keep the allowlist narrow.
  def auth_live_session(conn) do
    session =
      @auth_live_session_keys
      |> Enum.flat_map(fn key ->
        case Plug.Conn.get_session(conn, key) do
          nil -> []
          value -> [{Atom.to_string(key), value}]
        end
      end)
      |> Map.new()

    session
  end

  # -- Health (no logging, no session) --------------------------------

  scope "/" do
    pipe_through :api
    get "/healthz", EmisarWeb.HealthController, :live
    get "/readyz", EmisarWeb.HealthController, :ready
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
    get "/support", MarketingController, :support
    get "/privacy", MarketingController, :privacy
    get "/terms", MarketingController, :terms
    get "/dpa", MarketingController, :dpa
    get "/refund-policy", MarketingController, :refund_policy
    get "/docs/connect-claude-ai", MarketingController, :connect_claude_ai
    get "/docs/connect-chatgpt", MarketingController, :connect_chatgpt
    get "/docs/connect-cli-agent", MarketingController, :connect_cli_agent
    get "/docs/connect-multiple-accounts", MarketingController, :connect_multiple_accounts
    get "/docs/mcp-reference", MarketingController, :mcp_reference
    get "/docs/quickstart", MarketingController, :quickstart
    get "/docs/use-a-published-pack", MarketingController, :use_a_published_pack
    get "/docs/action-packs", MarketingController, :action_packs
    get "/docs/security-model", MarketingController, :security_model
    get "/docs/signed-dispatch", MarketingController, :signed_dispatch
    get "/use-cases", MarketingController, :use_cases
    get "/use-cases/cassandra-migration", MarketingController, :cassandra_migration
    get "/use-cases/csi-data-loss", MarketingController, :csi_data_loss
    get "/use-cases/ingress-502", MarketingController, :ingress_502
    get "/compare/raw-ssh-for-ai", MarketingController, :raw_ssh_for_ai
    get "/compare/custom-mcp-server", MarketingController, :custom_mcp_server
    get "/compare/copy-paste-ai-ops", MarketingController, :copy_paste_ai_ops
    get "/zero-trust", MarketingController, :zero_trust
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
    get "/packs/:id/versions/:version/pack.tar.gz", PackRegistryController, :tarball_version
    get "/packs/:id", MarketingController, :pack_detail
    get "/docs/publishing-packs", MarketingController, :publishing_packs
    get "/docs/pack-registry", MarketingController, :pack_registry
    get "/docs/run-an-action", MarketingController, :run_an_action
    get "/docs/policies-and-approvals", MarketingController, :policies_and_approvals
    get "/docs/runbooks", MarketingController, :runbooks
    get "/docs/authentication", MarketingController, :authentication
    get "/docs/teams-and-access", MarketingController, :teams_and_access
    get "/docs/sso", MarketingController, :sso
    get "/docs/integrations/okta", MarketingController, :okta
    get "/docs/integrations/entra", MarketingController, :entra
    get "/docs/integrations/jumpcloud", MarketingController, :jumpcloud
    get "/docs/integrations/keycloak", MarketingController, :keycloak
    get "/docs/integrations/google-workspace", MarketingController, :google_workspace
    get "/docs/scim", MarketingController, :scim
    get "/docs/runner-fleet", MarketingController, :runner_fleet
    get "/docs/production", MarketingController, :production
    get "/docs/audit-and-siem", MarketingController, :audit_and_siem
    get "/docs/host-install", MarketingController, :host_install
    get "/docs/containers", MarketingController, :containers
    get "/docs/kubernetes", MarketingController, :kubernetes
    get "/docs/nomad", MarketingController, :nomad
    get "/docs/autoscaling-fleets", MarketingController, :autoscaling_fleets
    get "/docs/runs", MarketingController, :runs
    get "/docs/agents-and-keys", MarketingController, :agents_and_keys
    get "/docs/runner-cli", MarketingController, :runner_cli
    get "/docs/billing", MarketingController, :billing
    get "/docs/limits", MarketingController, :limits
    get "/docs/runner-upgrades", MarketingController, :runner_upgrades
    get "/docs/bridge-upgrades", MarketingController, :bridge_upgrades
    get "/docs/credentials", MarketingController, :credentials
    get "/docs/runner-credentials", MarketingController, :runner_credentials
    get "/docs/pack-updates", MarketingController, :pack_updates
    get "/docs/network-requirements", MarketingController, :network_requirements
    get "/docs/troubleshooting", MarketingController, :troubleshooting
    get "/docs/security-incidents", MarketingController, :security_incidents
    get "/docs/architecture", MarketingController, :architecture
    get "/docs/compatibility", MarketingController, :compatibility
    get "/sitemap.xml", SitemapController, :show
    get "/changelog.xml", MarketingController, :changelog_feed
    get "/install.sh", InstallController, :show
    get "/install-mcp.sh", InstallMCPController, :show
    get "/install-mcp.ps1", InstallMCPController, :show_powershell
    # Footer "get launch updates" capture — CSRF-protected by the :browser pipeline.
    post "/subscribe", MarketingController, :subscribe
  end

  # -- Emailed unsubscribe (unauthenticated, signed-token) ------------

  scope "/unsubscribe", EmisarWeb do
    pipe_through :public_unauth

    get "/monthly-report/:token", UnsubscribeController, :show
    post "/monthly-report/:token", UnsubscribeController, :create
  end

  # Registered OIDC callback shared by signed-out login and the authenticated
  # administrator-reset reauthentication. It must precede the dynamic
  # `/sign_in/sso/:provider_id` route below or `callback` is parsed as a
  # provider id before either one-time session stash can be consumed.
  scope "/", EmisarWeb do
    pipe_through [:browser, :noindex]

    get "/sign_in/sso/callback", SSOController, :callback
  end

  # -- Auth surface (only when signed-out) ----------------------------

  scope "/", EmisarWeb do
    pipe_through [:browser, :noindex, :redirect_if_user_is_authenticated]

    live_session :redirect_if_user_is_authenticated,
      session: {__MODULE__, :auth_live_session, []},
      on_mount: [{EmisarWeb.UserAuth, :mount_current_user}] do
      live "/sign_up", UserSignUpLive
      live "/sign_in", UserSignInLive
      live "/sign_in/magic", MagicLinkLive

      # Second-factor challenge for an mfa_enabled user after the magic link
      # verifies factor one. Reads the partial-auth `:mfa_pending_user_id` from
      # the session; a NON-pending (fully authed) visitor is bounced to the app
      # by this pipeline, a never-pending one back to /sign_in/magic on mount.
      live "/sign_in/mfa", MfaChallengeLive

      # Per-account ("branded") sign-in — the slug picks the tenant; offers SSO + magic link.
      live "/app/:account_id_or_slug/sign_in", AccountSignInLive

      # A :manual-provisioner SSO first login parks here (request id in the session)
      # and live-updates when an admin approves. Declared before the `:provider_id`
      # begin route below so "pending" isn't read as a provider id.
      live "/sign_in/sso/pending", SSOPendingLive
    end

    # Split-code magic link: the LV form POSTs the email to :magic_link_start
    # (issues + sets the nonce cookie + mails the link/code); the email link
    # carries token_id + secret. The typed code is verified IN the LiveView (so a
    # wrong code shows inline, no reload) — on success the LV redirects to
    # :magic_link_complete with a short-lived, cookie-bound handoff that sets the
    # session (a LiveView can't set the auth cookie itself).
    post "/sign_in/magic/start", UserSessionController, :magic_link_start
    get "/sign_in/magic/complete", UserSessionController, :magic_link_complete
    get "/sign_in/magic/:token_id/:secret", UserSessionController, :magic_link_confirm

    # MFA challenge completion — MfaChallengeLive verifies the TOTP/recovery code,
    # then redirects here with a signed handoff that (with the matching pending
    # session) establishes the full second-factor-verified session the LiveView
    # can't set itself.
    get "/sign_in/mfa/complete", UserSessionController, :mfa_complete

    # SSO landing: pick a team (recent-accounts cookie + manual entry) → its branded sign-in page.
    get "/sign_in/sso", SSOSignInController, :new
    post "/sign_in/sso", SSOSignInController, :create
    get "/sign_in/sso/:provider_id", SSOController, :begin
  end

  # Email confirmation must run whether or not you're signed in — the link
  # has to consume the token either way. It previously lived under
  # :redirect_if_user_is_authenticated, which silently bounced an
  # already-signed-in user to the dashboard without ever confirming.
  scope "/", EmisarWeb do
    pipe_through [:browser, :noindex]

    get "/confirm/:token", UserConfirmationController, :confirm
    # The Paddle default payment link: Paddle.js auto-opens the checkout
    # overlay for the ?_ptxn= transaction. Utility page — noindex, no auth
    # (the transaction id is the capability; Paddle's overlay does the rest).
    get "/checkout", CheckoutController, :show
  end

  # -- Authenticated product surface ----------------------------------

  # The device-grant approval URL the MCP installer prints (…/activate) —
  # top-level so the printed URL stays short; forwards into the current
  # account's slugged page, preserving ?code=.
  scope "/", EmisarWeb do
    pipe_through [:browser, :noindex, :require_authenticated_user]

    get "/activate", AccountRedirectController, :activate
  end

  scope "/app", EmisarWeb do
    pipe_through [:browser, :noindex, :require_authenticated_user]

    post "/accounts/switch", AccountSwitchController, :switch

    # Bare /app → the user's current (session-hinted, else default) account, slugged.
    # require_authenticated_user has already resolved current_account (or bounced a
    # no-membership/suspended user), so this just forwards to the canonical URL.
    get "/", AccountRedirectController, :show

    # Slugless deep-link shorthands — URLs the MCP installer, `emisar-mcp
    # --help`, and docs print without knowing the account. Literal segments
    # here shadow account slugs, so each is reserved in Account.Changeset.
    get "/runners", AccountRedirectController, :runners
    get "/runners/install", AccountRedirectController, :connect_runner
    get "/runners/keys", AccountRedirectController, :enrollment_keys
    get "/runners/keys/new", AccountRedirectController, :new_enrollment_key
    get "/runs", AccountRedirectController, :runs
    get "/approvals", AccountRedirectController, :approvals
    get "/runbooks", AccountRedirectController, :runbooks
    get "/runbooks/new", AccountRedirectController, :new_runbook
    get "/runbooks/import", AccountRedirectController, :import_runbook
    get "/policies", AccountRedirectController, :policies
    get "/packs", AccountRedirectController, :packs
    get "/audit", AccountRedirectController, :audit
    get "/audit/export", AccountRedirectController, :audit_export
    get "/agents", AccountRedirectController, :agents
    get "/agents/connect", AccountRedirectController, :connect_agent
    get "/team", AccountRedirectController, :team
    get "/team/invite", AccountRedirectController, :invite_team_member
    get "/sso", AccountRedirectController, :sso
    get "/sso/new", AccountRedirectController, :add_sso_provider
    get "/billing", AccountRedirectController, :billing

    # Paddle's post-payment redirect. The checkout page can't know the account
    # slug at render time, so this resolves the session's current account and
    # lands on its billing page. Before the slug scope so "checkout" never
    # parses as an account ref.
    get "/checkout/success", CheckoutController, :success

    # require_sso step-up shim: :ensure_sso_compliant bounces a non-SSO session here;
    # GET renders the explicit sign-out form; POST revokes the session and lands on
    # the account's branded SSO sign-in. OUTSIDE the slug live_session below, so it
    # never re-triggers the gate (no redirect loop).
    get "/:account_id_or_slug/sso_required", SSORequiredController, :show
    post "/:account_id_or_slug/sso_required", SSORequiredController, :revoke

    # Outside the slug scope on purpose: this is where ensure_account_compliant
    # sends a non-compliant member, so it must mount without that combined gate (it
    # would loop). It DOES carry the SSO gate: SSO precedes MFA, so a member of a
    # require_sso+require_mfa account must satisfy SSO before enrolling a factor
    # (else a magic-link session could enroll TOTP without ever passing SSO).
    live_session :mfa_setup,
      on_mount: [
        {EmisarWeb.UserAuth, :ensure_authenticated},
        {EmisarWeb.UserAuth, :ensure_sso_compliant}
      ] do
      live "/mfa_setup", MfaSetupLive, :new
    end

    # Every tenant page nests under the account slug (resolved id-or-slug; the slug
    # is the canonical UI form). :ensure_account_slug resolves + authorizes it from
    # the URL on every mount — a non-member/unknown ref 404s, never leaks (IL-15).
    scope "/:account_id_or_slug" do
      live_session :authenticated,
        on_mount: [
          {EmisarWeb.UserAuth, :reload_stale_assets},
          {EmisarWeb.UserAuth, :ensure_authenticated},
          {EmisarWeb.UserAuth, :ensure_account_slug},
          {EmisarWeb.UserAuth, :ensure_account_compliant},
          {EmisarWeb.UserAuth, :track_pending_approvals},
          {EmisarWeb.UserAuth, :email_confirmation},
          {EmisarWeb.UserAuth, :track_pageviews}
        ] do
        live "/", DashboardLive, :index

        live "/runners", RunnersLive, :index
        live "/runners/install", RunnerInstallLive, :new
        # Before /runners/:id so "keys" isn't captured as a runner id.
        live "/runners/keys", EnrollmentKeysLive, :index
        live "/runners/keys/new", EnrollmentKeysLive, :new
        live "/runners/:id", RunnerDetailLive, :show

        live "/runs", RunsLive, :index
        live "/runs/:id", RunDetailLive, :show
        live "/runs/new/:runner_id/:action_id", RunNewLive, :new

        live "/approvals", ApprovalsLive, :index
        live "/approvals/:id", ApprovalDetailLive, :show

        live "/runbooks", RunbooksLive, :index
        live "/runbooks/new", RunbookEditorLive, :new
        live "/runbooks/import", RunbookImportLive, :new
        live "/runbooks/:id/edit", RunbookEditorLive, :edit
        live "/runbooks/:id/runs/:execution_id", RunbookRunLive, :show
        live "/runbooks/:id/run", RunbookRunLive, :new

        live "/policies", PoliciesLive, :index

        live "/packs", PacksLive, :index

        live "/audit", AuditLive, :index
        # Before /audit/:id so "export"/"download" aren't captured as event ids.
        live "/audit/export", AuditExportLive, :index
        get "/audit/download", AuditDownloadController, :download
        live "/audit/:id", AuditDetailLive, :show

        live "/agents", AgentsLive, :index
        live "/agents/connect", AgentsLive, :connect
        live "/activate", ActivateLive, :show
        live "/settings/team", TeamLive, :index
        live "/settings/team/invite", TeamLive, :new
        live "/settings/team/:membership_id/reset_2fa", TeamLive, :reset_mfa

        post "/settings/team/:membership_id/reset_2fa/sso",
             SSOController,
             :begin_member_mfa_reset

        live "/settings/sso", SSOSettingsLive, :index
        live "/settings/sso/new", SSOSettingsLive, :new
        live "/settings/sso/:id", SSOSettingsLive, :show
        live "/settings/sso/:id/edit", SSOSettingsLive, :edit
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
    # :noindex like every other auth-bound route — robots.txt blocks crawling
    # but not URL-only indexing, and the router comment above already promises
    # this pipeline on every one of them.
    pipe_through [:browser, :noindex]

    live_session :onboarding,
      on_mount: [{EmisarWeb.UserAuth, :mount_current_user}] do
      live "/onboarding", OnboardingLive, :new
      # Invitation acceptance has to work whether the visitor is signed
      # in or not: a brand-new invitee enters their name and requests a
      # sign-in link here, but a
      # signed-in user invited to a NEW team should see the prompt too
      # (the previous shared scope silently bounced them to /app).
      live "/accept_invitation/:token", AcceptInvitationLive
    end
  end

  # -- Runner transport (bearer-authed) --------------------------------

  scope "/runner", EmisarWeb do
    post "/register", RunnerConnectController, :register
    post "/token/refresh", RunnerConnectController, :refresh_token
    get "/socket/websocket", RunnerConnectController, :websocket
  end

  # -- MCP / LLM tool surface -----------------------------------------

  # Streamable-HTTP JSON-RPC endpoint — the canonical MCP
  # surface the stdio bridge and remote connectors (Claude / ChatGPT / Cursor)
  # use. Deliberately OUTSIDE the `:api` pipeline: a Streamable-HTTP GET opens an
  # SSE stream with `Accept: text/event-stream`, which `:accepts, ["json"]`
  # would answer 406 — but the spec requires 405 (this stateless server offers
  # no SSE stream). The controller enforces content negotiation, Origin, and
  # protocol-version checks explicitly instead. GET/DELETE are answered 405: no
  # SSE stream to open, no durable session to terminate.
  scope "/api/mcp", EmisarWeb do
    post "/rpc", MCPRpcController, :handle
    get "/rpc", MCPRpcController, :reject_stream
    delete "/rpc", MCPRpcController, :reject_termination

    # Device authorization for the MCP installer (RFC 8628 shape) — the
    # unauthenticated open + poll pair; the approval itself happens on the
    # authed /app/…/activate page. IP rate limits live on the controller.
    post "/device_authorization", MCPDeviceGrantController, :authorize
    post "/device_token", MCPDeviceGrantController, :token
  end

  scope "/api", EmisarWeb do
    pipe_through :api

    # SIEM-shaped audit export — cursor-paginated NDJSON over the same
    # API-key auth as MCP, but gated on the `:audit_export` key KIND so log
    # shipping is a separate credential from tool-execution rights.
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
    get "/ResourceTypes/:id", DiscoveryController, :resource_type
    get "/Schemas", DiscoveryController, :schemas
    get "/Schemas/:id", DiscoveryController, :schema

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
  # Claude.ai / ChatGPT cloud connectors take a display name plus this server
  # URL; their optional client credentials stay empty. They then drive the MCP
  # OAuth flow themselves: discover this metadata, self-register (DCR), bounce
  # the operator through the consent screen with PKCE, exchange the code for
  # tokens, and present the resulting `emo-` access token to `/api/mcp/rpc`.

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

  # OpenAI requests this text proof with Accept: text/plain, so it deliberately
  # stays outside the JSON-only API pipeline. The fixed public token is the
  # entire response; the controller does not inspect request data.
  scope "/", EmisarWeb do
    get "/.well-known/openai-apps-challenge", DomainVerificationController, :openai_apps_challenge
  end

  # Consent screen — the operator must be signed in; the approve/deny
  # POST rides the CSRF-protected browser pipeline.
  scope "/oauth", EmisarWeb do
    pipe_through [:browser, :noindex, :require_authenticated_user]

    get "/authorize", OAuthController, :authorize
    post "/authorize", OAuthController, :authorize_submit
  end

  # -- Provider webhooks ----------------------------------------------

  # Both webhooks are unauthenticated until their signature check runs, and each
  # request costs a 1 MiB body read, a JSON decode, a retained raw-body copy,
  # and an HMAC over the whole thing BEFORE anything can reject it. The SCIM
  # pipeline already carries an IP cap for exactly this reason. Set far above
  # what a provider sends so a real burst never meets it.
  pipeline :provider_webhook do
    plug EmisarWeb.Plugs.RateLimit,
      bucket: "provider_webhook_ip",
      limit: 600,
      window_ms: 60_000,
      by: :ip

    plug :accepts, ["json"]
  end

  scope "/webhooks", EmisarWeb do
    pipe_through :provider_webhook
    post "/paddle", PaddleWebhookController, :create
    post "/postmark", PostmarkWebhookController, :create
  end

  # -- LiveDashboard mounts -------------------------------------------

  # Exposing `ecto_repos` turns on the built-in Ecto page (queries /
  # slowest queries / pool stats) on top of the Phoenix process /
  # request / memory views. `ecto_psql_extras_options` is honored when
  # the optional `ecto_psql_extras` dep is installed; ignored otherwise.
  if @dev_routes do
    scope "/dev" do
      pipe_through [:browser, :mailbox_preview]

      live_dashboard "/dashboard",
        metrics: EmisarWeb.Telemetry,
        ecto_repos: [Emisar.Repo]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Emisar staff surfaces. Guarded by the regular auth pipeline AND `:is_admin`
  # on the user record (separate from per-account role) AND a second factor this
  # session verified — with `:ensure_admin` re-deciding all three on the socket,
  # so the request and mount gates cannot drift. The staff console reads across
  # tenants and mutates nothing; every account view it renders writes a
  # customer-visible `staff.account_viewed` audit row. Mutations stay on the
  # private emisar-admin pack (release RPC), never here.
  scope "/admin", EmisarWeb do
    pipe_through [:browser, :noindex, :require_authenticated_user, :require_admin]

    live_session :admin_console,
      on_mount: [{EmisarWeb.UserAuth, :ensure_admin}] do
      live "/", AdminSearchLive
      live "/accounts/:id", AdminAccountLive
    end

    scope "/" do
      pipe_through :live_dashboard_csp

      # A distinct `live_session_name` keeps the LiveDashboard isolated from the
      # console mount above and from the dev-routes mount.
      live_dashboard "/live",
        metrics: EmisarWeb.Telemetry,
        ecto_repos: [Emisar.Repo],
        csp_nonce_assign_key: :csp_nonce,
        live_session_name: :admin_dashboard,
        on_mount: [{EmisarWeb.UserAuth, :ensure_admin}]
    end
  end
end
