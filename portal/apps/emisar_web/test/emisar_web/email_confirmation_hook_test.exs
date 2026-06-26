defmodule EmisarWeb.EmailConfirmationHookTest do
  @moduledoc """
  The `on_mount(:email_confirmation)` hook attaches a UNIVERSAL
  `resend_confirmation` event handler to every authenticated LiveView, so
  the unconfirmed-email nudge banner's button works on any page without
  each LV defining its own handler. An unconfirmed user is never hard-gated
  — the banner is a soft nudge — so the handler is the only confirmation
  machinery they touch in-app.
  """
  use EmisarWeb.ConnCase, async: true

  import Swoosh.TestAssertions

  alias Emisar.{Accounts, Users}

  # A signed-in user who has a workspace but has NOT confirmed their email,
  # so the resend banner/handler is live for them.
  defp unconfirmed_member(conn) do
    {:ok, user} =
      Users.register_user(%{
        email: "pending-#{System.unique_integer([:positive])}@example.com",
        full_name: "Pending Person"
      })

    {:ok, account} =
      Accounts.create_account_with_owner(
        %{name: "Pending Co", slug: Accounts.suggest_unique_slug("Pending Co")},
        user
      )

    refute user.confirmed_at
    {log_in_user(conn, user), user, account}
  end

  test "an unconfirmed user reaches the app (soft nudge, not a hard gate) and can resend", %{
    conn: conn
  } do
    # the unconfirmed user is NOT bounced from the dashboard (no confirmation gate);
    # firing the universally-attached `resend_confirmation` event re-sends the
    # confirmation email and flashes a confirmation naming their address. The
    # dashboard defines NO `resend_confirmation` handler of its own — the
    # `:email_confirmation` on_mount hook owns it on every authed LV.
    {conn, user, account} = unconfirmed_member(conn)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

    html = render_click(lv, "resend_confirmation", %{})

    assert html =~ "Confirmation email sent to #{user.email}"
    assert_email_sent(subject: "Confirm your emisar account", to: {"", user.email})
  end

  test "resending while already confirmed sends nothing and says so", %{conn: conn} do
    # once confirmed, the same handler is a
    # no-op on the mail side: it flashes "already confirmed" and delivers no email
    # (firing it from a stale banner can't spam the inbox).
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

    html = render_click(lv, "resend_confirmation", %{})

    assert html =~ "Your email is already confirmed."
    assert_no_email_sent()
  end
end
