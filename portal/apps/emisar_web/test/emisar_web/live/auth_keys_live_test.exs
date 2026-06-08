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
    {:ok, _lv, html} = live(conn, ~p"/app/settings/runners/auth-keys")
    assert html =~ "live-key-aaa"
    refute html =~ "dead-key-zzz"

    # The dropdown's "All" (status="") clears the filter → both show.
    {:ok, _lv, html} = live(conn, ~p"/app/settings/runners/auth-keys?status=")
    assert html =~ "live-key-aaa"
    assert html =~ "dead-key-zzz"
  end
end
