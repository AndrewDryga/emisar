defmodule EmisarWeb.MCP.CancellationTest do
  use EmisarWeb.ConnCase, async: true
  alias EmisarWeb.MCP.Cancellation

  test "cancellation is scoped to the API key, session, and typed request id", %{conn: conn} do
    request_conn = scoped_conn(conn, "key-a", "session-a")
    parent = self()

    task =
      Task.async(fn ->
        Cancellation.track(request_conn, "tools/call", 7, fn _tracked_conn ->
          send(parent, {:tracking, self()})

          receive do
            {:mcp_request_cancelled, _topic} = cancellation ->
              send(self(), cancellation)
              :finished
          end
        end)
      end)

    assert_receive {:tracking, task_pid}

    :ok = Cancellation.cancel(scoped_conn(conn, "key-a", "session-b"), %{"requestId" => 7})
    :ok = Cancellation.cancel(request_conn, %{"requestId" => "7"})
    assert Process.alive?(task_pid)

    :ok = Cancellation.cancel(request_conn, %{"requestId" => 7})
    assert Task.await(task) == :cancelled
  end

  test "bridge generation tokens override a reused JSON-RPC id", %{conn: conn} do
    request_conn =
      conn
      |> scoped_conn("key-a", "session-a")
      |> put_req_header("x-emisar-mcp-request-token", "generation-2")

    parent = self()

    task =
      Task.async(fn ->
        Cancellation.track(request_conn, "tools/call", "reused", fn _tracked_conn ->
          send(parent, {:tracking, self()})

          receive do
            {:mcp_request_cancelled, _topic} = cancellation ->
              send(self(), cancellation)
              :finished
          end
        end)
      end)

    assert_receive {:tracking, task_pid}
    :ok = Cancellation.cancel(scoped_conn(conn, "key-a", "session-a"), %{"requestId" => "reused"})
    assert Process.alive?(task_pid)

    cancel_conn = put_req_header(request_conn, "x-emisar-mcp-cancel-token", "generation-2")
    :ok = Cancellation.cancel(cancel_conn, %{"requestId" => "reused"})
    assert Task.await(task) == :cancelled
  end

  test "initialize is never cancellable", %{conn: conn} do
    conn = scoped_conn(conn, "key-a", "session-a")

    assert Cancellation.track(conn, "initialize", 1, &Cancellation.topic/1) == nil
  end

  test "a cancellation that arrives before tracking is retained and then cleaned", %{conn: conn} do
    conn = scoped_conn(conn, "key-a", "pretracked-session")

    for request_id <- ["late-start", ""] do
      :ok = Cancellation.cancel(conn, %{"requestId" => request_id})

      assert Cancellation.track(conn, "tools/call", request_id, fn _conn ->
               flunk("a pre-cancelled request must not dispatch")
             end) == :cancelled

      assert Cancellation.track(conn, "tools/call", request_id, fn _conn -> :completed end) ==
               :completed
    end
  end

  defp scoped_conn(conn, key_id, session_id) do
    conn
    |> assign(:api_key, %{id: key_id})
    |> assign(:current_subject, %{account: %{id: "account-a"}})
    |> put_req_header("mcp-session-id", session_id)
  end
end
