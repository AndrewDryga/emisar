defmodule EmisarWeb.RecentAccounts do
  @moduledoc """
  Remembers the accounts a browser has signed into, in a signed cookie, so the
  sign-on landing page can offer them as one-click buttons (no need to retype a
  team's address). Stores `%{"slug" => ..., "name" => ...}` entries — slug + name
  are not secrets and the cookie is signed (tamper-proof), so a stale/forged
  cookie can at worst surface a team the browser already chose. Capped + most-
  recent-first; a rename (support-only) just goes stale until the next sign-in.
  """
  @cookie "emisar_recent_accounts"
  @max 5
  # A year — long enough that a returning operator still sees their team.
  @max_age 60 * 60 * 24 * 365

  # `secure` follows the `:force_secure_cookies` runtime knob (runtime.exs):
  # forced on behind HTTPS, off so local dev over http://localhost still returns
  # the cookie. A hardcoded `secure: true` would silently drop the recent-teams
  # buttons in dev.
  defp opts do
    [
      sign: true,
      max_age: @max_age,
      same_site: "Lax",
      http_only: true,
      secure: Emisar.Config.get_env(:emisar_web, :force_secure_cookies, false)
    ]
  end

  @doc "The remembered accounts (most-recent-first), or `[]`. Reads the signed cookie."
  def list(conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@cookie])

    case conn.cookies[@cookie] do
      entries when is_list(entries) -> entries
      _ -> []
    end
  end

  @doc "Record an account as most-recently-used (dedup by slug, capped). Writes the signed cookie."
  def put(conn, %{slug: slug, name: name}) when is_binary(slug) do
    entry = %{"slug" => slug, "name" => name}
    rest = Enum.reject(list(conn), &(&1["slug"] == slug))
    Plug.Conn.put_resp_cookie(conn, @cookie, Enum.take([entry | rest], @max), opts())
  end
end
