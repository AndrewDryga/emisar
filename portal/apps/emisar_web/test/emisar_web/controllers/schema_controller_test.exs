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

    test "is cached as immutable — a new version ships at a new URL", %{conn: conn} do
      conn = get(conn, ~p"/schemas/runbook-definition-v1.json")

      assert get_resp_header(conn, "cache-control") == [
               "public, max-age=31536000, immutable"
             ]
    end
  end
end
