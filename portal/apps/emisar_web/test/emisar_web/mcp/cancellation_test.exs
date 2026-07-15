defmodule EmisarWeb.MCP.CancellationTest do
  use EmisarWeb.ConnCase, async: true
  alias EmisarWeb.MCP.Cancellation

  test "cancellation is scoped to the API key and private generation token", %{conn: conn} do
    request_conn = scoped_conn(conn, "key-a", "generation-a")
    parent = self()

    task =
      Task.async(fn ->
        Cancellation.track(request_conn, "tools/call", fn _tracked_conn ->
          send(parent, {:tracking, self()})

          receive do
            {:mcp_request_cancelled, _topic} = cancellation ->
              send(self(), cancellation)
              :finished
          end
        end)
      end)

    assert_receive {:tracking, task_pid}

    :ok = Cancellation.cancel(scoped_conn(conn, "key-a", "generation-b"))
    :ok = Cancellation.cancel(scoped_conn(conn, "key-b", "generation-a"))
    assert Process.alive?(task_pid)

    :ok = Cancellation.cancel(request_conn)
    assert Task.await(task) == :cancelled
  end

  test "bridge generation tokens override a reused JSON-RPC id", %{conn: conn} do
    request_conn =
      conn
      |> scoped_conn("key-a", "generation-1")
      |> put_req_header("x-emisar-mcp-request-token", "generation-2")

    parent = self()

    task =
      Task.async(fn ->
        Cancellation.track(request_conn, "tools/call", fn _tracked_conn ->
          send(parent, {:tracking, self()})

          receive do
            {:mcp_request_cancelled, _topic} = cancellation ->
              send(self(), cancellation)
              :finished
          end
        end)
      end)

    assert_receive {:tracking, task_pid}
    :ok = Cancellation.cancel(scoped_conn(conn, "key-a", "generation-1"))
    assert Process.alive?(task_pid)

    cancel_conn = put_req_header(request_conn, "x-emisar-mcp-cancel-token", "generation-2")
    :ok = Cancellation.cancel(cancel_conn)
    assert Task.await(task) == :cancelled
  end

  test "a successor may cancel its immediate predecessor but not an ancestor", %{conn: conn} do
    request_conn = scoped_conn(conn, "key-a", "generation-a")
    parent = self()

    task =
      Task.async(fn ->
        Cancellation.track(request_conn, "tools/call", fn _tracked_conn ->
          send(parent, {:tracking, self()})

          receive do
            {:mcp_request_cancelled, _topic} = cancellation ->
              send(self(), cancellation)
              :finished
          end
        end)
      end)

    assert_receive {:tracking, task_pid}

    :ok =
      Cancellation.cancel(scoped_conn(conn, "key-c", "generation-a", "key-b"))

    assert Process.alive?(task_pid)

    :ok =
      Cancellation.cancel(scoped_conn(conn, "key-b", "generation-a", "key-a"))

    assert Task.await(task) == :cancelled
  end

  test "initialize is never cancellable", %{conn: conn} do
    conn = scoped_conn(conn, "key-a", "generation-a")

    assert Cancellation.track(conn, "initialize", &Cancellation.topic/1) == nil
  end

  test "a cancellation that arrives before tracking is retained and then cleaned", %{conn: conn} do
    conn = scoped_conn(conn, "key-a", "pretracked-generation")

    for _attempt <- 1..2 do
      :ok = Cancellation.cancel(conn)

      assert Cancellation.track(conn, "tools/call", fn _conn ->
               flunk("a pre-cancelled request must not dispatch")
             end) == :cancelled

      assert Cancellation.track(conn, "tools/call", fn _conn -> :completed end) ==
               :completed
    end
  end

  test "native stateless requests without private tokens are not cross-cancellable", %{conn: conn} do
    conn =
      conn
      |> assign(:api_key, %{id: "key-a", replaces_id: nil})
      |> assign(:current_subject, %{account: %{id: "account-a"}})

    assert Cancellation.track(conn, "tools/call", &Cancellation.topic/1) == nil
    assert Cancellation.cancel(conn) == :ok
  end

  defp scoped_conn(conn, key_id, generation, replaces_id \\ nil) do
    conn
    |> assign(:api_key, %{id: key_id, replaces_id: replaces_id})
    |> assign(:current_subject, %{account: %{id: "account-a"}})
    |> put_req_header("x-emisar-mcp-request-token", generation)
    |> put_req_header("x-emisar-mcp-cancel-token", generation)
  end
end
