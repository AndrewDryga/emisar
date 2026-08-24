defmodule Emisar.SSO.OIDC.Guard.Relay do
  @moduledoc """
  The bounded opaque-byte relay behind `Emisar.SSO.OIDC.Guard`.

  One process owns both sockets, so a single counter covers both directions.
  The caller supplies the absolute monotonic deadline captured when the tunnel
  was accepted; idle time is a separate, shorter bound.
  """
  require Logger

  @idle_timeout 15_000

  @doc "Relay opaque TLS bytes in both directions until a transport or budget boundary wins."
  def run(client, origin, deadline, max_bytes) do
    with :ok <- :inet.setopts(client, active: :once),
         :ok <- :inet.setopts(origin, active: :once) do
      relay(client, origin, deadline, max_bytes, 0)
    else
      {:error, reason} -> close(client, origin, reason)
    end
  end

  defp relay(client, origin, deadline, max_bytes, transferred) do
    if expired?(deadline) do
      close(client, origin, :tunnel_lifetime_exceeded)
    else
      receive do
        {:tcp, ^client, data} ->
          forward(client, origin, data, client, origin, deadline, max_bytes, transferred)

        {:tcp, ^origin, data} ->
          forward(origin, client, data, client, origin, deadline, max_bytes, transferred)

        {:tcp_closed, _socket} ->
          close_both(client, origin)

        {:tcp_error, _socket, _reason} ->
          close_both(client, origin)
      after
        min(@idle_timeout, remaining(deadline)) ->
          reason =
            if expired?(deadline),
              do: :tunnel_lifetime_exceeded,
              else: :tunnel_idle_timeout

          close(client, origin, reason)
      end
    end
  end

  defp forward(source, destination, data, client, origin, deadline, max_bytes, transferred) do
    next_transferred = transferred + byte_size(data)

    cond do
      expired?(deadline) ->
        close(client, origin, :tunnel_lifetime_exceeded)

      next_transferred > max_bytes ->
        close(client, origin, :tunnel_byte_budget_exceeded)

      true ->
        with :ok <- send_with_deadline(destination, data, deadline),
             :ok <- :inet.setopts(source, active: :once) do
          relay(client, origin, deadline, max_bytes, next_transferred)
        else
          {:error, reason} -> close(client, origin, reason)
        end
    end
  end

  defp send_with_deadline(socket, data, deadline) do
    with :ok <- ensure_time_remaining(deadline),
         :ok <-
           :inet.setopts(socket,
             send_timeout: remaining(deadline),
             send_timeout_close: true
           ) do
      :gen_tcp.send(socket, data)
    end
  end

  defp close(client, origin, reason) do
    case reason do
      :tunnel_lifetime_exceeded -> Logger.warning("OIDC guard closed a tunnel at its lifetime")
      :tunnel_byte_budget_exceeded -> Logger.warning("OIDC guard closed an oversized tunnel")
      :tunnel_idle_timeout -> Logger.warning("OIDC guard closed an idle tunnel")
      _transport_error -> :ok
    end

    close_both(client, origin)
    {:error, reason}
  end

  defp close_both(client, origin) do
    :gen_tcp.close(client)
    :gen_tcp.close(origin)
  end

  defp ensure_time_remaining(deadline) do
    if expired?(deadline), do: {:error, :timeout}, else: :ok
  end

  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)
end
