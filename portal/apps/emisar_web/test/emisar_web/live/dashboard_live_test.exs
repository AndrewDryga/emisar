defmodule EmisarWeb.DashboardLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app" do
    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app")
    end

    test "fresh accounts see the onboarding wizard with both checklist cards",
         %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app")

      # Two onboarding cards — runner + LLM — sit at the top of the
      # dashboard as a wizard checklist. The runner card links to
      # /app/runners/install where the actual install command lives.
      assert html =~ "Connect a runner"
      assert html =~ "Connect an LLM"

      # No auto-minted install key — the dashboard doesn't mint
      # anymore. The runners/install page mints when the operator
      # navigates into it.
      assert Emisar.Repo.all(Emisar.Runners.AuthKey) == []
    end

    test "renders the populated dashboard once a runner exists", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _agent} =
        Emisar.Runners.create_runner(
          %{
            "name" => "runner-1",
            "group" => "default"
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app")
      assert html =~ "Runners online"
      assert html =~ "Recent runs"
      # The runner-onboarding card disappears once a runner exists.
      refute html =~ "Connect a runner"
      # LLM onboarding card still shows — no API key was minted in
      # this test.
      assert html =~ "Connect an LLM"
    end
  end
end
