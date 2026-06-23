defmodule EmisarWeb.AccountSwitchControllerTest do
  @moduledoc """
  Covers `POST /app/accounts/switch`: a member of multiple accounts
  flips the active tenant; a user attempting to switch to an account
  they don't belong to is rejected with a flash.
  """

  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Accounts, Repo, Users}
  alias Emisar.Audit.Event

  defp second_account_for(user, attrs \\ %{}) do
    base = %{
      name: "Second Co #{System.unique_integer([:positive])}"
    }

    attrs = Map.merge(base, attrs)

    {:ok, account} =
      Accounts.create_account_with_owner(
        Map.put(attrs, :slug, Accounts.suggest_unique_slug(attrs.name)),
        user
      )

    account
  end

  describe "POST /app/accounts/switch" do
    test "switches the active account when the user belongs to it", %{conn: conn} do
      {conn, user, first} = register_and_log_in(conn)
      second = second_account_for(user)

      conn = post(conn, ~p"/app/accounts/switch", account_id: second.id)

      assert redirected_to(conn) == ~p"/app/#{second}"
      assert get_session(conn, :current_account_id) == second.id

      # And the audit row landed on the new tenant.
      audit =
        Event.Query.all()
        |> Event.Query.by_account_id(second.id)
        |> Repo.all()

      assert Enum.any?(audit, &(&1.event_type == "session.account_switched"))
      _ = first
    end

    test "rejects switching to an account the user is NOT a member of", %{conn: conn} do
      {conn, _user, first} = register_and_log_in(conn)

      # Account belonging to someone else.
      {:ok, other_user} =
        Users.register_user(%{
          email: "other-#{System.unique_integer([:positive])}@example.com",
          full_name: "Other",
          password: "very-long-password-1234"
        })

      other_user = Emisar.Fixtures.confirm_user(other_user)
      foreign = second_account_for(other_user)

      conn = post(conn, ~p"/app/accounts/switch", account_id: foreign.id)

      assert redirected_to(conn) == ~p"/app"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "aren't a member"
      assert get_session(conn, :current_account_id) != foreign.id
      _ = first
    end

    test "rejects a missing/invalid account_id", %{conn: conn} do
      {conn, _user, first} = register_and_log_in(conn)
      conn = post(conn, ~p"/app/accounts/switch", account_id: "not-a-uuid")

      assert redirected_to(conn) == ~p"/app"
      # Session pins to the user's primary, never adopts the invalid id.
      assert get_session(conn, :current_account_id) == first.id
    end

    test "a signed-out switch is bounced by require_authenticated_user", %{conn: conn} do
      # switching tenant is an authenticated-only action;
      # a signed-out POST never reaches the controller (no current_user to read),
      # it's halted at the plug and redirected to sign-in.
      conn = post(conn, ~p"/app/accounts/switch", account_id: Ecto.UUID.generate())

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "must log in"
    end

    test "the switch persists across subsequent requests via the session", %{conn: conn} do
      {conn, user, _first} = register_and_log_in(conn)
      second = second_account_for(user)

      conn = post(conn, ~p"/app/accounts/switch", account_id: second.id)
      assert get_session(conn, :current_account_id) == second.id

      # A follow-up request to the dashboard reads the pinned id and
      # mounts the second account, NOT the most-recent default: bare /app
      # forwards to the pinned account's slug.
      conn = recycle(conn) |> get(~p"/app")
      assert redirected_to(conn) == ~p"/app/#{second}"
      assert html_response(recycle(conn) |> get(redirected_to(conn)), 200) =~ second.name
    end
  end
end
