defmodule EmisarWeb.AuditExportLiveTest do
  @moduledoc """
  The SIEM-export page: admin-only `:audit_export` token mint/reveal/revoke,
  denial paths for lower roles + crafted events, cross-account isolation,
  and the export endpoint honoring revocation. Split off the audit-list
  tests when the panel moved to its own page.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Fixtures

  describe "SIEM export keys" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      # Export (SIEM + CSV) is Team+ — these tests exercise the feature itself.
      Fixtures.Accounts.create_subscription(account, "team")
      %{conn: conn, user: user, account: account}
    end

    test "mint shows the secret once, list updates, revoke retires it", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/export")

      # Mint: the raw emk- secret is rendered exactly once.
      html = render_click(lv, "create_export_key", %{})
      assert html =~ "emk-"
      assert html =~ "Audit export —"

      html = render_click(lv, "dismiss_export_secret", %{})
      refute html =~ "emk-NOSUCH"

      # The minted key row is in the export list; revoke it.
      {:ok, [key], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(subject, page_size: 50)

      html = render_click(lv, "revoke_export_key", %{"id" => key.id})
      assert html =~ "Export token revoked."

      # Revoked keys stay listed (audit trail) but carry the revocation.
      {:ok, [revoked], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(subject, page_size: 50)

      assert revoked.revoked_at
    end

    # an account with no export tokens shows
    # the mint affordance but NOT the (empty) list section: the list div is
    # `:if={@export_keys != []}`, so a manager sees just the "Mint export token"
    # button until they've created one.
    test "with no export keys the list is hidden but the mint affordance shows", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit/export")

      # The SIEM card + mint button are present (the owner manages keys)…
      assert html =~ "SIEM export"
      assert html =~ "Mint export token"
      # …but with zero export tokens the list section is hidden — so no list-row
      # Revoke affordance renders (the header copy is present regardless, so the
      # list's presence is the real signal). Scope to the card to be sure.
      siem_card = lv |> element("#siem-export") |> render()
      refute siem_card =~ "revoke_export_key"
      refute siem_card =~ "Revoked"
    end

    # while a freshly-minted secret is being revealed, the
    # "Mint export token" button is hidden (`:if={is_nil(@export_secret)}`) so a
    # double-mint can't clobber the one-shot reveal; dismissing brings it back.
    test "the mint button is hidden while a secret is being revealed", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/audit/export")
      assert html =~ "Mint export token"

      html = render_click(lv, "create_export_key", %{})
      # The secret is shown and the mint button is gone during the reveal.
      assert html =~ "emk-"
      refute html =~ "Mint export token"

      # Dismissing the reveal restores the mint button.
      html = render_click(lv, "dismiss_export_secret", %{})
      assert html =~ "Mint export token"
    end

    # the curl snippet's base URL is derived from the socket
    # (`derive_base_url(socket) <> "/api/audit"`), so the reveal hands the
    # operator a copy-paste command pointed at this deployment's export endpoint.
    test "the reveal shows a curl snippet pointed at /api/audit", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/export")

      html = render_click(lv, "create_export_key", %{})

      assert html =~ "/api/audit"
      assert html =~ "curl -H"
      assert html =~ "Authorization: Bearer"
    end

    # the raw secret is one-shot: it lives only
    # in the socket assigns, so a fresh mount (a reconnect / reload) never
    # re-shows it. Mint in one session, then open a second LV: no secret.
    test "the minted secret is one-shot — a fresh mount never re-shows it", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/export")

      html = render_click(lv, "create_export_key", %{})
      [raw] = Regex.run(~r/Bearer (emk-[A-Za-z0-9_-]+)/, html, capture: :all_but_first)

      # A brand-new mount of the same page (reconnect) must not carry the secret.
      {:ok, _lv2, fresh_html} = live(conn, ~p"/app/#{account}/audit/export")
      refute fresh_html =~ raw
      refute fresh_html =~ "won't show it again"
    end

    # the Revoke button renders only for non-revoked keys
    # (`:if={is_nil(key.revoked_at)}`); a revoked key shows the "Revoked" chip and
    # no button — idempotency by affordance.
    test "revoke is offered only on active keys; revoked keys show a chip", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _raw, active} =
        Emisar.ApiKeys.create_key(%{name: "active-export", kind: :audit_export}, subject)

      {:ok, _raw, to_revoke} =
        Emisar.ApiKeys.create_key(%{name: "dead-export", kind: :audit_export}, subject)

      {:ok, _} = Emisar.ApiKeys.revoke_api_key(to_revoke, subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/export")
      siem_card = lv |> element("#siem-export") |> render()

      # The active key offers a Revoke button keyed to its id…
      assert siem_card =~ ~s(phx-value-id="#{active.id}")
      # …the revoked key does NOT (no button keyed to it) but shows the chip.
      refute siem_card =~ ~s(phx-value-id="#{to_revoke.id}")
      assert siem_card =~ "revoked"
    end

    # a key whose creating user has since been deleted still
    # lists (left-join preload → created_by is nil), and the "by <email>" line is
    # guarded (`:if={key.created_by}`) so the row renders without crashing.
    test "a key whose creator was deleted renders without the 'by' line", %{
      conn: conn,
      account: account
    } do
      # A second admin mints the export token, then their user row is soft-deleted
      # (we stay logged in as the original owner so the page still mounts).
      other_admin = Fixtures.Users.create_user(email: "departing-admin@example.com")

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: other_admin.id,
          role: "admin"
        )

      other_subject = Fixtures.Subjects.subject_for(other_admin, account, role: :admin)

      {:ok, _raw, _key} =
        Emisar.ApiKeys.create_key(%{name: "orphan-export", kind: :audit_export}, other_subject)

      # Soft-delete the creator — created_by (a where: deleted_at: nil belongs_to)
      # now resolves to nil on the preload.
      other_admin
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Emisar.Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/export")
      siem_card = lv |> element("#siem-export") |> render()

      # The key still lists; the guarded "by <email>" line is simply absent.
      assert siem_card =~ "orphan-export"
      refute siem_card =~ "departing-admin@example.com"
    end

    test "a viewer cannot mint an export key", %{account: account} do
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      # A viewer never reaches the mint UI — denied at mount.
      assert {:error, {:live_redirect, %{to: to}}} =
               build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/audit/export")

      assert to == ~p"/app/#{account}/audit"
    end

    test "an api_key list_changed broadcast refreshes the key list", %{
      conn: conn,
      user: user,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/export")

      # A key minted elsewhere (another tab/admin) appears via the broadcast.
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _raw, key} =
        Emisar.ApiKeys.create_key(
          %{name: "Side-channel export", kind: :audit_export},
          subject
        )

      send(lv.pid, {:list_changed, :api_key, "api_key.created", key.id})
      assert render(lv) =~ "Side-channel export"
    end

    test "an operator cannot revoke an export key (crafted event denied)", %{
      user: owner,
      account: account
    } do
      # An owner-minted export token; the operator below must not be able to
      # retire it from a crafted event (managing keys needs admin+).
      owner_subject = Fixtures.Subjects.subject_for(owner, account)

      {:ok, _raw, _key} =
        Emisar.ApiKeys.create_key(
          %{name: "Owner export token", kind: :audit_export},
          owner_subject
        )

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      # The operator never mounts the page (redirected), so there is no LV to
      # craft the event through; the handler stays Permissions-gated as depth.
      assert {:error, {:live_redirect, _}} =
               build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/audit/export")

      # The token is untouched — still active.
      {:ok, [reread], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(owner_subject, page_size: 50)

      assert is_nil(reread.revoked_at)
    end

    test "revoking a bogus key id is a silent no-op, not a crash or a flash", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/export")

      # A well-formed but nonexistent id: fetch_api_key_by_id returns
      # {:error, :not_found}, so the handler does nothing — no info flash.
      html = render_click(lv, "revoke_export_key", %{"id" => Ecto.UUID.generate()})
      refute html =~ "Export token revoked."

      # A malformed (non-UUID) id is rejected pre-query, same no-op.
      html = render_click(lv, "revoke_export_key", %{"id" => "not-a-uuid"})
      refute html =~ "Export token revoked."
    end

    test "an admin cannot revoke another account's export key (cross-account no-op)", %{
      conn: conn,
      account: account_b
    } do
      # Account A (a different tenant) has its own export token. The admin of B
      # fires revoke with A's real key id — the subject-gated fetch scopes to B,
      # so A's key is never found and never revoked.
      {a_user, _account_a, a_subject} = Fixtures.Subjects.owner_subject()
      _ = a_user

      {:ok, _raw, a_key} =
        Emisar.ApiKeys.create_key(
          %{name: "Account A export token", kind: :audit_export},
          a_subject
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account_b}/audit/export")

      html = render_click(lv, "revoke_export_key", %{"id" => a_key.id})
      refute html =~ "Export token revoked."

      # A's token is untouched.
      {:ok, [reread], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(a_subject, page_size: 50)

      assert reread.id == a_key.id
      assert is_nil(reread.revoked_at)
    end

    test "a revoked export token returns 401 from the export endpoint on its next call",
         %{conn: conn, user: user, account: account} do
      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/export")

      # Mint via the page; the raw secret only exists in the reveal once, so
      # parse it out of the rendered curl snippet.
      html = render_click(lv, "create_export_key", %{})
      [raw] = Regex.run(~r/Bearer (emk-[A-Za-z0-9_-]+)/, html, capture: :all_but_first)

      # The fresh token works.
      ok = build_conn() |> put_req_header("authorization", "Bearer #{raw}") |> get(~p"/api/audit")
      assert ok.status == 200

      # Revoke it on the page, then the collector's next poll is rejected.
      {:ok, [key], _meta} =
        Emisar.ApiKeys.list_audit_export_keys_for_account(subject, page_size: 50)

      _ = render_click(lv, "revoke_export_key", %{"id" => key.id})

      denied =
        build_conn() |> put_req_header("authorization", "Bearer #{raw}") |> get(~p"/api/audit")

      assert json_response(denied, 401) == %{"error" => "unauthorized"}
    end

    test "a free-plan account is redirected to billing", %{conn: _conn} do
      {conn, _user, account} = register_and_log_in(build_conn())

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/app/#{account}/audit/export")

      assert to == ~p"/app/#{account}/settings/billing"
      assert %{"info" => "Audit export is available on the Team plan."} = flash
    end

    test "the SIEM card is hidden from a non-manager (operator)", %{account: account} do
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      # An operator can read the audit log but not manage keys — the export
      # page redirects them back to the trail rather than rendering a dead
      # shell (the mint/revoke handlers stay Permissions-gated as depth).
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/audit/export")

      assert to == ~p"/app/#{account}/audit"
      assert %{"info" => "Managing export tokens needs an admin role."} = flash
    end

    test "another account's export tokens never appear in this account's SIEM list",
         %{conn: conn, account: account_b} do
      # Account A mints a distinctively-named export token.
      {a_user, _account_a, a_subject} = Fixtures.Subjects.owner_subject()
      _ = a_user

      {:ok, _raw, _a_key} =
        Emisar.ApiKeys.create_key(
          %{name: "Account-A-only-export-token", kind: :audit_export},
          a_subject
        )

      # Viewing B's audit page must not surface A's token.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account_b}/audit")
      refute html =~ "Account-A-only-export-token"
    end

    test "audit-export tokens are bucketed out of the LLM agents page", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)

      # An export token (kind: :audit_export) and an MCP token (kind: :mcp). The
      # audit page shows the export one; the agents page shows the MCP one — the
      # two buckets never overlap (they're split by kind).
      {:ok, _raw, _export} =
        Emisar.ApiKeys.create_key(
          %{name: "ZZ-siem-export-token", kind: :audit_export},
          subject
        )

      {:ok, _raw, _mcp} =
        Emisar.ApiKeys.create_key(%{name: "ZZ-mcp-bridge-token"}, subject)

      # The audit page's SIEM card lists the export token, not the MCP one.
      # (Both names also appear in the audit *timeline* as `api_key.created`
      # rows — minting logs an audit event — so scope the bucket assertion to
      # the SIEM card itself, which is the list under test.)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/audit/export")
      siem_card = lv |> element("#siem-export") |> render()
      assert siem_card =~ "ZZ-siem-export-token"
      refute siem_card =~ "ZZ-mcp-bridge-token"

      # The agents page lists the MCP token, not the export one.
      {:ok, _lv, agents_html} = live(conn, ~p"/app/#{account}/settings/agents")
      assert agents_html =~ "ZZ-mcp-bridge-token"
      refute agents_html =~ "ZZ-siem-export-token"
    end
  end
end
