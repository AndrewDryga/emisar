defmodule EmisarWeb.StaffAuth do
  @moduledoc """
  The staff realm's web boundary: the staff cookie as the session of every staff
  route, the request and socket gates on `/admin` and `/ops/live`, and staff
  sign-in and sign-out.

  Nothing here reads the workspace session or `EmisarWeb.UserAuth`, and nothing
  there reads this realm. A staff session is minted only by
  `Emisar.Admin.complete_staff_sign_in/5`, travels only in the staff cookie, and
  is re-checked against its row on every request and mount and before every
  root LiveView event and patch. Ending a session (sign-out, a box reset or
  removal) disconnects its sockets through the `live_socket_id` the sign-in
  stores, and a connected socket leaves on its own when the session expires.
  """
  use EmisarWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias Emisar.Admin

  @staff_socket_path "/admin/live"

  @doc """
  Used in router, first in `:staff_browser`: makes the staff cookie this
  request's whole Plug session. The endpoint configures the workspace session
  for every request but only lazily, so installing this store before anything
  fetches a session means a staff request never reads or writes the workspace
  cookie. A request that already holds a session is refused rather than risk
  writing staff state into the workspace cookie.
  """
  def use_staff_session_cookie(conn, _opts) do
    if Map.has_key?(conn.private, :plug_session) do
      raise ArgumentError, "a session was fetched before the staff session store was installed"
    end

    conn
    |> Plug.Session.call(Plug.Session.init(EmisarWeb.Endpoint.staff_session_options()))
    |> fetch_session()
  end

  @doc """
  Used in router: staff pages connect their LiveViews to the staff socket, whose
  session is the staff cookie. The root layout hands this path to `app.js`.
  """
  def put_staff_live_socket_path(conn, _opts),
    do: assign(conn, :live_socket_path, @staff_socket_path)

  @doc "Used in router: assigns `:staff_session`, the live staff session or nil."
  def fetch_current_staff(conn, _opts) do
    raw_token = get_session(conn, :staff_token)

    case live_staff_session(raw_token) do
      {:ok, staff_session} -> assign(conn, :staff_session, staff_session)
      :error -> assign(conn, :staff_session, nil)
    end
  end

  @doc """
  Used in router: the gate on every staff page. Without a live staff session the
  request goes to the staff sign-in, and a dead token leaves the cookie.
  """
  def require_staff(conn, _opts) do
    cond do
      conn.assigns[:staff_session] ->
        conn

      get_session(conn, :staff_token) ->
        conn
        |> delete_session(:staff_token)
        |> put_flash(:error, "Your staff session has ended. Sign in again.")
        |> redirect(to: ~p"/admin/sign_in")
        |> halt()

      true ->
        conn |> redirect(to: ~p"/admin/sign_in") |> halt()
    end
  end

  @doc "Used in router: a signed-in staff browser skips the sign-in pages."
  def redirect_if_staff(conn, _opts) do
    if conn.assigns[:staff_session],
      do: conn |> redirect(to: ~p"/admin") |> halt(),
      else: conn
  end

  @doc """
  Starts the staff session `raw_token` in this browser. The staff cookie is
  renewed and cleared first, so nothing from before the sign-in (the pending
  code, the old CSRF token) survives into the session.
  """
  def log_in_staff(conn, raw_token) when is_binary(raw_token) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:staff_token, raw_token)
    |> put_session(:live_socket_id, Admin.staff_session_socket_topic(raw_token))
    |> redirect(to: ~p"/admin")
  end

  @doc "Ends this browser's staff session, disconnects its sockets, and drops the staff cookie."
  def log_out_staff(conn) do
    if raw_token = get_session(conn, :staff_token) do
      :ok = Admin.delete_staff_session(raw_token)
      EmisarWeb.Endpoint.broadcast(Admin.staff_session_socket_topic(raw_token), "disconnect", %{})
    end

    delete_csrf_token()

    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/admin/sign_in")
  end

  @doc """
  The socket gate for every staff LiveView, LiveDashboard included. The request
  gate only covers the dead render, so the mount re-reads the session from the
  staff cookie's socket session. A connected socket then re-checks the row before
  every root event and patch, and leaves when the session expires. LiveComponent
  events skip root hooks, which is one reason LiveDashboard's destructive
  actions stay off; revocation still reaches those sockets as a disconnect.
  """
  def on_mount(:ensure_staff, _params, session, socket) do
    raw_token = session["staff_token"]

    case live_staff_session(raw_token) do
      {:ok, staff_session} ->
        socket =
          socket
          |> Phoenix.Component.assign(:staff_session, staff_session)
          |> watch_staff_session(staff_session)

        {:cont, socket}

      :error when is_binary(raw_token) ->
        {:halt, staff_session_ended(socket)}

      :error ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/admin/sign_in")}
    end
  end

  defp live_staff_session(raw_token) when is_binary(raw_token) do
    case Admin.fetch_staff_session(raw_token) do
      {:ok, staff_session} -> {:ok, staff_session}
      {:error, :not_found} -> :error
    end
  end

  defp live_staff_session(_raw_token), do: :error

  defp watch_staff_session(socket, staff_session) do
    if Phoenix.LiveView.connected?(socket) do
      Process.send_after(
        self(),
        {:staff_session_expired, staff_session.id},
        milliseconds_until(staff_session.expires_at)
      )

      socket
      |> Phoenix.LiveView.attach_hook(:staff_session_event, :handle_event, &recheck_on_event/3)
      |> Phoenix.LiveView.attach_hook(:staff_session_params, :handle_params, &recheck_on_patch/3)
      |> Phoenix.LiveView.attach_hook(:staff_session_expiry, :handle_info, &staff_session_info/2)
    else
      socket
    end
  end

  defp recheck_on_event(_event, _params, socket), do: recheck_staff_session(socket)

  defp recheck_on_patch(_params, _uri, socket), do: recheck_staff_session(socket)

  defp staff_session_info({:staff_session_expired, id}, socket) do
    if socket.assigns.staff_session.id == id,
      do: {:halt, staff_session_ended(socket)},
      else: {:halt, socket}
  end

  defp staff_session_info(_message, socket), do: {:cont, socket}

  defp recheck_staff_session(socket) do
    case Admin.refresh_staff_session(socket.assigns.staff_session) do
      {:ok, staff_session} ->
        {:cont, Phoenix.Component.assign(socket, :staff_session, staff_session)}

      {:error, :not_found} ->
        {:halt, staff_session_ended(socket)}
    end
  end

  defp staff_session_ended(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, "Your staff session has ended. Sign in again.")
    |> Phoenix.LiveView.redirect(to: ~p"/admin/sign_in")
  end

  defp milliseconds_until(%DateTime{} = at),
    do: max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0)
end
