defmodule EmisarWeb.UserAuth do
  @moduledoc """
  Authentication plug + LiveView hooks. Sessions are signed cookies
  carrying a session-token; the token is looked up in `user_tokens` on
  each request. Stale 60d => garbage-collect (handled by Oban).
  """

  use EmisarWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Emisar.{Auth, Accounts}
  alias Emisar.Auth.Subject

  @remember_me_cookie "_emisar_user_remember_me"

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
  Logs in `user`, persisting the session token in the cookie, and
  optionally setting the "remember me" cookie. Always renews the
  session ID (CSRF defence in depth) and redirects.
  """
  def log_in_user(conn, user, params \\ %{}) do
    token =
      Auth.create_session_token!(user, %{
        ip_address: normalize_ip(forwarded_for(conn) || peer_ip(conn)),
        user_agent: List.first(get_req_header(conn, "user-agent"))
      })

    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

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
    if user = conn.assigns[:current_user], do: Auth.record_sign_out(user)
    user_token && Auth.delete_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      EmisarWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  # -- Plugs ----------------------------------------------------------

  @doc "Fetch the current user from the session/cookie token."
  def fetch_current_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)

    user =
      with token when is_binary(token) <- user_token,
           {:ok, user} <- Auth.fetch_user_by_session_token(token) do
        user
      else
        _ -> nil
      end

    assign(conn, :current_user, user)
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
    requested_account_id = get_session(conn, :current_account_id)

    case Accounts.fetch_membership_for_session(user, requested_account_id) do
      {:error, :not_found} ->
        cond do
          Accounts.all_memberships_suspended?(user) ->
            conn
            |> log_out_user_with_flash("Your access has been suspended. Contact your team admin.")
            |> halt()

          true ->
            conn
            |> put_flash(:error, "You don't belong to any account. Create one to continue.")
            |> redirect(to: ~p"/onboarding")
            |> halt()
        end

      {:ok, membership} ->
        context = conn_context(conn)

        conn
        |> maybe_refresh_account_session(membership.account_id, requested_account_id)
        |> assign(:current_account, membership.account)
        |> assign(:current_membership, membership)
        |> assign(
          :current_subject,
          Subject.for_user(user, membership.account, membership, context)
        )
    end
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

  # Same as log_out_user/1 but lets the caller stamp a specific flash
  # message before the session is renewed.
  defp log_out_user_with_flash(conn, message) do
    user_token = get_session(conn, :user_token)
    user_token && Auth.delete_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      EmisarWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign_in")
  end

  defp conn_context(conn) do
    %{
      ip_address: normalize_ip(forwarded_for(conn) || peer_ip(conn)),
      user_agent: List.first(get_req_header(conn, "user-agent")),
      request_id: List.first(get_resp_header(conn, "x-request-id"))
    }
  end

  defp forwarded_for(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [val | _] -> val |> String.split(",") |> List.first() |> String.trim()
      [] -> nil
    end
  end

  defp peer_ip(%{remote_ip: ip}) when is_tuple(ip),
    do: ip |> :inet_parse.ntoa() |> to_string()

  defp peer_ip(_), do: nil

  # IPv6-listener sockets surface IPv4 clients as `::ffff:N.N.N.N`
  # (the IPv4-mapped IPv6 encoding). Operators don't care about the
  # wrapper — strip it so audit columns show `1.2.3.4`, not the
  # awkward 20-character form that overflows the column.
  defp normalize_ip(nil), do: nil
  defp normalize_ip("::ffff:" <> ip4), do: ip4
  defp normalize_ip(ip), do: ip

  defp signed_in_path(_conn), do: ~p"/app"

  # -- LiveView on_mount hooks ----------------------------------------

  # Flags that this render needs the full `app.js` (LiveSocket + hooks).
  # Attached to every LiveView via `EmisarWeb.live_view/0`, so the dead
  # render carries `@app_js?` up to `root.html.heex`; controller-rendered
  # marketing pages never set it and get the lean `marketing.js` instead.
  def on_mount(:assign_app_bundle, _params, _session, socket) do
    {:cont, Phoenix.Component.assign(socket, :app_js?, true)}
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

    cond do
      is_nil(user) or is_nil(account) ->
        {:cont, socket}

      not account.require_mfa ->
        {:cont, socket}

      user.mfa_enabled_at != nil ->
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

  # Stashes IP + user agent from the WebSocket connect into the
  # LiveView process's audit metadata. Set once at mount; persists for
  # the lifetime of the LV process so every `handle_event/3` that calls
  # into the business layer gets the right IP without further plumbing.
  #
  # Requires `:peer_data` and `:user_agent` to be listed in the
  # endpoint's `socket "/live"` `connect_info`.
  def on_mount(:audit_meta, _params, _session, socket) do
    peer = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)

    Emisar.Audit.put_request_metadata(%{
      ip_address: normalize_ip(format_peer_ip(peer)),
      user_agent: user_agent
    })

    {:cont, socket}
  end

  # Tracks the account's pending-approval AND pending-pack-trust counts
  # so both sidebar badges stay live across every authenticated LV
  # without each one re-implementing the subscribe/handle_info dance.
  #
  # First connect computes the counts + subscribes to the account's
  # approvals and packs topics; `attach_hook`s then refresh whenever a
  # request is created/decided or a pack flips pending/resolved. The
  # approvals hook returns `{:cont, ...}` so the host LV's own
  # `handle_info/2` (e.g. reload the approvals table) still runs; the
  # packs hook `{:halt}`s — no host LV needs that message forwarded.
  def on_mount(:track_pending_approvals, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign_new(:pending_approvals_count, fn ->
        approval_count_for(socket.assigns[:current_subject])
      end)
      |> Phoenix.Component.assign_new(:pending_packs_count, fn ->
        pack_pending_count_for(socket.assigns[:current_subject])
      end)

    if Phoenix.LiveView.connected?(socket) and socket.assigns[:current_account] do
      account_id = socket.assigns.current_account.id
      Emisar.Approvals.subscribe_account_approvals(account_id)
      Emisar.Catalog.subscribe_account_packs(account_id)

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

  defp format_peer_ip(%{address: ip}) when is_tuple(ip),
    do: ip |> :inet_parse.ntoa() |> to_string()

  defp format_peer_ip(_), do: nil

  defp mount_current_user(session, socket) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      with token when is_binary(token) <- session["user_token"],
           {:ok, user} <- Auth.fetch_user_by_session_token(token) do
        user
      else
        _ -> nil
      end
    end)
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
              subject = Subject.for_user(user, membership.account, membership, %{})
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
