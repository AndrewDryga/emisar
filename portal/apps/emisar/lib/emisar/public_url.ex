defmodule Emisar.PublicUrl do
  @moduledoc """
  The app's public base URL — the single source of truth for absolute
  links built outside a request (mailer bodies and Paddle success/cancel
  URLs).

  Reads the domain-owned `:emisar, :public_url` config — a
  `[scheme:, host:, port:]` keyword every config file binds once and
  feeds to both this module and the endpoint's `url:`, so one origin
  drives every absolute URL the app emits. Honors the configured
  scheme, host, and port and elides the default port (443/80) exactly
  as Phoenix does.
  """

  @doc "The public base URL, e.g. `https://emisar.dev` — no trailing slash."
  def base do
    url = Emisar.Config.get_env(:emisar, :public_url, [])

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
