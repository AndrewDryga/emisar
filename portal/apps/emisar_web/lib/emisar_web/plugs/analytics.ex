defmodule EmisarWeb.Plugs.Analytics do
  @moduledoc """
  Server-side funnel pageview tracking. On an eligible browser GET it fires a
  `page_viewed` once the response is known to be a 200 HTML render. Writes no
  session state — the anonymous id is a cookieless daily hash (see
  `EmisarWeb.Analytics`). No-op for non-GET requests and `/app/*` — console
  usage is captured as product events, not pageviews (see
  `Emisar.Analytics.Events`).
  """

  @behaviour Plug

  import Plug.Conn

  alias EmisarWeb.Analytics

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if eligible?(conn) do
      register_before_send(conn, &track_if_rendered/1)
    else
      conn
    end
  end

  defp track_if_rendered(conn) do
    if conn.status == 200 and html?(conn), do: Analytics.track_pageview(conn)
    conn
  end

  # Off ⇒ a complete no-op (no `page_viewed`), so the analytics HTTP calls only
  # happen when the feature is live.
  defp eligible?(conn) do
    Emisar.Analytics.enabled?() and conn.method == "GET" and not console_path?(conn)
  end

  defp console_path?(%{path_info: ["app" | _]}), do: true
  defp console_path?(_conn), do: false

  defp html?(conn) do
    case get_resp_header(conn, "content-type") do
      [content_type | _] -> String.contains?(content_type, "text/html")
      _ -> false
    end
  end
end
