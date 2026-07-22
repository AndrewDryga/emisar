defmodule Emisar.PublicUrl do
  @moduledoc """
  The app's public base URL — the single source of truth for absolute
  links built outside a request (mailer bodies and Paddle success/cancel
  URLs).

  Reproduces `EmisarWeb.Endpoint.url/0` from the shared
  `:emisar_web, EmisarWeb.Endpoint` config so callers in the `emisar`
  context app can build the same string without compile-coupling to
  `EmisarWeb`. Honors the configured scheme, host, and port and elides
  the default port (443/80) exactly as Phoenix does, so a single host
  config drives every absolute URL the app emits.
  """

  @doc "The public base URL, e.g. `https://emisar.dev` — no trailing slash."
  def base do
    url = Emisar.Config.get_env(:emisar_web, EmisarWeb.Endpoint, []) |> Keyword.get(:url, [])

    %URI{
      scheme: Keyword.get(url, :scheme, "http"),
      host: Keyword.get(url, :host, "localhost"),
      port: Keyword.get(url, :port)
    }
    |> URI.to_string()
  end

  @doc "The base URL with `path` appended. `path` should start with `/`."
  def url(path) when is_binary(path), do: base() <> path
end
