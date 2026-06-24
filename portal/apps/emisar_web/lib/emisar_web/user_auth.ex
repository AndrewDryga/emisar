defmodule EmisarWeb.UserAuth do
  @moduledoc """
  Authentication plug + LiveView hooks. Sessions are signed cookies
  carrying a session-token; the token is looked up in `user_tokens` on
  each request. Stale 60d => garbage-collect (handled by Oban).
  """

  use EmisarWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Emisar.{Accounts, Auth, SSO}
  alias Emisar.Auth.Subject
  alias EmisarWeb.Analytics
  alias EmisarWeb.RequestContext

  @remember_me_cookie "_emisar_user_remember_me"

  # Session provenance for an unauthenticated request — no method, no SSO
  # identity. `fetch_user_and_token_by_session_token/1` returns the `%UserToken{}`
  # on a hit; this is the miss/anonymous default the Subject build reads from.
  @no_auth %{auth_method: nil, mfa: nil, user_identity_id: nil}

  # Built per-call rather than as a module attribute so `secure:` can
  # be flipped at runtime via the FORCE_SSL env knob (see runtime.exs).
  # If we baked it in with `Application.compile_env`, the release would
  # refuse to boot whenever the runtime value diverged from compile.
  defp remember_me_options do
    [
      encrypt: true,
      max_age: 60 * 60 * 24 * 60,
      same_site: "Lax",
      http_only: true,
      secure: Application.get_env(:emisar_web, :force_secure_cookies, false)
    ]
  end

  # -- Public surface -------------------------------------------------

  @doc """
  Logs in `user`, persisting the session token in the cookie, and optionally
  setting the "remember me" cookie. Always renews the session ID (CSRF defence
  in depth) and redirects. `auth_method` (how they signed in) and `mfa` (was a
  second factor verified) are stamped onto the persisted token so they reach
  every audit row; `opts` carry the SSO-only `:user_identity_id`.
  """
  def log_in_user(conn, user, auth_method, mfa, params \\ %{}, opts \\ []) do
    context = RequestContext.from_conn(conn)

    token =
      Auth.create_session_token!(
        user,
        auth_method,
        mfa,
        %{ip_address: context.ip_address, user_agent: context.user_agent},
        opts
      )

    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> maybe_flash_just_registered(user)
    |> Analytics.track_authentication(user, auth_method, mfa)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  # The sign-up form posts here with `?_action=registered` and we auto-sign the
  # new user in. Tell them a confirmation link is on the way — otherwise the
  # email is silent. No "or your account locks" threat: unconfirmed accounts
  # aren't gated (they just see the verify-email banner). Matching `params` in
  # the head also no-ops safely when they're unfetched (direct unit calls).
  defp maybe_flash_just_registered(%{params: %{"_action" => "registered"}} = conn, user) do
    put_flash(conn, :info, "Welcome to emisar! We emailed a confirmation link to #{user.email}.")
  end

  defp maybe_flash_just_registered(conn, _user), do: conn

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, remember_me_options())
  end

  defp maybe_write_remember_me_cookie(conn, _, _), do: conn

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp put_token_in_session(conn, token) do
    # `live_socket_id` is derived from the digest (NOT the raw token)
    # so the server can re-derive the per-session disconnect topic
    # without the cookie value — see `Emisar.Auth.live_socket_topic/1`.
    # If we keyed on the raw token, `Auth.disconnect_and_revoke_all_sessions`
    # couldn't broadcast to a session whose cookie it doesn't hold.
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, Auth.live_socket_topic_for_session(token))
  end

  @doc "Sign-out: invalidate the session token and clear the cookie."
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    # Audit-log the sign-out BEFORE deleting the token — the user lookup
    # is via the token, so dropping it first would lose the actor id.
    if user = conn.assigns[:current_user],
      do: Auth.record_sign_out(user, RequestContext.from_conn(conn))

    user_token && Auth.delete_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      EmisarWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> Analytics.track_sign_out()
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  # -- Plugs ----------------------------------------------------------

  @doc "Fetch the current user from the session/cookie token."
  def fetch_current_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)

    {user, auth} =
      with token when is_binary(token) <- user_token,
           {:ok, user, auth} <- Auth.fetch_user_and_token_by_session_token(token) do
        {user, auth}
      else
        _ -> {nil, @no_auth}
      end

    conn
    |> assign(:current_user, user)
    |> assign(:current_auth, auth)
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, put_token_in_session(conn, token)}
      else
        {nil, conn}
      end
    end
  end

  @doc "Used in router/pipeline: redirects unauthenticated requests to login."
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      assign_current_account(conn)
    else
      conn
      |> put_flash(:error, "You must log in to access that page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/sign_in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :user_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn

  @doc "Used in router: prevents already-logged-in users from hitting auth pages."
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  defp assign_current_account(conn) do
    user = conn.assigns.current_user
    account_ref = conn.path_params["account_id_or_slug"]
    session_account_id = get_session(conn, :current_account_id)

    case resolve_membership_for_request(user, account_ref, session_account_id) do
      {:error, :not_found} when not is_nil(account_ref) ->
        # A slugged route whose ref isn't a (non-suspended) membership the user
        # holds: 404, never a redirect — indistinguishable from a nonexistent
        # tenant, so the URL never confirms one exists (IL-15, no leak).
        raise EmisarWeb.NotFoundError

      {:error, :not_found} ->
        if Accounts.all_memberships_suspended?(user) do
          conn
          |> log_out_user_with_flash("Your access has been suspended. Contact your team admin.")
          |> halt()
        else
          conn
          |> put_flash(:error, "You don't belong to any account. Create one to continue.")
          |> redirect(to: ~p"/onboarding")
          |> halt()
        end

      {:ok, membership} ->
        context = RequestContext.from_conn(conn)

        conn
        |> maybe_refresh_account_session(membership.account_id, session_account_id)
        |> assign(:current_account, membership.account)
        |> assign(:current_membership, membership)
        |> assign(
          :current_subject,
          Subject.for_user(user, membership.account, membership, context, auth_opts(conn.assigns))
        )
    end
  end

  # Slugged tenant route → resolve+authorize from the URL ref (id-or-slug);
  # bare /app + the unslugged /app routes (switch, mfa_setup) → the session hint.
  defp resolve_membership_for_request(user, nil, session_account_id),
    do: Accounts.fetch_membership_for_session(user, session_account_id)

  defp resolve_membership_for_request(user, account_ref, _session_account_id),
    do: Accounts.fetch_membership_by_account_id_or_slug(user, account_ref)

  # Session provenance (auth_method / mfa / user_identity_id) for the Subject,
  # pulled off the `:current_auth` assign the boundary stashed (a `%UserToken{}`
  # or `@no_auth`). So every audit row the subject produces records how the
  # operator signed in.
  defp auth_opts(assigns) do
    auth = Map.get(assigns, :current_auth, @no_auth)
    [auth_method: auth.auth_method, mfa: auth.mfa, user_identity_id: auth.user_identity_id]
  end

  # If the session asked for an account the user can no longer reach
  # (suspended, deleted) `fetch_membership_for_session/2` falls back to
  # their primary. Overwrite the session value so subsequent requests
  # don't keep re-resolving against the dead pointer.
  defp maybe_refresh_account_session(conn, resolved_id, requested_id)
       when resolved_id == requested_id,
       do: conn

  defp maybe_refresh_account_session(conn, resolved_id, _requested_id),
    do: put_session(conn, :current_account_id, resolved_id)

  @doc """
  Public API for the switch-account controller: validates the user has
  a non-suspended membership on `account_id` and pins it in the session.
  Returns `{:ok, conn}` with the new session value, or `{:error, :not_found}`
  when the user has no access to that account.
  """
  def switch_account(conn, account_id) when is_binary(account_id) do
    user = conn.assigns.current_user

    case Accounts.fetch_membership_for_session(user, account_id) do
      {:ok, %{account_id: ^account_id} = membership} ->
        {:ok, put_session(conn, :current_account_id, account_id), membership}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Log the session out (delete the token, disconnect live sockets, renew the
  session) and redirect to `to` with an error flash. Drives the suspended-account
  bounce (default `/sign_in`) and the require_sso step-up, which lands the user on
  that account's branded sign-in. The flash is set AFTER renew_session, so it
  survives to the next request.
  """
  def log_out_user_with_flash(conn, message, to \\ ~p"/sign_in") do
    user_token = get_session(conn, :user_token)
    user_token && Auth.delete_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      EmisarWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> put_flash(:error, message)
    |> redirect(to: to)
  end

  defp signed_in_path(_conn), do: ~p"/app"

  # -- LiveView on_mount hooks ----------------------------------------

  # Flags that this render needs the full `app.js` (LiveSocket + hooks).
  # Attached to every LiveView via `EmisarWeb.live_view/0`, so the dead
  # render carries `@app_js?` up to `root.html.heex`; controller-rendered
  # marketing pages never set it and get the lean `marketing.js` instead.
  def on_mount(:assign_app_bundle, _params, _session, socket) do
    {:cont, Phoenix.Component.assign(socket, :app_js?, true)}
  end

  # Console pageview tracking. The console is a LiveView app, so in-app
  # navigation happens over the websocket with no controller hit — the :browser
  # pageview plug only sees the dead render, which it skips for /app. This
  # attaches a `handle_params` lifecycle hook that fires `page_viewed` on the
  # connected mount and on every live navigation; the `connected?` guard keeps
  # the twice-running mount to one event. UA captured at mount (connect-info is
  # mount-only) and closed over.
  def on_mount(:track_pageviews, _params, _session, socket) do
    context = RequestContext.from_socket(socket)

    hook = fn _params, uri, socket ->
      user = socket.assigns[:current_user]

      if user && Phoenix.LiveView.connected?(socket) do
        Analytics.track_console_pageview(user, socket.assigns[:current_account], uri, context)
      end

      {:cont, socket}
    end

    {:cont, Phoenix.LiveView.attach_hook(socket, :analytics_pageview, :handle_params, hook)}
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(session, socket)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(session, socket)

    if socket.assigns.current_user do
      {:cont, mount_current_account(socket, session)}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access that page.")
        |> Phoenix.LiveView.redirect(to: ~p"/sign_in")

      {:halt, socket}
    end
  end

  # The slug gate (IL-15): composed AFTER :ensure_authenticated on every tenant
  # route. Re-resolves current_account from the URL ref (id-or-slug) on EVERY
  # mount — the session value is NOT trusted as the tenant key here — and
  # overwrites the session-based account/subject :ensure_authenticated mounted.
  # A ref the user has no (non-suspended) membership for raises NotFoundError →
  # 404, never a redirect/leak (indistinguishable from a nonexistent tenant).
  def on_mount(:ensure_account_slug, %{"account_id_or_slug" => account_ref}, _session, socket) do
    user = socket.assigns.current_user

    case Accounts.fetch_membership_by_account_id_or_slug(user, account_ref) do
      {:ok, membership} ->
        subject =
          Subject.for_user(
            user,
            membership.account,
            membership,
            RequestContext.from_socket(socket),
            auth_opts(socket.assigns)
          )

        {:cont,
         socket
         |> Phoenix.Component.assign(:current_account, membership.account)
         |> Phoenix.Component.assign(:current_membership, membership)
         |> Phoenix.Component.assign(:current_subject, subject)
         |> Phoenix.LiveView.attach_hook(
           :ensure_slug_unchanged,
           :handle_params,
           &ensure_slug_unchanged/3
         )}

      {:error, :not_found} ->
        raise EmisarWeb.NotFoundError
    end
  end

  # require_sso enforcement (approach B). Composed AFTER :ensure_account_slug, so
  # current_account + the session's auth provenance are set. When the account
  # mandates SSO and this session wasn't authenticated via THAT account's own SSO
  # (a password/magic session — OR an SSO session for a DIFFERENT account, since
  # each account demands its own IdP), bounce to the /sso_required shim, which
  # logs the session out and lands on the account's branded sign-in (a LiveView
  # on_mount can't clear the plug session itself). Misconfig (require_sso on with
  # no usable provider) is recoverable, not a lockout: the shim logs out and the
  # branded page shows whatever sign-in methods exist.
  def on_mount(:ensure_sso_compliant, _params, _session, socket) do
    account = socket.assigns[:current_account]
    auth = socket.assigns[:current_auth] || @no_auth

    cond do
      is_nil(account) or not account.require_sso ->
        {:cont, socket}

      auth.auth_method == :sso and
          SSO.identity_belongs_to_account?(auth.user_identity_id, account.id) ->
        {:cont, socket}

      # Defensive fail-open: require_sso is on but the account has no usable SSO
      # connection (one removed out-of-band). Allow access rather than brick
      # everyone — recoverable (re-enable a connection and enforcement resumes).
      # The provider write paths guard against reaching this through the UI.
      SSO.list_enabled_providers_for_account(account.id) == [] ->
        {:cont, socket}

      true ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/#{account}/sso_required")}
    end
  end

  # Account-wide MFA enforcement. When the account has `require_mfa`
  # on and the user hasn't enrolled, every protected route funnels
  # them to /app/settings/profile (where the MFA setup UI lives) and
  # blocks everything else. Compose this hook AFTER :ensure_authenticated
  # in the LV pipeline so `current_account` is already mounted.
  #
  # The profile page itself is the one exception — the user has to be
  # able to load it to enroll. If they're already there, do nothing.
  def on_mount(:ensure_mfa_compliant, _params, _session, socket) do
    user = socket.assigns[:current_user]
    account = socket.assigns[:current_account]
    auth = socket.assigns[:current_auth] || @no_auth

    cond do
      is_nil(user) or is_nil(account) ->
        {:cont, socket}

      not account.require_mfa ->
        {:cont, socket}

      user.mfa_enabled_at != nil ->
        {:cont, socket}

      # An SSO session is exempt ONLY when its provider satisfies MFA (the IdP
      # enforces the second factor — decision 4 / N2). A provider marked
      # satisfies_mfa: false still funnels the user into emisar TOTP.
      auth.auth_method == :sso and SSO.identity_satisfies_mfa?(auth.user_identity_id) ->
        {:cont, socket}

      socket.view == EmisarWeb.ProfileLive ->
        {:cont, socket}

      true ->
        # No error flash — the setup page explains the enforcement and
        # walks the member through enrollment (the invite-accept flow
        # lands here as its natural second step before the dashboard).
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/mfa_setup")}
    end
  end

  # Tracks the account's pending-approval count, pending-pack-trust count, AND
  # the fleet-offline alert so all three nav cues stay live across every
  # authenticated LV without each one re-implementing the subscribe/handle_info
  # dance.
  #
  # First connect computes them + subscribes to the account's approvals, packs,
  # and runner-connections topics; `attach_hook`s then refresh whenever a request
  # is created/decided, a pack flips pending/resolved, or a runner connects/
  # disconnects. The approvals hook returns `{:cont, ...}` so the host LV's own
  # `handle_info/2` (e.g. reload the approvals table) still runs; the packs hook
  # `{:halt}`s — no host LV needs that message; the fleet hook forwards
  # `presence_diff` (the dashboard reloads on it) but `{:halt}`s its own debounce
  # tick. The fleet recompute is debounced (the connections topic is hot).
  def on_mount(:track_pending_approvals, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign_new(:pending_approvals_count, fn ->
        approval_count_for(socket.assigns[:current_subject])
      end)
      |> Phoenix.Component.assign_new(:pending_packs_count, fn ->
        pack_pending_count_for(socket.assigns[:current_subject])
      end)
      |> Phoenix.Component.assign_new(:fleet_all_offline?, fn ->
        fleet_offline_for(socket.assigns[:current_subject])
      end)
      |> Phoenix.Component.assign_new(:no_agents?, fn ->
        no_agents_for(socket.assigns[:current_subject])
      end)

    if Phoenix.LiveView.connected?(socket) and socket.assigns[:current_account] do
      account_id = socket.assigns.current_account.id
      Emisar.Approvals.subscribe_account_approvals(account_id)
      Emisar.Catalog.subscribe_account_packs(account_id)
      Emisar.Runners.subscribe_connections(account_id)

      {:cont,
       socket
       |> Phoenix.LiveView.attach_hook(
         :refresh_pending_approvals,
         :handle_info,
         &refresh_pending_approvals/2
       )
       |> Phoenix.LiveView.attach_hook(
         :refresh_pending_packs,
         :handle_info,
         &refresh_pending_packs/2
       )
       |> Phoenix.LiveView.attach_hook(
         :refresh_fleet_offline,
         :handle_info,
         &refresh_fleet_offline/2
       )}
    else
      {:cont, socket}
    end
  end

  # Wires a global "resend confirmation email" handler onto every
  # authenticated LiveView so the unverified-email banner (rendered by
  # `dashboard_shell`) can re-send the link from any page without each
  # host LV defining the event. The banner reads `@current_user.confirmed_at`
  # directly, so this hook only needs to handle the button's event.
  def on_mount(:email_confirmation, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(
       socket,
       :resend_confirmation,
       :handle_event,
       &resend_confirmation_email/3
     )}
  end

  # Defense-in-depth for cross-slug `live_patch` (attached by :ensure_account_slug):
  # on_mount runs once, so a patch that changes the URL's account ref WITHOUT a
  # remount keeps the mount-time subject — the URL would say account B while the
  # socket is still scoped to A. No data crosses today (every context call uses
  # the mounted subject, not the ref), but assert the ref still resolves to the
  # mounted account on every handle_params and 404 on a mismatch rather than lean
  # on that invariant alone.
  defp ensure_slug_unchanged(%{"account_id_or_slug" => ref}, _uri, socket) do
    account = socket.assigns.current_account

    if ref == account.id or ref == account.slug do
      {:cont, socket}
    else
      raise EmisarWeb.NotFoundError
    end
  end

  defp ensure_slug_unchanged(_params, _uri, socket), do: {:cont, socket}

  defp refresh_pending_approvals({:approval_updated, _}, socket) do
    {:cont,
     Phoenix.Component.assign(
       socket,
       :pending_approvals_count,
       approval_count_for(socket.assigns[:current_subject])
     )}
  end

  defp refresh_pending_approvals(_msg, socket), do: {:cont, socket}

  # Pack-trust badge counterpart. The count drives both the sidebar badge
  # and the dashboard banner (both read `@pending_packs_count`), so the
  # hook owns the refresh end-to-end and HALTS: no host LV needs the
  # message forwarded, and halting keeps `{:pack_trust_changed, _}` off
  # pages whose `handle_info/2` doesn't expect it.
  defp refresh_pending_packs({:pack_trust_changed, _account_id}, socket) do
    {:halt,
     Phoenix.Component.assign(
       socket,
       :pending_packs_count,
       pack_pending_count_for(socket.assigns[:current_subject])
     )}
  end

  defp refresh_pending_packs(_msg, socket), do: {:cont, socket}

  # Fleet-offline nav alert. The runner-connections topic is high-frequency (a
  # busy fleet flaps), and this hook runs on EVERY page, so a `presence_diff`
  # only ARMS a 500ms trailing debounce (mirrors dashboard_live) — the recompute
  # runs at most ~2×/s per page, not once per flap. `presence_diff` is forwarded
  # (`:cont`) so a host LV that watches it (the dashboard) still reloads; the
  # internal `:recompute_fleet_offline` tick HALTS — no host LV expects it.
  defp refresh_fleet_offline(%{event: "presence_diff"}, socket),
    do: {:cont, schedule_fleet_recompute(socket)}

  defp refresh_fleet_offline(:recompute_fleet_offline, socket) do
    {:halt,
     Phoenix.Component.assign(socket, %{
       fleet_all_offline?: fleet_offline_for(socket.assigns[:current_subject]),
       fleet_recompute_scheduled?: false
     })}
  end

  defp refresh_fleet_offline(_msg, socket), do: {:cont, socket}

  defp schedule_fleet_recompute(socket) do
    if socket.assigns[:fleet_recompute_scheduled?] do
      socket
    else
      Process.send_after(self(), :recompute_fleet_offline, 500)
      Phoenix.Component.assign(socket, :fleet_recompute_scheduled?, true)
    end
  end

  defp resend_confirmation_email("resend_confirmation", _params, socket) do
    socket =
      case socket.assigns[:current_user] do
        %{confirmed_at: nil} = user ->
          :ok = Auth.deliver_confirmation_instructions(user)
          Phoenix.LiveView.put_flash(socket, :info, "Confirmation email sent to #{user.email}.")

        %{} ->
          Phoenix.LiveView.put_flash(socket, :info, "Your email is already confirmed.")

        _ ->
          socket
      end

    {:halt, socket}
  end

  defp resend_confirmation_email(_event, _params, socket), do: {:cont, socket}

  defp approval_count_for(nil), do: 0
  defp approval_count_for(subject), do: Emisar.Approvals.count_pending_approval_requests(subject)

  # Pack-trust badge counterpart: computed at mount (assign_new) and kept
  # live by `refresh_pending_packs` on the account's packs topic.
  defp pack_pending_count_for(nil), do: 0
  defp pack_pending_count_for(subject), do: Emisar.Catalog.count_pending_pack_versions(subject)

  # Fleet-offline alert: computed at mount (assign_new) and kept live by
  # `refresh_fleet_offline` on the account's runner-connections topic.
  defp fleet_offline_for(nil), do: false
  defp fleet_offline_for(subject), do: Emisar.Runners.fleet_all_offline?(subject)

  # "Connect an agent" nudge: no LLM agent (API key) on the account yet. Computed
  # at mount (assign_new); resolves once the first agent appears.
  defp no_agents_for(nil), do: false
  defp no_agents_for(subject), do: Emisar.ApiKeys.no_agents?(subject)

  defp mount_current_user(session, socket) do
    # When a parent LiveView already mounted the user, inherit both assigns
    # rather than re-hitting the DB (the assign_new contract). Otherwise
    # resolve the user AND its session provenance in ONE token lookup — the
    # auth map rides onto the Subject so every audit row records how the
    # operator signed in.
    if Map.has_key?(socket.assigns, :current_user) do
      Phoenix.Component.assign_new(socket, :current_auth, fn -> @no_auth end)
    else
      {user, auth} =
        with token when is_binary(token) <- session["user_token"],
             {:ok, user, auth} <- Auth.fetch_user_and_token_by_session_token(token) do
          {user, auth}
        else
          _ -> {nil, @no_auth}
        end

      socket
      |> Phoenix.Component.assign(:current_user, user)
      |> Phoenix.Component.assign(:current_auth, auth)
    end
  end

  defp mount_current_account(socket, session) do
    # Resolve everything in one shot so assign_new closures don't race
    # against the outer pipe's socket reference (assign_new captures
    # the socket at definition time, not at evaluation time).
    requested_id = session["current_account_id"]

    {account, membership, subject, switchable} =
      case socket.assigns[:current_user] do
        nil ->
          {nil, nil, nil, []}

        user ->
          case Accounts.fetch_membership_for_session(user, requested_id) do
            {:error, :not_found} ->
              {nil, nil, nil, []}

            {:ok, membership} ->
              subject =
                Subject.for_user(
                  user,
                  membership.account,
                  membership,
                  RequestContext.from_socket(socket),
                  auth_opts(socket.assigns)
                )

              {membership.account, membership, subject, load_switchable_accounts(subject)}
          end
      end

    socket
    |> Phoenix.Component.assign_new(:current_account, fn -> account end)
    |> Phoenix.Component.assign_new(:current_membership, fn -> membership end)
    |> Phoenix.Component.assign_new(:current_subject, fn -> subject end)
    |> Phoenix.Component.assign_new(:switchable_accounts, fn -> switchable end)
  end

  # All non-suspended accounts the subject's user can mount. Used by the
  # sidebar account switcher; cheap (one indexed lookup) so it's fine to
  # fetch on every LV mount.
  defp load_switchable_accounts(subject) do
    case Accounts.list_accounts_for_user(subject, page_size: 100) do
      {:ok, accounts, _meta} -> accounts
      _ -> []
    end
  end
end
