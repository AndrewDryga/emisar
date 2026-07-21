defmodule EmisarWeb.DomainVerificationControllerTest do
  use EmisarWeb.ConnCase, async: true

  @openai_apps_challenge "Akvd3R_a96uO5bgjAFCuvVd4rEZI7ZFPXLnLIRHEmpU"

  test "GET /.well-known/openai-apps-challenge serves the exact OpenAI proof", %{conn: conn} do
    conn = get(conn, "/.well-known/openai-apps-challenge")

    assert response(conn, 200) == @openai_apps_challenge
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end
end
