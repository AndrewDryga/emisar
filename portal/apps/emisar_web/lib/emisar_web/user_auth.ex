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

  @remember_me_cookie "_emisar_user_remember_me"
  @remember_me_options [
    encrypt: true,
    max_age: 60 * 60 * 24 * 60,
    same_site: "Lax",
    http_only: true,
    secure: Application.compile_env(:emisar_web, :force_secure_cookies, false)
  ]

  # -- Public surface -------------------------------------------------

  @doc """
  Logs in `user`, persisting the session token in the cookie, and
  optionally setting the "remember me" cookie. Always renews the
  session ID (CSRF defence in depth) and redirects.
  """
  def log_in_user(conn, user, params \\ %{}) do
    token = Auth.create_session_token(user)
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
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
    user = user_token && Auth.get_user_by_session_token(user_token)
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

    case Accounts.primary_membership(user) do
      nil ->
        conn
        |> put_flash(:error, "You don't belong to any account. Create one to continue.")
        |> redirect(to: ~p"/onboarding")
        |> halt()

      membership ->
        conn
        |> assign(:current_account, membership.account)
        |> assign(:current_membership, membership)
    end
  end

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

  defp mount_current_user(session, socket) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if user_token = session["user_token"] do
        Auth.get_user_by_session_token(user_token)
      end
    end)
  end

  defp mount_current_account(socket) do
    Phoenix.Component.assign_new(socket, :current_account, fn ->
      if user = socket.assigns[:current_user] do
        case Accounts.primary_membership(user) do
          nil -> nil
          membership -> membership.account
        end
      end
    end)
    |> Phoenix.Component.assign_new(:current_membership, fn ->
      if user = socket.assigns[:current_user] do
        Accounts.primary_membership(user)
      end
    end)
  end
end
