defmodule EmisarWeb.InstallControllersTest do
  @moduledoc """
  The public install endpoints serve the compile-time-embedded repo
  scripts (`curl … | sh` is the documented onboarding path), so the
  bytes must be a runnable shell script, not an HTML error page.
  """
  use EmisarWeb.ConnCase, async: true

  # The compile-time-embedded copy must match the live repo file byte-for-
  # byte — a drift means `curl https://emisar.dev/install.sh | sudo bash`
  # would run stale onboarding bytes. Mix runs the suite from the app dir
  # (apps/emisar_web); the repo root (where install*.sh live) is three up.
  @repo_root Path.expand("../../..", File.cwd!())

  test "GET /install.sh serves the embedded runner installer", %{conn: conn} do
    conn = get(conn, ~p"/install.sh")

    assert response_content_type(conn, :"x-shellscript") =~ "text/x-shellscript"
    assert "#!/" <> _ = response(conn, 200)
  end

  test "GET /install.sh is byte-identical to the repo-root install.sh", %{conn: conn} do
    body = conn |> get(~p"/install.sh") |> response(200)
    assert body == File.read!(Path.join(@repo_root, "install.sh"))
  end

  test "GET /install.sh ignores junk query params", %{conn: conn} do
    body = conn |> get(~p"/install.sh?x=1") |> response(200)
    assert body == File.read!(Path.join(@repo_root, "install.sh"))
  end

  test "GET /install-mcp.sh serves the embedded MCP installer", %{conn: conn} do
    conn = get(conn, ~p"/install-mcp.sh")

    assert response_content_type(conn, :"x-shellscript") =~ "text/x-shellscript"
    assert "#!/" <> _ = response(conn, 200)
  end

  test "GET /install-mcp.sh is byte-identical to the repo-root install-mcp.sh", %{conn: conn} do
    body = conn |> get(~p"/install-mcp.sh") |> response(200)
    assert body == File.read!(Path.join(@repo_root, "install-mcp.sh"))
  end

  test "GET /install-mcp.sh ignores junk query params", %{conn: conn} do
    body = conn |> get(~p"/install-mcp.sh?x=1") |> response(200)
    assert body == File.read!(Path.join(@repo_root, "install-mcp.sh"))
  end
end
