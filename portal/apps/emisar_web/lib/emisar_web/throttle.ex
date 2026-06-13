defmodule EmisarWeb.Throttle do
  @moduledoc """
  Web-layer abuse gate over `EmisarWeb.RateLimiter`.

  The single place that honors the `:rate_limit_enabled` switch — off in
  the test env so the fast suite never trips shared ETS counters — so the
  route plug (`EmisarWeb.Plugs.RateLimit`) and the LiveView event handlers
  that can't sit behind a plug (magic-link / password-reset sends arrive
  over the socket) share one on/off semantics.

  Returns `:ok | {:error, :rate_limited}`; the caller decides how to
  reject — HTTP 429, a flash, or a silent skip behind a uniform response.
  """

  @spec check(term(), term(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def check(bucket, key, limit, window_ms) do
    if enabled?() do
      EmisarWeb.RateLimiter.check({bucket, key}, limit, window_ms)
    else
      :ok
    end
  end

  defp enabled?, do: Application.get_env(:emisar_web, :rate_limit_enabled, true)
end
