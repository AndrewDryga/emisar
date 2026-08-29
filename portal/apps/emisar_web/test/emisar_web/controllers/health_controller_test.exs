defmodule EmisarWeb.HealthControllerTest do
  use EmisarWeb.ConnCase, async: true

  setup do
    check = start_supervised!({Agent, fn -> {:error, :database_unavailable} end})

    Emisar.Config.put_override(:emisar, :database_health_check, fn ->
      Agent.get(check, & &1)
    end)

    %{check: check}
  end

  test "liveness stays independent while readiness tracks the database", %{
    conn: conn,
    check: check
  } do
    assert %{"status" => "ok"} = json_response(get(conn, ~p"/healthz"), 200)
    assert %{"status" => "error"} = json_response(get(conn, ~p"/readyz"), 503)

    Agent.update(check, fn _ -> {:ok, %{rows: [[1]]}} end)
    assert %{"status" => "ok"} = json_response(get(conn, ~p"/readyz"), 200)
  end

  test "healthz reports the running version but withholds the source revision", %{conn: conn} do
    expected_version = EmisarWeb.AppVersion.version()

    body = json_response(get(conn, ~p"/healthz"), 200)

    assert body == %{"status" => "ok", "version" => expected_version}
    refute Map.has_key?(body, "revision")
  end
end
