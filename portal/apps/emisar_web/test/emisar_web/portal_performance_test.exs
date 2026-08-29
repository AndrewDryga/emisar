defmodule EmisarWeb.PortalPerformanceTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias EmisarWeb.PortalPerformance
  alias Phoenix.LiveView.Socket

  test "emits bounded navigation measurements with server-owned view metadata" do
    handler = attach_telemetry([:emisar, :portal, :browser, :navigation])
    on_exit(fn -> :telemetry.detach(handler) end)
    socket = %Socket{view: EmisarWeb.AgentsLive}

    assert {:halt, reported_socket} =
             PortalPerformance.handle_event(
               "portal_performance",
               %{
                 "kind" => "navigation",
                 "duration_ms" => 187,
                 "dom_bytes" => 92_500,
                 "transport" => "websocket"
               },
               socket
             )

    assert_receive {:portal_performance, %{duration_ms: 187, dom_bytes: 92_500}, metadata}
    assert metadata == %{transport: :websocket, view: "EmisarWeb.AgentsLive"}
    assert reported_socket.private[PortalPerformance].navigation == 1
  end

  test "records a normalized fallback reason without the browser error payload" do
    handler = attach_telemetry([:emisar, :portal, :browser, :transport_fallback])
    on_exit(fn -> :telemetry.detach(handler) end)
    socket = %Socket{view: EmisarWeb.AuditLive}

    log =
      capture_log(fn ->
        assert {:halt, reported_socket} =
                 PortalPerformance.handle_event(
                   "portal_performance",
                   %{
                     "kind" => "transport_fallback",
                     "elapsed_ms" => 2_501,
                     "reason" => "timeout",
                     "error" => "must never be logged"
                   },
                   socket
                 )

        assert reported_socket.private[PortalPerformance].fallback?
      end)

    assert_receive {:portal_performance, %{count: 1, elapsed_ms: 2_501}, metadata}
    assert metadata == %{reason: :timeout, view: "EmisarWeb.AuditLive"}
    assert log =~ "reason=timeout"
    refute log =~ "must never be logged"
  end

  test "drops forged labels and out-of-range measurements" do
    handler = attach_telemetry([:emisar, :portal, :browser, :navigation])
    on_exit(fn -> :telemetry.detach(handler) end)
    socket = %Socket{view: EmisarWeb.TeamLive}

    assert {:halt, ^socket} =
             PortalPerformance.handle_event(
               "portal_performance",
               %{
                 "kind" => "navigation",
                 "duration_ms" => 600_001,
                 "dom_bytes" => 1,
                 "transport" => "attacker-controlled-label"
               },
               socket
             )

    refute_receive {:portal_performance, _, _}
  end

  defp attach_telemetry(event) do
    test_pid = self()
    handler = {__MODULE__, test_pid, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:portal_performance, measurements, metadata})
        end,
        nil
      )

    handler
  end
end
