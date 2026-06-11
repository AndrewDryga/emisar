defmodule EmisarWeb.InstallControllersTest do
  @moduledoc """
  The public install endpoints serve the compile-time-embedded repo
  scripts (`curl … | sh` is the documented onboarding path), so the
  bytes must be a runnable shell script, not an HTML error page.
  """
  use EmisarWeb.ConnCase, async: true

  test "GET /install.sh serves the embedded runner installer", %{conn: conn} do
    conn = get(conn, ~p"/install.sh")

    assert response_content_type(conn, :"x-shellscript") =~ "text/x-shellscript"
    assert "#!/" <> _ = response(conn, 200)
  end

  test "GET /install-mcp.sh serves the embedded MCP installer", %{conn: conn} do
    conn = get(conn, ~p"/install-mcp.sh")

    assert response_content_type(conn, :"x-shellscript") =~ "text/x-shellscript"
    assert "#!/" <> _ = response(conn, 200)
  end
end
