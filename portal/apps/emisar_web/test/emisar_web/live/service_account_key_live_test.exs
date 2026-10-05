defmodule EmisarWeb.ServiceAccountKeyLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.Repo

  defp key_path(account, membership),
    do: ~p"/app/#{account}/settings/service-accounts/#{membership.id}/keys/new"

  describe "creating a key for a service account" do
    test "an owner creates a key that acts as it and sees the secret once", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      service_account = Fixtures.Memberships.create_service_account(account_id: account.id)
      {:ok, lv, html} = live(conn, key_path(account, service_account))

      assert html =~ "Create an API key for Ryker"
      refute html =~ "Acts as"

      html =
        lv
        |> form("#api_key_form", %{"api_key" => %{"name" => "Ryker in production"}})
        |> render_submit()

      assert [%ApiKey{} = key] = Repo.all(ApiKey)
      assert key.name == "Ryker in production"
      assert key.created_by_membership_id == service_account.id
      assert key.issued_by_membership_id == owner.id
      assert html =~ "API key created"
      assert has_element?(lv, "#service-account-key-secret", "emk-")
      assert has_element?(lv, "#service-account-key-rpc-url")
      refute has_element?(lv, "#api_key_form")
    end

    test "a replayed submit after the secret is shown creates nothing more", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      service_account = Fixtures.Memberships.create_service_account(account_id: account.id)
      {:ok, lv, _html} = live(conn, key_path(account, service_account))

      lv |> form("#api_key_form", %{"api_key" => %{"name" => "Ryker"}}) |> render_submit()
      render_submit(lv, "create", %{"api_key" => %{"name" => "Ryker again"}})

      assert [%ApiKey{name: "Ryker"}] = Repo.all(ApiKey)
    end

    test "a blank name keeps the form with its error and creates nothing", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      service_account = Fixtures.Memberships.create_service_account(account_id: account.id)
      {:ok, lv, _html} = live(conn, key_path(account, service_account))

      html = lv |> form("#api_key_form", %{"api_key" => %{"name" => ""}}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(lv, "#api_key_form")
      assert Repo.all(ApiKey) == []
    end

    test "a service account removed after the page opened creates nothing and says so", %{
      conn: conn
    } do
      {conn, _owner, account} = register_and_log_in(conn)
      service_account = Fixtures.Memberships.create_service_account(account_id: account.id)
      {:ok, lv, _html} = live(conn, key_path(account, service_account))

      Fixtures.Memberships.mark_membership_as_deleted(service_account)

      html =
        lv
        |> form("#api_key_form", %{"api_key" => %{"name" => "Ryker bot"}})
        |> render_submit()

      assert html =~ "This service account is no longer available."
      assert has_element?(lv, ~s(#api_key_form input[value="Ryker bot"]))
      assert Repo.all(ApiKey) == []
    end

    test "an admin whose access doesn't cover the service account's creates nothing", %{
      conn: conn
    } do
      {_owner_conn, _owner, account} = register_and_log_in(conn)
      service_account = Fixtures.Memberships.create_service_account(account_id: account.id)
      {:ok, scoped} = RunnerAccess.restricted(["web"], [])

      admin =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
        |> Fixtures.Memberships.force_runner_access(scoped)

      {:ok, lv, _html} =
        build_conn()
        |> log_in_member(admin)
        |> live(key_path(account, service_account))

      html =
        lv
        |> form("#api_key_form", %{"api_key" => %{"name" => "Ryker"}})
        |> render_submit()

      assert html =~ "can reach runners or packs you can&#39;t"
      assert Repo.all(ApiKey) == []
    end

    test "a suspended service account, a person, or another workspace's opens nothing", %{
      conn: conn
    } do
      {conn, _owner, account} = register_and_log_in(conn)

      suspended =
        [account_id: account.id]
        |> Fixtures.Memberships.create_service_account()
        |> Fixtures.Memberships.suspend_membership()

      person = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      elsewhere = Fixtures.Memberships.create_service_account()
      dest = ~p"/app/#{account}/settings/service-accounts"

      for membership <- [suspended, person, elsewhere] do
        result = live(conn, key_path(account, membership))
        assert {:error, {:live_redirect, %{to: ^dest}}} = result
        assert {:ok, _lv, html} = follow_redirect(result, conn)
        assert html =~ "That service account isn&#39;t available to you."
      end
    end

    test "an operator can't open the page", %{conn: conn} do
      {_owner_conn, _owner, account} = register_and_log_in(conn)
      service_account = Fixtures.Memberships.create_service_account(account_id: account.id)
      operator = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      dest = ~p"/app/#{account}/settings/service-accounts"

      operator_conn = log_in_member(build_conn(), operator)
      result = live(operator_conn, key_path(account, service_account))

      assert {:error, {:live_redirect, %{to: ^dest}}} = result
      assert {:ok, _lv, html} = follow_redirect(result, operator_conn)
      assert html =~ "That service account isn&#39;t available to you."
    end
  end
end
