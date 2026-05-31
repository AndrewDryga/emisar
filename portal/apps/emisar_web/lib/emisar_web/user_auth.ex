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
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end

  @doc "Sign-out: invalidate the session token and clear the cookie."
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
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

    case Accounts.fetch_primary_membership_for_user(user) do
      {:error, :not_found} ->
        cond do
          Accounts.all_memberships_suspended?(user) ->
            conn
            |> log_out_user_with_flash(
              "Your access has been suspended. Contact your team admin."
            )
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
        |> assign(:current_account, membership.account)
        |> assign(:current_membership, membership)
        |> assign(:current_subject, Subject.for_user(user, membership.account, membership, context))
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

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(session, socket)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(session, socket)

    if socket.assigns.current_user do
      {:cont, mount_current_account(socket)}
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
        socket =
          socket
          |> Phoenix.LiveView.put_flash(
            :error,
            "Your account requires two-factor authentication. Set it up to continue."
          )
          |> Phoenix.LiveView.redirect(to: ~p"/app/settings/profile")

        {:halt, socket}
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

  defp mount_current_account(socket) do
    # Resolve everything in one shot so assign_new closures don't race
    # against the outer pipe's socket reference (assign_new captures
    # the socket at definition time, not at evaluation time).
    {account, membership, subject} =
      case socket.assigns[:current_user] do
        nil ->
          {nil, nil, nil}

        user ->
          case Accounts.fetch_primary_membership_for_user(user) do
            {:error, :not_found} ->
              {nil, nil, nil}

            {:ok, membership} ->
              {membership.account, membership,
               Subject.for_user(user, membership.account, membership, %{})}
          end
      end

    socket
    |> Phoenix.Component.assign_new(:current_account, fn -> account end)
    |> Phoenix.Component.assign_new(:current_membership, fn -> membership end)
    |> Phoenix.Component.assign_new(:current_subject, fn -> subject end)
  end
end
