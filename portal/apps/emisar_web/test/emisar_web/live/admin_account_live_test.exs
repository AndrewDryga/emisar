defmodule EmisarWeb.AdminAccountLiveTest do
  @moduledoc """
  The staff console's account detail page at `/admin/accounts/:id`. The gate in
  front of it is `EmisarWeb.AdminGateTest`'s; these drive the surface behind it,
  including the two properties the page exists to guarantee: it writes exactly
  one `staff.account_viewed` row per view, and it never renders a run payload.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Audit, Repo}

  setup %{conn: conn} do
    {conn, staff_user} = register_and_log_in_staff(conn)
    %{conn: conn, staff_user: staff_user}
  end

  # Every fixture in here writes audit rows of its own, so the staff event has
  # to be picked out rather than read as the only row in the table.
  defp staff_view_events do
    Audit.Event
    |> Repo.all()
    |> Enum.filter(&(&1.event_type == "staff.account_viewed"))
  end

  describe "GET /admin/accounts/:id" do
    setup do
      account = Fixtures.Accounts.create_account(plan: "team")
      owner = Fixtures.Users.create_user(full_name: "Dana Okafor")

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "acme-db-01")

      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: "postgres.replication_status",
          source: :mcp
        )

      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: owner.id)

      %{account: account, owner: owner, runner: runner, run: run}
    end

    test "each section renders its key facts", %{
      conn: conn,
      account: account,
      owner: owner,
      runner: runner,
      run: run
    } do
      {:ok, live, html} = live(conn, ~p"/admin/accounts/#{account.id}")

      assert html =~ account.name
      assert html =~ account.slug
      assert html =~ account.id

      assert html =~ "team"
      assert html =~ owner.email
      assert html =~ "Dana Okafor"
      assert html =~ "Owner"

      assert html =~ runner.name
      # `dotted_mono` puts a <wbr> at every dot, so the id is never contiguous
      # in the markup — assert the segment that identifies this action.
      assert html =~ "replication_status"
      assert has_element?(live, "#run-#{run.id}")
      assert html =~ "1 active API key."

      # The fixture subscription has no Paddle id, so its source (legacy_manual)
      # differs from the plan — the row renders, humanized.
      assert has_element?(live, "dt", "Source")
      assert html =~ "Legacy manual"
    end

    test "the account can be reached by slug as well as id", %{conn: conn, account: account} do
      {:ok, _live, html} = live(conn, ~p"/admin/accounts/#{account.slug}")

      assert html =~ account.name
    end

    test "a connected mount writes exactly one staff.account_viewed row", %{
      conn: conn,
      account: account,
      staff_user: staff_user
    } do
      # The dead render mounts too, so anything less careful than a `connected?`
      # guard bills the customer's trail twice for one look.
      {:ok, _live, _html} = live(conn, ~p"/admin/accounts/#{account.id}")

      assert [event] = staff_view_events()
      assert event.account_id == account.id
      assert event.actor_id == staff_user.id
      assert event.actor_label == "Emisar staff"
      # The customer reads this row; the acting employee stays out of it.
      assert event.payload == %{}
    end

    test "no run payload reaches the page", %{conn: conn, account: account, runner: runner} do
      marker = "hunter2-connection-string"

      run =
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          args_raw: ~s({"dsn":"#{marker}"})
        )

      finished =
        Fixtures.Runs.finish_without_runbook_callback(run, :success, %{"stdout" => marker})

      # The seed itself is asserted, or a fixture that quietly stopped storing
      # either field would leave the refute below passing for nothing.
      assert finished.args_raw =~ marker
      assert finished.structured_output == %{"stdout" => marker}

      {:ok, live, html} = live(conn, ~p"/admin/accounts/#{account.id}")

      # The run itself is on the page — otherwise the refute below would pass
      # for the wrong reason — but neither its arguments nor its output are.
      assert has_element?(live, "#run-#{run.id}")
      refute html =~ marker
    end

    test "an unknown account redirects to the search with a flash", %{conn: conn} do
      unknown_id = Ecto.UUID.generate()
      result = live(conn, ~p"/admin/accounts/#{unknown_id}")

      assert {:error, {:live_redirect, %{to: "/admin"}}} = result

      # The redirect happens on the connected mount, so its flash comes back as
      # a signed token — follow it and read the flash where staff would see it.
      {:ok, _live, html} = follow_redirect(result, conn)
      assert html =~ "Account not found."
      assert staff_view_events() == []
    end
  end

  describe "an account with nothing in it" do
    test "every section renders its empty state", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      {:ok, live, html} = live(conn, ~p"/admin/accounts/#{account.id}")

      assert html =~ account.name
      assert html =~ "No members."
      assert html =~ "No providers configured."
      assert html =~ "No runners enrolled."
      assert html =~ "No runs yet."
      assert html =~ "No MCP activity."
      assert html =~ "free"

      # A free account's source IS "free" — the row would only restate Plan.
      refute has_element?(live, "dt", "Source")
    end
  end

  describe "a disabled account" do
    test "says so, and still renders", %{conn: conn} do
      account = Fixtures.Accounts.create_account() |> Fixtures.Accounts.disable_account()

      {:ok, _live, html} = live(conn, ~p"/admin/accounts/#{account.id}")

      assert html =~ account.name
      assert html =~ "Disabled"
    end
  end
end
