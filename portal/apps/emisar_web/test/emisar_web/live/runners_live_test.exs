defmodule EmisarWeb.RunnersLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/runners" do
    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/runners")
    end

    test "shows the empty state when no runners are registered", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/runners")
      assert html =~ "No runners yet"
      assert html =~ "Open install wizard"
    end

    test "the dead/pre-connect empty render shows a loading placeholder, not the pitch",
         %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)

      # A plain GET is the disconnected render — connected?/1 is false, so the
      # onboarding pitch is deferred behind a loading placeholder.
      html = conn |> get(~p"/app/runners") |> html_response(200)
      assert html =~ "Loading"
      refute html =~ "No runners yet"
    end

    test "lists runners grouped by their `group` field", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _} =
        Emisar.Runners.create_runner(%{"name" => "a1", "group" => "cassandra-us-east1"}, subject)

      {:ok, _} =
        Emisar.Runners.create_runner(%{"name" => "a2", "group" => "cassandra-us-east1"}, subject)

      {:ok, _} =
        Emisar.Runners.create_runner(%{"name" => "b1", "group" => "postgres-eu-west1"}, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/runners")
      assert html =~ "cassandra-us-east1"
      assert html =~ "postgres-eu-west1"
      assert html =~ "a1"
      assert html =~ "b1"
    end

    test "the fleet health strip summarizes the whole account's runner states", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      Emisar.Fixtures.runner_fixture(account_id: account.id, connected?: true)
      disabled = Emisar.Fixtures.runner_fixture(account_id: account.id, connected?: true)
      {:ok, _} = Emisar.Runners.disable_runner(disabled, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/runners")

      # The strip names each state (Offline always shows, even at 0) + the
      # whole-account total: 1 online + 1 disabled = 2 runners.
      assert html =~ "Online"
      assert html =~ "Offline"
      assert html =~ "Disabled"
      assert html =~ "2 runners total"
    end
  end

  describe "GET /app/runners/install" do
    test "always renders the install wizard with a pre-minted command",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      # Pre-existing runner shouldn't bypass the wizard — the user can
      # add a second runner the same way as the first.
      {:ok, _} =
        Emisar.Runners.create_runner(
          %{
            "name" => "existing",
            "group" => "default"
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/runners/install")
      assert html =~ "Install a runner"
      assert html =~ "Connect a runner"
      assert html =~ "curl -sSL"
      assert html =~ "EMISAR_AUTH_KEY=emkey-auth-"

      # The command embeds a live root-capable credential — the wizard must
      # say so (won't reshow, treat like a password) and let the operator
      # read the script before running it, not just on the marketing page.
      assert html =~ "Live credential"
      assert html =~ "Treat it like a password"
      assert html =~ "read it first"
      assert html =~ ~s(href="/install.sh")
    end

    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} =
               live(conn, ~p"/app/runners/install")
    end
  end

  describe "GET /app/runners/:id" do
    test "404-redirects when the runner does not belong to the account", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)

      assert {:error, {:live_redirect, %{to: "/app/runners"}}} =
               live(conn, ~p"/app/runners/#{Ecto.UUID.generate()}")
    end

    test "renders the runner detail page", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, runner} =
        Emisar.Runners.create_runner(
          %{
            "name" => "my-runner",
            "group" => "default"
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/runners/#{runner.id}")
      assert html =~ "my-runner"
      assert html =~ "Advertised actions"
    end
  end
end
