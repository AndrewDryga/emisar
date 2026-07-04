defmodule EmisarWeb.AuthKeysLiveTest do
  @moduledoc """
  The runner auth-keys list defaults to hiding revoked keys (the Status
  filter defaults to "active"); the operator widens it via the dropdown.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Runners

  test "hides revoked keys by default; the All option shows them", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

    {:ok, _, _live} =
      Runners.create_auth_key(%{reusable: true, description: "live-key-aaa"}, subject)

    {:ok, _, revoked} =
      Runners.create_auth_key(%{reusable: true, description: "dead-key-zzz"}, subject)

    {:ok, _} = Runners.revoke_auth_key(revoked, subject)

    # Default Status=active → the revoked key is hidden.
    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runners/keys")
    assert html =~ "live-key-aaa"
    refute html =~ "dead-key-zzz"

    # Selecting "All" goes through the real dropdown path: phx-change "filter"
    # submits status="", and because the status filter declares a default,
    # apply_filter KEEPS the explicit blank in the URL — that's what overrides
    # the "active" default on the next load instead of snapping back to it.
    lv |> form("#auth-keys-filter", %{"status" => ""}) |> render_change()
    assert_patched(lv, ~p"/app/#{account}/runners/keys?status=")

    html = render(lv)
    assert html =~ "live-key-aaa"
    assert html =~ "dead-key-zzz"
  end

  # a brand-new account with no auth keys renders the
  # "No runner keys yet." onboarding empty state.
  test "no auth keys → onboarding empty state", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/keys")

    assert html =~ "No runner keys yet."
    assert html =~ "bearer secret a fresh host enrolls with"
    # The pitch carries a real CTA, not a narrated chrome reference.
    assert html =~ "New runner key"
  end

  # a hand-edited page cursor makes the list read return
  # {:error, …}; `load/1` retries once with clean params (first page) rather than
  # recursing forever or raising. The page renders.
  test "a bad cursor in the URL falls back to the first page, not a crash", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account)
    {:ok, _raw, _key} = Runners.create_auth_key(%{description: "still-here"}, subject)

    {:ok, _lv, html} =
      live(conn, ~p"/app/#{account}/runners/keys?page=garbage-cursor")

    assert html =~ "still-here"
  end

  # `put_max_uses` keeps max_uses only for a reusable key
  # with a positive value; a single-use key (and a blank value) drops it (the
  # single-use key self-caps at 1 via the schema's not-reusable rule).
  test "max_uses is kept for a reusable+positive key, dropped otherwise", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/keys")

    # Ticking Reusable reveals the max_uses input (progressive disclosure).
    html =
      lv
      |> form("#auth_key_form", %{"auth_key" => %{"reusable" => "true"}})
      |> render_change()

    assert html =~ ~s(name="auth_key[max_uses]")

    # Reusable + max_uses=5 → persisted with max_uses == 5.
    lv
    |> form("#auth_key_form", %{
      "auth_key" => %{"description" => "pool-key", "reusable" => "true", "max_uses" => "5"}
    })
    |> render_submit()

    # Single-use (reusable unchecked, no max_uses field shown) → max_uses nil.
    lv
    |> form("#auth_key_form", %{"auth_key" => %{"description" => "one-shot-key"}})
    |> render_submit()

    {:ok, keys, _} = Runners.list_auth_keys(subject)
    by_desc = Map.new(keys, &{&1.description, &1})

    assert by_desc["pool-key"].reusable
    assert by_desc["pool-key"].max_uses == 5

    refute by_desc["one-shot-key"].reusable
    assert is_nil(by_desc["one-shot-key"].max_uses)
  end

  test "create form shows validation errors inline on the field, not in a flash", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/keys")

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
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/keys")

    html =
      lv
      |> form("#auth_key_form", %{
        "auth_key" => %{"description" => "bootstrap for prod image"}
      })
      |> render_submit()

    assert html =~ "Copy it now"

    # The full raw secret is on the page exactly once, until dismissed —
    # the list rows keep showing the short prefix, so refute the raw.
    [raw_secret] = Regex.run(~r/emkey-auth-[A-Za-z0-9_-]{20,}/, html)

    html = render_click(lv, "dismiss_secret", %{})
    refute html =~ raw_secret
    assert html =~ "bootstrap for prod image"

    # Revoke it through the typed-confirm dialog. The dialog id is
    # `revoke-key-<id>`; the token to type is the key prefix.
    [key_id] = Regex.run(~r/revoke-key-([0-9a-f-]+)/, html, capture: :all_but_first)

    [key_prefix] =
      Regex.run(~r/Type <span[^>]*>([^<]+)<\/span> to confirm/, html, capture: :all_but_first)

    dialog = "revoke-key-#{key_id}"

    type_confirm_token(lv, dialog, key_prefix)
    html = confirm_dialog(lv, dialog, "Revoke key")
    assert html =~ "Key revoked."
    refute html =~ "bootstrap for prod image"
  end

  # one-time-secret hygiene: once the operator dismisses the
  # revealed secret it's gone for good. There's no re-reveal control, and the
  # only "show secret again" affordance is the dismiss (which clears it) — the
  # raw secret is never re-rendered after dismiss.
  test "a dismissed secret cannot be re-revealed", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/keys")

    html =
      lv
      |> form("#auth_key_form", %{"auth_key" => %{"description" => "one-time"}})
      |> render_submit()

    [raw_secret] = Regex.run(~r/emkey-auth-[A-Za-z0-9_-]{20,}/, html)
    # The reveal panel offers a dismiss; there is NO re-reveal control.
    assert has_element?(lv, "[phx-click=\"dismiss_secret\"]")

    html = render_click(lv, "dismiss_secret", %{})
    refute html =~ raw_secret
    refute has_element?(lv, "[phx-click=\"dismiss_secret\"]")

    # Re-rendering (a tick / list reload) never brings the secret back.
    send(lv.pid, {:list_changed, :auth_key, "auth_key.created", Ecto.UUID.generate()})
    refute render(lv) =~ raw_secret
  end

  test "revoke's typed-confirm: Confirm stays disabled (and won't fire) until the prefix matches",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {:ok, _raw, key} = Runners.create_auth_key(%{description: "guarded-key"}, subject)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/keys")
    dialog = "revoke-key-#{key.id}"

    # Empty token → Confirm disabled; the dialog won't dispatch `revoke`.
    assert_raise ArgumentError, ~r/disabled/, fn -> confirm_dialog(lv, dialog, "Revoke key") end

    # Wrong token → still disabled, still won't fire.
    type_confirm_token(lv, dialog, "not-the-prefix")
    assert_raise ArgumentError, ~r/disabled/, fn -> confirm_dialog(lv, dialog, "Revoke key") end

    # The key is untouched — a bypassing event was never fired.
    assert render(lv) =~ "guarded-key"
  end

  test "a viewer cannot mint an auth key", %{conn: conn} do
    {_owner_conn, _owner, account} = register_and_log_in(conn)

    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    # Manage-only page: a viewer is bounced at LOAD time with the honest
    # why-not, never reaching the form to fail on submit.
    dest = ~p"/app/#{account}/runners"

    assert {:error, {:live_redirect, %{to: ^dest, flash: flash}}} =
             build_conn()
             |> log_in_user(viewer)
             |> live(~p"/app/#{account}/runners/keys")

    assert flash["info"] == "Runner keys need an owner or admin role."
  end

  test "a list_changed broadcast refreshes the key list", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runners/keys")
    refute html =~ "minted-elsewhere"

    {:ok, _raw, key} = Runners.create_auth_key(%{description: "minted-elsewhere"}, subject)
    send(lv.pid, {:list_changed, :auth_key, "auth_key.created", key.id})

    assert render(lv) =~ "minted-elsewhere"
  end

  test "last-used renders through <.local_time> — 'never' until used, then a time", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account)

    # A fresh key has never been used → <.local_time> renders its "never"
    # placeholder as a <span> (so "last used" is followed by the placeholder
    # span, with the {" "} space preserved), not a hook-driven <time>.
    {:ok, _raw, key} = Runners.create_auth_key(%{description: "freshly-minted"}, subject)
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/keys")
    assert html =~ ~r/last used\s<span[^>]*>never<\/span>/

    # Once stamped, it renders the time through the hook-driven <time>, and the
    # mid-sentence space survives the formatter's line-break (the {" "} guard).
    key |> Ecto.Changeset.change(last_used_at: DateTime.utc_now()) |> Emisar.Repo.update!()
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/keys")
    assert html =~ ~s(phx-hook="LocalTime")
    assert html =~ ~s(data-format="relative")
    assert html =~ ~r/last used\s<time/
    refute html =~ ~r/last used<time/
  end

  # at the plan's runner limit the page shows the rose
  # cap-warning banner: a key minted here is useless once a runner bounces off a
  # 402. The free plan caps at 3 runners; fill all three.
  test "at the runner limit, the cap-warning banner renders", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    for _ <- 1..3, do: Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/keys")

    assert html =~ "At runner limit"
    assert html =~ "3 of 3 runners in use"
  end

  # (the near-limit half) — one slot short of the cap shows
  # the softer amber "one slot left" variant, not the at-limit rose one.
  test "near the runner limit, the amber 'one slot left' banner renders", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    for _ <- 1..2, do: Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/keys")

    assert html =~ "One runner slot left"
    refute html =~ "At runner limit"
  end

  # a `datetime-local` expiry (no seconds, no zone) is
  # stored as UTC: `put_expires` appends ":00Z" before parsing, so "2030-12-25
  # at 10:30" persists as 10:30:00 UTC.
  test "expires_at from a datetime-local field is stored as UTC", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/keys")

    lv
    |> form("#auth_key_form", %{
      "auth_key" => %{"description" => "expiring-key", "expires_at" => "2030-12-25T10:30"}
    })
    |> render_submit()

    {:ok, keys, _} = Runners.list_auth_keys(subject)
    key = Enum.find(keys, &(&1.description == "expiring-key"))

    # The column is :utc_datetime_usec, so the stored value carries
    # microseconds — compare on the truncated instant.
    assert DateTime.truncate(key.expires_at, :second) == ~U[2030-12-25 10:30:00Z]
  end

  # a key created from account A's session is bound to A
  # (no cross-account id), and its one-time secret is the only place the raw
  # value appears (the persisted row stores only the hash + prefix).
  test "a created key is bound to the current account", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/keys")

    html =
      lv
      |> form("#auth_key_form", %{"auth_key" => %{"description" => "account-bound-key"}})
      |> render_submit()

    {:ok, keys, _} = Runners.list_auth_keys(subject)
    key = Enum.find(keys, &(&1.description == "account-bound-key"))

    assert key.account_id == account.id
    # The raw secret is revealed once in the DOM; the row persists only a hash.
    [raw_secret] = Regex.run(~r/emkey-auth-[A-Za-z0-9_-]{20,}/, html)
    refute key.key_hash == raw_secret
  end

  # the page is manage-only (auth keys have no
  # view permission). An operator (view-only on runners, no manage_auth_keys) is
  # bounced at LOAD time with an honest why-not back to Runners — they never
  # reach the form or a `revoke` event.
  test "an operator is redirected at mount — the page is manage-only", %{conn: conn} do
    {_owner_conn, _owner, account} = register_and_log_in(conn)

    operator = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

    dest = ~p"/app/#{account}/runners"

    assert {:error, {:live_redirect, %{to: ^dest, flash: flash}}} =
             build_conn()
             |> log_in_user(operator)
             |> live(~p"/app/#{account}/runners/keys")

    assert flash["info"] == "Runner keys need an owner or admin role."
  end

  # the list is account-scoped (A's admin sees
  # A's keys, never B's), and revoke only finds keys in the loaded A list: forcing
  # a `revoke` with a foreign B-account key id is a quiet no-op (the id isn't in
  # `socket.assigns.auth_keys`), so only account-A keys are revocable.
  test "cross-account — only A's keys are listed and revocable", %{conn: conn} do
    {conn, user_a, account_a} = register_and_log_in(conn)
    subject_a = Fixtures.Subjects.subject_for(user_a, account_a)

    {:ok, _raw, _key_a} =
      Runners.create_auth_key(%{description: "alpha-key"}, subject_a)

    {_user_b, account_b, subject_b} = Fixtures.Subjects.owner_subject()
    refute account_b.id == account_a.id

    {:ok, _raw, key_b} =
      Runners.create_auth_key(%{description: "bravo-key"}, subject_b)

    {:ok, lv, html} = live(conn, ~p"/app/#{account_a}/runners/keys")

    # A's admin sees A's key and never B's.
    assert html =~ "alpha-key"
    refute html =~ "bravo-key"

    # Forcing a revoke for B's key id is a no-op — it isn't in A's loaded list.
    render_click(lv, "revoke", %{"id" => key_b.id})
    assert is_nil(Emisar.Repo.reload!(key_b).revoked_at)

    # B's key is still revocable from B's own (authorized) path — proves the
    # no-op was the scope boundary, not a broken key.
    assert {:ok, _} = Runners.revoke_auth_key(key_b, subject_b)
  end

  # once a key is revoked the Revoke button (and its
  # typed-confirm dialog) are gone (`:if={is_nil(key.revoked_at) …}`); the row
  # carries the "Revoked" chip instead. The "gone key → no-op" half is the
  # absent-id case below (the genuine `do_revoke` guard).
  test "a revoked key shows the Revoked chip and no Revoke control", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account)

    {:ok, _raw, key} = Runners.create_auth_key(%{description: "spent-key"}, subject)
    {:ok, _} = Runners.revoke_auth_key(key, subject)

    # View it via the Status=revoked filter (default hides revoked).
    {:ok, lv, html} =
      live(conn, ~p"/app/#{account}/runners/keys?status=revoked")

    assert html =~ "spent-key"
    assert html =~ "Revoked"
    # No live Revoke affordance on a revoked row (button + dialog both gated on
    # `is_nil(key.revoked_at)`).
    refute has_element?(lv, "[phx-click*=\"revoke-key-#{key.id}\"]")
  end

  # (the "gone key → no-op" half) — a forced `revoke` with an
  # id that isn't in the loaded list (a since-deleted / never-present key) is a
  # quiet no-op: `do_revoke` finds nothing in `socket.assigns.auth_keys` and
  # returns the socket untouched (no flash, no crash).
  test "revoking an absent key id is a quiet no-op", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/keys")

    # No such key in the loaded list → the find misses → no-op, page intact.
    html = render_click(lv, "revoke", %{"id" => Ecto.UUID.generate()})
    refute html =~ "Key revoked."
    assert html =~ "Runner keys"
  end

  # BUG: a forced `revoke` of an ALREADY-revoked (but still loaded,
  # e.g. under ?status=revoked) key is NOT idempotent — `AuthKey.Changeset.revoke/2`
  # unconditionally re-stamps `revoked_at: DateTime.utc_now()` (and writes a fresh
  # audit row + broadcast), so re-revoking moves the timestamp instead of being a
  # no-op. The UI hides the Revoke button on revoked rows, so this is only
  # reachable via a crafted event, and the key stays revoked + manage-gated —
  # low severity, but it contradicts the "no-op" claim and pollutes the audit
  # trail with a duplicate revocation. Fix: guard the changeset on
  # `is_nil(key.revoked_at)` (skip when already revoked).
  test "re-revoking an already-revoked key is idempotent (no timestamp change)", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    subject = Fixtures.Subjects.subject_for(user, account)

    {:ok, _raw, key} = Runners.create_auth_key(%{description: "spent-key"}, subject)
    {:ok, _} = Runners.revoke_auth_key(key, subject)

    {:ok, lv, _html} =
      live(conn, ~p"/app/#{account}/runners/keys?status=revoked")

    revoked_at = Emisar.Repo.reload!(key).revoked_at
    render_click(lv, "revoke", %{"id" => key.id})

    # Should stay put — a second revocation of a spent key is meaningless.
    assert Emisar.Repo.reload!(key).revoked_at == revoked_at
  end
end
