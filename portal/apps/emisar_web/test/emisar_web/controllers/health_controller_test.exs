defmodule EmisarWeb.HealthControllerTest do
  use EmisarWeb.ConnCase, async: false

  @live_after_ready {EmisarWeb.HealthController, :live_after_ready}

  setup do
    :persistent_term.erase(@live_after_ready)
    check = start_supervised!({Agent, fn -> {:error, :database_unavailable} end})
    previous = Application.get_env(:emisar_web, :database_health_check)

    Application.put_env(:emisar_web, :database_health_check, fn ->
      Agent.get(check, & &1)
    end)

    on_exit(fn ->
      :persistent_term.erase(@live_after_ready)

      if previous do
        Application.put_env(:emisar_web, :database_health_check, previous)
      else
        Application.delete_env(:emisar_web, :database_health_check)
      end
    end)

    %{check: check}
  end

  test "liveness gates initial rollout but stays independent after first readiness", %{
    conn: conn,
    check: check
  } do
    assert %{"status" => "error"} = json_response(get(conn, ~p"/healthz"), 503)

    Agent.update(check, fn _ -> {:ok, %{rows: [[1]]}} end)
    assert %{"status" => "ok"} = json_response(get(conn, ~p"/healthz"), 200)

    Agent.update(check, fn _ -> {:error, :database_unavailable} end)
    assert %{"status" => "ok"} = json_response(get(conn, ~p"/healthz"), 200)
    assert %{"status" => "error"} = json_response(get(conn, ~p"/readyz"), 503)
  end

  test "healthz reports the running version for the deploy reconciler", %{
    conn: conn,
    check: check
  } do
    Agent.update(check, fn _ -> {:ok, %{rows: [[1]]}} end)

    expected_version = EmisarWeb.AppVersion.version()

    assert %{"status" => "ok", "version" => ^expected_version} =
             json_response(get(conn, ~p"/healthz"), 200)
  end
end
