defmodule EmisarWeb.PacksLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/packs" do
    test "redirects anonymous users", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/packs")
    end

    test "renders the empty state when the account has no pack observations", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/packs")

      assert html =~ "Packs"
      assert html =~ "No packs reported yet"
    end
  end

  describe "trust decisions" do
    defp observe_pending_pack!(account) do
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)

      {:ok, _runner} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [],
          # No library baseline for this custom pack — lands pending,
          # never auto-trusted.
          "packs" => %{"acme-tools" => %{"version" => "9.9", "hash" => "abc123"}}
        })

      {:ok, [pack_version], _meta} =
        Emisar.Catalog.list_pack_versions(
          Emisar.Fixtures.subject_for(Emisar.Fixtures.user_fixture(), account)
        )

      pack_version
    end

    test "lists the pending pack with Trust/Reject for an owner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      _ = observe_pending_pack!(account)

      {:ok, lv, _dead_html} = live(conn, ~p"/app/packs")
      html = render(lv)

      assert html =~ "acme-tools"
      assert html =~ "phx-click=\"trust\""
      assert html =~ "phx-click=\"reject\""
    end

    test "Trust adopts the pending hash and clears the pending badge", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/packs")
      html = render_click(lv, "trust", %{"id" => pack_version.id})

      assert html =~ "Trusted acme-tools"
      refute render(lv) =~ "phx-click=\"trust\""
    end

    test "Reject on a never-trusted custom pack drops the row", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/packs")
      html = render_click(lv, "reject", %{"id" => pack_version.id})

      assert html =~ "Rejected drift on acme-tools"
      # The flash quotes the pack name, so scope the absence check to the list.
      refute has_element?(lv, "#packs li", "acme-tools")
    end

    test "a viewer sees the pack but no Trust/Reject controls", %{conn: conn} do
      {_owner_conn, _user, account} = register_and_log_in(conn)
      _ = observe_pending_pack!(account)

      viewer = Emisar.Fixtures.user_fixture()

      _ =
        Emisar.Fixtures.membership_fixture(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/packs")
      html = render(lv)

      assert html =~ "acme-tools"
      refute html =~ "phx-click=\"trust\""
    end
  end
end
