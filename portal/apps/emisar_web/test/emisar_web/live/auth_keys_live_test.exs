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

  test "create form shows validation errors inline on the field, not in a flash", %{conn: conn} do
    {conn, _user, _account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/settings/runners/auth-keys")

    too_long = String.duplicate("x", 201)

    html =
      lv
      |> form("#auth_key_form", %{"auth_key" => %{"description" => too_long}})
      |> render_submit()

    # Inline field error (rendered by <.input>/<.error> under the input)…
    assert html =~ "should be at most 200 character(s)"
    # …and no flash banner with a humanized changeset dump.
    refute html =~ "Could not create key"
  end

  test "create shows the secret once; dismiss hides it; revoke retires the key", %{conn: conn} do
    {conn, _user, _account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/settings/runners/auth-keys")

    html =
      lv
      |> form("#auth_key_form", %{
        "auth_key" => %{"description" => "bootstrap for prod image", "group" => "prod"}
      })
      |> render_submit()

    assert html =~ "Copy it now"

    # The full raw secret is on the page exactly once, until dismissed —
    # the list rows keep showing the short prefix, so refute the raw.
    [raw_secret] = Regex.run(~r/emkey-auth-[A-Za-z0-9_-]{20,}/, html)

    html = render_click(lv, "dismiss_secret", %{})
    refute html =~ raw_secret
    assert html =~ "bootstrap for prod image"

    # Revoke it via the row control — the row flips out of the active list.
    [key_id] = Regex.run(~r/phx-value-id="([0-9a-f-]+)"/, html, capture: :all_but_first)

    html = render_click(lv, "revoke", %{"id" => key_id})
    assert html =~ "Key revoked."
    refute html =~ "bootstrap for prod image"
  end

  test "a viewer cannot mint an auth key", %{conn: conn} do
    {_owner_conn, _owner, account} = register_and_log_in(conn)

    viewer = Emisar.Fixtures.user_fixture()

    _ =
      Emisar.Fixtures.membership_fixture(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    # Manage-only page: a viewer is bounced at LOAD time (reads as
    # not-found), never reaching the form to fail on submit.
    assert {:error, {:live_redirect, %{to: "/app", flash: flash}}} =
             build_conn() |> log_in_user(viewer) |> live(~p"/app/settings/runners/auth-keys")

    assert flash["error"] == "Page not found."
  end

  test "a list_changed broadcast refreshes the key list", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Emisar.Fixtures.subject_for(user, account)

    {:ok, lv, html} = live(conn, ~p"/app/settings/runners/auth-keys")
    refute html =~ "minted-elsewhere"

    {:ok, _raw, key} = Runners.create_auth_key(%{description: "minted-elsewhere"}, subject)
    send(lv.pid, {:list_changed, :auth_key, "auth_key.created", key.id})

    assert render(lv) =~ "minted-elsewhere"
  end

  test "last-used renders through <.local_time> — 'never' until used, then a time", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Emisar.Fixtures.subject_for(user, account)

    # A fresh key has never been used → <.local_time> renders its "never"
    # placeholder as a <span> (so "last used" is followed by the placeholder
    # span, with the {" "} space preserved), not a hook-driven <time>.
    {:ok, _raw, key} = Runners.create_auth_key(%{description: "freshly-minted"}, subject)
    {:ok, _lv, html} = live(conn, ~p"/app/settings/runners/auth-keys")
    assert html =~ ~r/last used\s<span[^>]*>never<\/span>/

    # Once stamped, it renders the time through the hook-driven <time>, and the
    # mid-sentence space survives the formatter's line-break (the {" "} guard).
    key |> Ecto.Changeset.change(last_used_at: DateTime.utc_now()) |> Emisar.Repo.update!()
    {:ok, _lv, html} = live(conn, ~p"/app/settings/runners/auth-keys")
    assert html =~ ~s(phx-hook="LocalTime")
    assert html =~ ~s(data-format="relative")
    assert html =~ ~r/last used\s<time/
    refute html =~ ~r/last used<time/
  end
end
