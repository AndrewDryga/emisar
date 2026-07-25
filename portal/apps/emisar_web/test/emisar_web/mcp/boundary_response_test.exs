defmodule EmisarWeb.MCP.BoundaryResponseTest do
  @moduledoc """
  The rate-limit reject fires before authentication and the suite-wide
  throttle disable keeps the controller path unreachable, so the reject is
  exercised directly. `async: false` — the log assertion raises the
  application log level, which is global.
  """
  use EmisarWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  alias EmisarWeb.MCP.BoundaryResponse

  test "a rate-limited request logs one safe reject event and keeps the envelope" do
    :ok = Logger.put_application_level(:emisar_web, :info)
    on_exit(fn -> Logger.delete_application_level(:emisar_web) end)

    request = %{"jsonrpc" => "2.0", "id" => "rl-1", "method" => "tools/call", "params" => %{}}
    conn = build_conn(:post, "/api/mcp/rpc", request)

    {conn, log} =
      with_log([level: :info], fn ->
        BoundaryResponse.rate_limited(conn, 60)
      end)

    assert conn.halted
    assert conn.status == 429

    assert Jason.decode!(conn.resp_body) == %{
             "jsonrpc" => "2.0",
             "id" => "rl-1",
             "error" => %{"code" => -32_000, "message" => "Too many requests. Retry in 60s."}
           }

    assert length(String.split(log, "mcp.dispatch_rejected")) == 2
    assert log =~ "mcp_dispatch_reject_reason=rate_limited"
    assert log =~ "mcp_tool=unknown"
    refute log =~ "mcp_action_id"
    refute log =~ "mcp_pack_ref"
  end
end
