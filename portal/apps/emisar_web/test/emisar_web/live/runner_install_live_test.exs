defmodule EmisarWeb.RunnerInstallLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/runners/install" do
    test "renders the install one-liner and copies it with its leading space", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/install")

      assert html =~ "curl -sSL"

      # The Copy button copies the literal command via data-copy-text,
      # including the intentional leading space (keeps the auth key out of
      # shell history under HISTCONTROL=ignorespace). Regression: copying
      # via the element's innerText used to strip that leading space.
      assert html =~ ~s(data-copy-text=" curl -sSL)
    end
  end
end
