defmodule Emisar.Fixtures.Throttle do
  @moduledoc """
  Capped, unique test keys for flows that must exercise the real abuse gate.
  """

  @doc "Cap the current and next fixed window so a clock edge cannot undo setup."
  def cap(bucket, key, limit, window_ms) do
    window = div(System.system_time(:millisecond), window_ms)

    rows =
      Enum.map(window..(window + 1), fn index ->
        {{{bucket, key}, index}, limit, (index + 1) * window_ms}
      end)

    true = :ets.insert(Emisar.RateLimiter, rows)
    :ok
  end
end
