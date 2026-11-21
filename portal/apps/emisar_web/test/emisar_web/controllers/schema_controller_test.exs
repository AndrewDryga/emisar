defmodule EmisarWeb.SchemaControllerTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Runbooks

  describe "GET /schemas/runbook-definition-v1.json" do
    test "serves the runbook-definition schema at the $id it declares", %{conn: conn} do
      conn = get(conn, ~p"/schemas/runbook-definition-v1.json")
      body = json_response(conn, 200)

      # The whole point: the schema resolves at the exact URL its own $id names,
      # so a validator following that URL gets the real contract.
      assert body["$id"] == "https://emisar.dev/schemas/runbook-definition-v1.json"
      assert body == Runbooks.definition_schema()
    end

    test "is cached briefly and revalidated against its content ETag", %{conn: conn} do
      first = get(conn, ~p"/schemas/runbook-definition-v1.json")

      assert get_resp_header(first, "cache-control") == [
               "public, max-age=3600, must-revalidate"
             ]

      assert [etag] = get_resp_header(first, "etag")

      revalidated =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get(~p"/schemas/runbook-definition-v1.json")

      assert revalidated.status == 304
      assert revalidated.resp_body == ""

      changed =
        build_conn()
        |> put_req_header("if-none-match", ~s("stale"))
        |> get(~p"/schemas/runbook-definition-v1.json")

      assert json_response(changed, 200) == Runbooks.definition_schema()
    end
  end
end
