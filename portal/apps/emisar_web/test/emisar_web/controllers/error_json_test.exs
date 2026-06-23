defmodule EmisarWeb.ErrorJSONTest do
  use EmisarWeb.ConnCase, async: true

  test "renders 404" do
    assert EmisarWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert EmisarWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end

  test "an unrouted JSON request yields the structured 404 through the endpoint", %{conn: conn} do
    # closes CFG-013-T03
    # Not just the renderer in isolation: a real request whose Accept is
    # application/json must come back as the structured error shape (never
    # the HTML page, never a struct/stacktrace), proving the endpoint wires
    # ErrorJSON for the json format.
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get("/no-such-path")

    assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
  end
end
