defmodule EmisarWeb.AuthKeysLiveTest do
  @moduledoc """
  The runner auth-keys list defaults to hiding revoked keys (the Status
  filter defaults to "active"); the operator widens it via the dropdown.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Runners

  test "hides revoked keys by default; the All option shows them", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Emisar.Fixtures.subject_for(user, account, role: :owner)

    {:ok, _, _live} =
      Runners.create_auth_key(%{reusable: true, description: "live-key-aaa"}, subject)

    {:ok, _, revoked} =
      Runners.create_auth_key(%{reusable: true, description: "dead-key-zzz"}, subject)

    {:ok, _} = Runners.revoke_auth_key(revoked, subject)

    # Default Status=active → the revoked key is hidden.
    {:ok, lv, html} = live(conn, ~p"/app/settings/runners/auth-keys")
    assert html =~ "live-key-aaa"
    refute html =~ "dead-key-zzz"

    # Selecting "All" must go through the real dropdown path: phx-change
    # "filter" submits status="", which LiveTable strips out of the URL. Once
    # the operator has interacted, an absent status has to mean "All" — not
    # snap back to the "active" default — so the revoked key now shows. (The
    # earlier version of this test hand-built `?status=`, a URL the dropdown
    # can never actually produce, and so missed the bug.)
    lv |> form("#auth-keys-filter", %{"status" => ""}) |> render_change()
    assert_patched(lv, ~p"/app/settings/runners/auth-keys")

    html = render(lv)
    assert html =~ "live-key-aaa"
    assert html =~ "dead-key-zzz"
  end
end
