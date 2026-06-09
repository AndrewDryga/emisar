defmodule EmisarWeb.OnboardingLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "workspace-name form validation" do
    test "a blank name renders inline on the field, not in a flash", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      html =
        lv
        |> form("#onboarding_form", %{"account" => %{"name" => ""}})
        |> render_submit()

      # Inline field error under the name input.
      assert html =~ "can&#39;t be blank"
      # Old flash copy is gone.
      refute html =~ "Unable to create. Try a different name."
    end

    test "phx-change surfaces a blank-name error inline without submitting", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/onboarding")

      html =
        lv
        |> form("#onboarding_form", %{"account" => %{"name" => ""}})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end
  end
end
