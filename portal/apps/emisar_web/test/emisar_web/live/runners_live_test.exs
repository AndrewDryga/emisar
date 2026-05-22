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
      assert html =~ "Issue an auth key"
    end

    test "lists runners grouped by their `group` field", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _} = Emisar.Runners.create_runner(account.id, %{"name" => "a1", "group" => "cassandra-us-east1"})
      {:ok, _} = Emisar.Runners.create_runner(account.id, %{"name" => "a2", "group" => "cassandra-us-east1"})
      {:ok, _} = Emisar.Runners.create_runner(account.id, %{"name" => "b1", "group" => "postgres-eu-west1"})

      {:ok, _lv, html} = live(conn, ~p"/app/runners")
      assert html =~ "cassandra-us-east1"
      assert html =~ "postgres-eu-west1"
      assert html =~ "a1"
      assert html =~ "b1"
    end
  end

  describe "GET /app/runners/:id" do
    test "404-redirects when the runner does not belong to the account", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)

      assert {:error, {:live_redirect, %{to: "/app/runners"}}} =
               live(conn, ~p"/app/runners/#{Ecto.UUID.generate()}")
    end

    test "renders the runner detail page", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, runner} =
        Emisar.Runners.create_runner(account.id, %{
          "name" => "my-runner",
          "group" => "default"
        })

      {:ok, _lv, html} = live(conn, ~p"/app/runners/#{runner.id}")
      assert html =~ "my-runner"
      assert html =~ "Advertised actions"
    end
  end
end
