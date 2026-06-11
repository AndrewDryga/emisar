defmodule EmisarWeb.UserSignUpLiveTest do
  @moduledoc """
  Self-serve sign-up: one form creates the user AND their free-plan
  workspace, then arms the hidden POST that signs them in.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Users

  defp sign_up_params(overrides \\ %{}) do
    Map.merge(
      %{
        "user" => %{
          "full_name" => "Founder Person",
          "email" => "founder-#{System.unique_integer([:positive])}@example.com",
          "password" => "a-long-enough-password"
        },
        "account_name" => "Founder Co"
      },
      overrides
    )
  end

  test "renders the registration form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/sign_up")

    assert html =~ "Start your free workspace"
    assert html =~ "Team or company name"
  end

  test "a valid sign-up creates user + workspace and arms the sign-in POST", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    params = sign_up_params()

    html = lv |> form("#registration_form", params) |> render_submit()

    assert html =~ ~s|action="/sign_in?_action=registered"|
    assert html =~ "phx-trigger-action"

    {:ok, user} = Users.fetch_user_by_email(params["user"]["email"])
    assert user.full_name == "Founder Person"
    # Email confirmation is a separate step — never auto-confirmed.
    refute user.confirmed_at

    memberships =
      Emisar.Accounts.Membership.Query.not_deleted()
      |> Emisar.Accounts.Membership.Query.by_user_id(user.id)
      |> Emisar.Repo.all()
      |> Emisar.Repo.preload(:account)

    assert [%{role: :owner, account: %{name: "Founder Co", plan: "free"}}] = memberships
  end

  test "a blank workspace name flashes and creates nothing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")
    params = sign_up_params(%{"account_name" => "  "})

    html = lv |> form("#registration_form", params) |> render_submit()

    assert html =~ "Tell us what to call your workspace."
    assert Users.fetch_user_by_email(params["user"]["email"]) == {:error, :not_found}
  end

  test "a taken email renders the changeset error inline", %{conn: conn} do
    existing = Emisar.Fixtures.user_fixture()

    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    params =
      sign_up_params(%{
        "user" => %{
          "full_name" => "Copy Cat",
          "email" => existing.email,
          "password" => "a-long-enough-password"
        }
      })

    html = lv |> form("#registration_form", params) |> render_submit()

    assert html =~ "has already been taken"
  end

  test "phx-change validation keeps the typed workspace name", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/sign_up")

    html =
      lv
      |> form("#registration_form", sign_up_params(%{"account_name" => "Sticky Name"}))
      |> render_change()

    assert html =~ "Sticky Name"
  end
end
