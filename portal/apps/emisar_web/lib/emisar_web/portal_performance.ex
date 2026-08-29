defmodule EmisarWeb.PortalPerformance do
  @moduledoc """
  Receives coarse browser performance reports from the authenticated console.

  Browser reports are untrusted hints, not billing or audit evidence. Only
  bounded numbers and closed enums reach telemetry or logs; URLs, account ids,
  rendered content, socket payloads, and transport errors never do.
  """
  alias Phoenix.LiveView
  require Logger

  @max_navigation_ms 600_000
  @max_dom_bytes 20_000_000
  @max_navigation_reports 500
  @transports %{"websocket" => :websocket, "long_poll" => :long_poll, "unknown" => :unknown}
  @fallback_reasons %{
    "memorized" => :memorized,
    "timeout" => :timeout,
    "error" => :error,
    "close" => :close,
    "unknown" => :unknown
  }

  @doc false
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> put_report_state(%{fallback?: false, navigation: 0})
      |> LiveView.attach_hook(__MODULE__, :handle_event, &__MODULE__.handle_event/3)

    {:cont, socket}
  end

  @doc false
  def handle_event(
        "portal_performance",
        %{
          "kind" => "navigation",
          "duration_ms" => duration_ms,
          "dom_bytes" => dom_bytes,
          "transport" => transport
        },
        socket
      ) do
    socket =
      with {:ok, duration_ms} <- bounded_integer(duration_ms, @max_navigation_ms),
           {:ok, dom_bytes} <- bounded_integer(dom_bytes, @max_dom_bytes),
           {:ok, transport} <- Map.fetch(@transports, transport),
           %{navigation: reports} = state when reports < @max_navigation_reports <-
             report_state(socket) do
        :telemetry.execute(
          [:emisar, :portal, :browser, :navigation],
          %{duration_ms: duration_ms, dom_bytes: dom_bytes},
          %{transport: transport, view: inspect(socket.view)}
        )

        put_report_state(socket, %{state | navigation: reports + 1})
      else
        _ -> socket
      end

    {:halt, socket}
  end

  def handle_event(
        "portal_performance",
        %{
          "kind" => "transport_fallback",
          "elapsed_ms" => elapsed_ms,
          "reason" => reason
        },
        socket
      ) do
    socket =
      with {:ok, elapsed_ms} <- bounded_integer(elapsed_ms, @max_navigation_ms),
           {:ok, reason} <- Map.fetch(@fallback_reasons, reason),
           %{fallback?: false} = state <- report_state(socket) do
        view = inspect(socket.view)

        :telemetry.execute(
          [:emisar, :portal, :browser, :transport_fallback],
          %{count: 1, elapsed_ms: elapsed_ms},
          %{reason: reason, view: view}
        )

        Logger.warning(
          "browser transport fell back to long poll: " <>
            "reason=#{reason} elapsed_ms=#{elapsed_ms} live_view=#{view} source=browser_untrusted"
        )

        put_report_state(socket, %{state | fallback?: true})
      else
        _ -> socket
      end

    {:halt, socket}
  end

  def handle_event("portal_performance", _params, socket), do: {:halt, socket}
  def handle_event(_event, _params, socket), do: {:cont, socket}

  defp bounded_integer(value, max) when is_integer(value) and value >= 0 and value <= max,
    do: {:ok, value}

  defp bounded_integer(_value, _max), do: :error

  defp report_state(socket),
    do: Map.get(socket.private, __MODULE__, %{fallback?: false, navigation: 0})

  defp put_report_state(socket, state), do: LiveView.put_private(socket, __MODULE__, state)
end
