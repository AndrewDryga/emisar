defmodule EmisarWeb.Plugs.ErrorContentSecurityPolicy do
  @moduledoc """
  Adds a static CSP to responses rendered by the endpoint error handler.

  Phoenix renders endpoint errors outside router pipelines, so those responses
  cannot receive the normal per-request CSP plug. Existing pipeline CSP headers
  are preserved for errors raised after a pipeline has run.
  """
  @behaviour Plug

  import Plug.Conn

  @error_content_security_policy "default-src 'self'; object-src 'none'; frame-ancestors 'none'"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: register_before_send(conn, &put_error_content_security_policy/1)

  defp put_error_content_security_policy(%{status: status} = conn)
       when is_integer(status) and status >= 400 and status < 600 do
    if get_resp_header(conn, "content-security-policy") == [] do
      put_resp_header(conn, "content-security-policy", @error_content_security_policy)
    else
      conn
    end
  end

  defp put_error_content_security_policy(conn), do: conn
end
