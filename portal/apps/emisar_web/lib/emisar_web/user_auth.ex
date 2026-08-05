defmodule EmisarWeb.UserAuth do
  @moduledoc """
  Authentication plug + LiveView hooks. Sessions are signed cookies
  carrying a session-token; the token is looked up in `user_tokens` on
  each request. Stale session tokens are rejected by the Auth token expiry check.
  """

  use EmisarWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias Emisar.{Accounts, Auth, Marketing, Runners}
  alias Emisar.Auth.Subject
  alias EmisarWeb.{Analytics, MarketingAttribution}
  alias EmisarWeb.RequestContext

  # Session provenance for an unauthenticated request — no method, no SSO
  # identity. `fetch_user_and_token_by_session_token/1` returns the `%UserToken{}`
  # on a hit; this is the miss/anonymous default the Subject build reads from.
  @no_auth %{auth_method: nil, mfa: nil, user_identity_id: nil}

  # -- Public surface -------------------------------------------------

  @doc """
  Installs the magic-link session `Emisar.Auth` already minted — factor one
  only, so the analytics provenance is fixed here at `:magic_link` / `mfa:
  false` and no caller can widen it. `user` and `token` are the pair the domain
  returned from one locked transaction; the boundary only puts the token in the
  cookie, renews the session ID (CSRF defence in depth), and redirects.
  `registered?` is true for the FIRST sign-in after a registration, which fires
  sign_up_completed.
  """
  def log_in_magic_link_user(conn, user, token, registered?),
    do: finish_log_in(conn, user, token, :magic_link, false, registered?)

  @doc """
  Installs the magic-link session `Emisar.Auth` minted after the second factor
  passed — same as `log_in_magic_link_user/4` but with `mfa: true` provenance,
  fixed here so no caller can claim a factor it didn't verify.
  """
  def log_in_magic_link_mfa_user(conn, user, token, registered?),
    do: finish_log_in(conn, user, token, :magic_link, true, registered?)

  @doc """
  Completes an SSO sign-in under the account lifecycle lock. `mfa` says whether
  the IdP satisfies the second factor; `opts` carry the `:user_identity_id` the
  session is bound to plus the JIT-provisioning `:registered?` flag. Returns
  `{:error, :account_disabled}` when support disabled the account before the
  session credential could be inserted.
  """
  def log_in_sso_user_for_account(conn, user, account_id, mfa, opts \\ []) do
    {registered?, opts} = Keyword.pop(opts, :registered?, false)
    context = RequestContext.from_conn(conn)

    case Auth.complete_sso_account_sign_in(user, account_id, mfa, context, opts) do
      {:ok, token} ->
        {:ok, finish_log_in(conn, user, token, :sso, mfa, registered?)}

      {:error, :account_disabled} = error ->
        error

      {:error, reason} ->
        raise "could not complete SSO sign-in: #{inspect(reason)}"
    end
  end

  defp finish_log_in(conn, user, token, auth_method, mfa, registered?) do
    user_return_to = get_session(conn, :user_return_to)
    attribution = MarketingAttribution.current(conn)
    if registered?, do: Marketing.account_signed_up(user, attribution)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_flash_just_registered(user, registered?)
    |> Analytics.track_authentication(user, auth_method, mfa, registered?, attribution)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  # The first sign-in right after registering (magic-link round-trip or SSO JIT).
  # The confirmation email already went out at sign-up; the verify-email banner
  # (not this flash) nudges an unconfirmed account, so just welcome them.
  defp maybe_flash_just_registered(conn, _user, true) do
    put_flash(conn, :info, "Welcome to emisar! Your workspace is ready.")
  end

  defp maybe_flash_just_registered(conn, _user, false), do: conn

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

  @doc """
  Voluntary sign-out: the domain ends the presented session (row delete + the
  `user.signed_out` audit, one transaction), then the boundary clears the cookie
  and drops the live sockets. The raw cookie value is the only attribution the
  domain gets — `current_user` is this request's snapshot, not the credential
  being revoked.
  """
  def log_out_user(conn) do
    :ok = complete_sign_out(get_session(conn, :user_token), conn)

    if live_socket_id = get_session(conn, :live_socket_id) do
      EmisarWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> Analytics.track_sign_out()
    |> renew_session()
    |> redirect(to: ~p"/")
  end

  # A rolled-back sign-out must not reach the browser as a completed one, so the
  # cookie clear, the socket disconnect, and the redirect are all downstream of
  # this. No cookie value means there is nothing durable to end.
  defp complete_sign_out(token, conn) when is_binary(token) do
    case Auth.complete_session_sign_out(token, RequestContext.from_conn(conn)) do
      :ok -> :ok
      {:error, reason} -> raise "could not complete sign-out: #{inspect(reason)}"
    end
  end

  defp complete_sign_out(_token, _conn), do: :ok

  # -- Plugs ----------------------------------------------------------

  @doc "Fetch the current user from the session token."
  def fetch_current_user(conn, _opts) do
    {user, auth} =
      with token when is_binary(token) <- get_session(conn, :user_token),
           {:ok, user, auth} <- Auth.fetch_user_and_token_by_session_token(token) do
        {user, auth}
      else
        _ -> {nil, @no_auth}
      end

    conn
    |> assign(:current_user, user)
    |> assign(:current_auth, auth)
  end

  @doc "Used in router/pipeline: redirects unauthenticated requests to login."
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      assign_current_account(conn)
    else
      conn
      |> put_flash(:error, "You must sign in to access that page.")
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

  @doc """
  Builds a `%Subject{}` for the signed-in user against an explicit account ref
  (id or slug), independent of the session's current account. The OAuth consent
  screen lets the operator pick which account an MCP client is granted, so the
  grant must be authorized against the CHOSEN account's membership — never the
  session default the form rode in on. Resolves only the user's own
  non-suspended memberships; anything else is `{:error, :not_found}`,
  indistinguishable from a nonexistent tenant. Carries the same request context
  and session auth provenance as `assign_current_account/1`.
  """
  def subject_for_account(conn, account_ref) do
    user = conn.assigns.current_user

    with {:ok, membership} <- Accounts.fetch_membership_by_account_id_or_slug(user, account_ref) do
      context = RequestContext.from_conn(conn)

      {:ok,
       Subject.for_user(user, membership.account, membership, context, auth_opts(conn.assigns))}
    end
  end

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
  Pins an already-validated membership's account in the session. `membership`
  comes from `Accounts.switch_account/2`, which owns the validation and the
  audit row; the web boundary only carries the decision into the session.
  """
  def switch_account(conn, %Accounts.Membership{} = membership),
    do: put_session(conn, :current_account_id, membership.account_id)

  @doc """
  FORCED invalidation (delete the token, disconnect live sockets, renew the
  session) with an error flash and a redirect to `to`. Drives the
  suspended-account bounce (default `/sign_in`) and the require_sso step-up,
  which lands the user on that account's branded sign-in. The operator didn't
  choose to leave, so this rides `Auth.delete_session_token/1` and writes no
  `user.signed_out` audit — `log_out_user/1` owns the voluntary sign-out. The
  flash is set AFTER renew_session, so it survives to the next request.
  """
  def log_out_user_with_flash(conn, message, to \\ ~p"/sign_in") do
    user_token = get_session(conn, :user_token)
    user_token && Auth.delete_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      EmisarWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> put_flash(:error, message)
    |> redirect(to: to)
  end

  defp signed_in_path(_conn), do: ~p"/app"

  # -- LiveView on_mount hooks ----------------------------------------

  # Flags that this render needs the full `app.js` (LiveSocket + hooks).
  # Attached to every LiveView via `EmisarWeb.live_view/0`, so the dead
  # render carries `@app_js?` up to `root.html.heex`; controller-rendered
  # marketing pages never set it and get the lean `marketing.js` instead.
  # A LIVE-navigated tab keeps executing the JS bundle it loaded until a FULL
  # page load — after a deploy, markup (fresh, over the socket) skews against
  # hooks (stale), which has shipped "the feature doesn't work" reports twice
  # (the time tooltip, the combobox corner fusion). When the connect params'
  # tracked statics no longer match the digest manifest, break out of live
  # navigation by redirecting to the SAME url — a full load with the new
  # bundle. No-op in dev/test (no digest manifest → static_changed? is false).
  def on_mount(:reload_stale_assets, _params, _session, socket) do
    if Phoenix.LiveView.static_changed?(socket) do
      {:cont,
       Phoenix.LiveView.attach_hook(
         socket,
         :stale_asset_reload,
         :handle_params,
         fn _params, uri, socket ->
           {:halt, Phoenix.LiveView.redirect(socket, external: uri)}
         end
       )}
    else
      {:cont, socket}
    end
  end

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
        |> Phoenix.LiveView.put_flash(:error, "You must sign in to access that page.")
        |> Phoenix.LiveView.redirect(to: ~p"/sign_in")

      {:halt, socket}
    end
  end

  # The LiveDashboard's socket gate. The :require_admin PIPELINE only guards the
  # dead render; a LiveView session stays verifiable for 14 days, so without an
  # on_mount hook a revoked admin could replay one and reconnect to DB stats and
  # the process list. Re-reads the user from the session token on every mount.
  def on_mount(:ensure_admin, _params, session, socket) do
    socket = mount_current_user(session, socket)

    case socket.assigns.current_user do
      %{is_admin: true} ->
        {:cont, socket}

      _ ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "Not authorized.")
          |> Phoenix.LiveView.redirect(to: ~p"/app")

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

    with {:ok, membership} <- Accounts.fetch_membership_by_account_id_or_slug(user, account_ref),
         {:ok, membership} <-
           subscribe_and_refetch_account(socket, user, account_ref, membership) do
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
       )
       |> Phoenix.LiveView.attach_hook(
         :account_lifecycle,
         :handle_info,
         &handle_account_lifecycle/2
       )}
    else
      {:error, :not_found} ->
        raise EmisarWeb.NotFoundError
    end
  end

  # require_sso enforcement (approach B). Composed AFTER :ensure_account_slug, so
  # current_account + the subject carrying the session's auth provenance are set.
  # Delegates the decision to `Accounts.ensure_account_compliant/2` (shared with
  # the controller-route plug); on a step-up it bounces to the /sso_required
  # shim, which logs the session out and lands on the account's branded sign-in
  # (a LiveView on_mount can't clear the plug session itself).
  def on_mount(:ensure_sso_compliant, _params, _session, socket) do
    account = socket.assigns[:current_account]

    case Accounts.ensure_account_compliant(account, socket.assigns.current_subject) do
      {:error, :sso_required} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/#{account}/sso_required")}

      result when result in [:ok, {:error, :mfa_required}] ->
        {:cont, socket}

      {:error, reason} when reason in [:not_found, :unauthorized] ->
        raise EmisarWeb.NotFoundError
    end
  end

  # Account-wide MFA enforcement. Composed AFTER :ensure_authenticated so
  # current_account is mounted. Delegates to `Accounts.ensure_account_compliant/2`
  # (shared with the controller-route plug); a non-enrolled member of a
  # require_mfa account is funnelled to /app/mfa_setup with no error flash (the
  # setup page explains the enforcement and walks them through enrollment). The
  # profile page is the one exception — the voluntary MFA setup UI lives there,
  # so a member must be able to LOAD it while still un-enrolled (a LOCATION
  # exemption, layered here rather than in the shared policy).
  def on_mount(:ensure_mfa_compliant, _params, _session, socket) do
    account = socket.assigns[:current_account]
    subject = socket.assigns[:current_subject]

    ensure_mfa_compliant(socket, account, subject)
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
  # `presence_diff` so host pages can patch their visible state, but `{:halt}`s
  # its own topology-recompute tick.
  def on_mount(:track_pending_approvals, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket) and socket.assigns[:current_account] do
      account_id = socket.assigns.current_account.id
      subject = socket.assigns[:current_subject]

      if subject && Emisar.Approvals.subject_can_view_approvals?(subject),
        do: Emisar.Approvals.subscribe_account_approvals(account_id)

      if subject && Emisar.Catalog.subject_can_view_packs?(subject),
        do: Emisar.Catalog.subscribe_account_packs(account_id)

      if subject && Runners.subject_can_view_runners?(subject),
        do: Runners.subscribe_connections(account_id)

      {:cont,
       socket
       |> Phoenix.Component.assign(:pending_approvals_count, approval_count_for(subject))
       |> Phoenix.Component.assign(:pending_packs_count, pack_pending_count_for(subject))
       |> Phoenix.Component.assign(:fleet_all_offline?, fleet_offline_for(subject))
       |> Phoenix.Component.assign(:no_agents?, no_agents_for(subject))
       |> Phoenix.Component.assign(:onboarding_incomplete?, onboarding_incomplete_for(subject))
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
      # Dead mount (and the no-account edge): rest the nav cues at their empty
      # state — the connected mount above computes the real counts + subscribes,
      # so these four reads run once per live socket, not on the dead render too.
      {:cont,
       socket
       |> Phoenix.Component.assign(:pending_approvals_count, 0)
       |> Phoenix.Component.assign(:pending_packs_count, 0)
       |> Phoenix.Component.assign(:fleet_all_offline?, false)
       |> Phoenix.Component.assign(:no_agents?, false)
       |> Phoenix.Component.assign(:onboarding_incomplete?, false)}
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

  defp ensure_mfa_compliant(%{view: EmisarWeb.ProfileLive} = socket, _account, _subject),
    do: {:cont, socket}

  defp ensure_mfa_compliant(socket, account, subject) do
    case Accounts.ensure_account_compliant(account, subject) do
      {:error, :mfa_required} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/mfa_setup")}

      {:error, :sso_required} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/#{account}/sso_required")}

      :ok ->
        {:cont, socket}

      {:error, reason} when reason in [:not_found, :unauthorized] ->
        raise EmisarWeb.NotFoundError
    end
  end

  defp subscribe_and_refetch_account(socket, user, account_ref, membership) do
    if Phoenix.LiveView.connected?(socket) do
      :ok = Accounts.subscribe_account_lifecycle(membership.account_id)
      Accounts.fetch_membership_by_account_id_or_slug(user, account_ref)
    else
      {:ok, membership}
    end
  end

  defp handle_account_lifecycle(
         {:account_disabled, account_id},
         %{assigns: %{current_account: %{id: account_id}}} = socket
       ),
       do: {:halt, socket}

  defp handle_account_lifecycle(_message, socket), do: {:cont, socket}

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

  # Heartbeats update Presence metadata without changing fleet connectivity.
  # Recompute the nav alert only for join-only or leave-only topology changes;
  # host LiveViews still receive the diff to patch their own visible state.
  defp refresh_fleet_offline(%{event: "presence_diff"} = event, socket) do
    change = Runners.normalize_connection_change(event)

    if Runners.connection_topology_changed?(change) do
      {:cont, schedule_fleet_recompute(socket)}
    else
      {:cont, socket}
    end
  end

  defp refresh_fleet_offline(:recompute_fleet_offline, socket) do
    subject = socket.assigns[:current_subject]

    {:halt,
     Phoenix.Component.assign(socket, %{
       fleet_all_offline?: fleet_offline_for(subject),
       # A runner registering clears the onboarding nudge live (it depends on
       # any_runners?, which the same presence event just flipped).
       onboarding_incomplete?: onboarding_incomplete_for(subject),
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

  # Pack-decision badge counterpart: computed at mount (assign_new) and kept
  # live by `refresh_pending_packs` on the account's packs topic. Counts
  # every version awaiting a decision — pending trust reviews AND
  # retired-blocked trusted versions.
  defp pack_pending_count_for(nil), do: 0

  defp pack_pending_count_for(subject),
    do: Emisar.Catalog.count_pack_versions_needing_decision(subject)

  # Fleet-offline alert: computed at mount (assign_new) and kept live by
  # `refresh_fleet_offline` on the account's runner-connections topic.
  defp fleet_offline_for(nil), do: false
  defp fleet_offline_for(subject), do: Runners.fleet_all_offline?(subject)

  # "Connect an agent" nudge (the LLM-agents nav dot): no agent key yet AND the
  # fleet exists — a brand-new account's first job is a runner, so nudging
  # agents before any host is connected points at the wrong next step.
  defp no_agents_for(nil), do: false

  defp no_agents_for(subject),
    do: Emisar.ApiKeys.no_agents?(subject) and Runners.any_runners?(subject)

  # "Finish onboarding" nudge (the Dashboard nav dot): the account has neither a
  # runner NOR an LLM agent yet, so it can't do anything — a fresh workspace's
  # very first step. Adding EITHER a runner or an agent clears it. (Distinct from
  # the two dots above, which nudge the *next* step once one exists.)
  defp onboarding_incomplete_for(nil), do: false

  defp onboarding_incomplete_for(subject),
    do: not Runners.any_runners?(subject) and Emisar.ApiKeys.no_agents?(subject)

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
