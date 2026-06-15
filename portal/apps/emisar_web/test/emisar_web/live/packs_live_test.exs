defmodule EmisarWeb.PacksLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/packs" do
    test "redirects anonymous users", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/packs")
    end

    test "renders the empty state when the account has no pack observations", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/packs")

      assert html =~ "Packs"
      assert html =~ "No packs reported yet"
    end
  end

  describe "trust decisions" do
    defp observe_pending_pack!(account) do
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)

      {:ok, _runner} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [],
          # No library baseline for this custom pack — lands pending,
          # never auto-trusted.
          "packs" => %{"acme-tools" => %{"version" => "9.9", "hash" => "abc123"}}
        })

      {:ok, [pack_version], _meta} =
        Emisar.Catalog.list_pack_versions(
          Emisar.Fixtures.subject_for(Emisar.Fixtures.user_fixture(), account)
        )

      pack_version
    end

    test "lists the pending pack with Trust/Reject for an owner", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      _ = observe_pending_pack!(account)

      {:ok, lv, _dead_html} = live(conn, ~p"/app/packs")
      html = render(lv)

      assert html =~ "acme-tools"
      # Trust stays a direct click; Reject (irreversible-feeling) now opens the
      # typed-confirm dialog instead of dispatching `reject` straight away.
      assert html =~ "phx-click=\"trust\""
      assert html =~ "open_reject"
      assert has_element?(lv, "#reject-pack")
    end

    test "the pending card names the runners advertising the pack (blast radius)", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      runner =
        Emisar.Fixtures.runner_fixture(
          account_id: account.id,
          name: "canary-01",
          group: "staging"
        )

      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            %{
              "id" => "acme.tool",
              "pack_id" => "acme-tools",
              "title" => "Tool",
              "kind" => "exec",
              "risk" => "low",
              "description" => "t",
              "args" => []
            }
          ],
          "packs" => %{"acme-tools" => %{"version" => "9.9", "hash" => "abc123"}}
        })

      {:ok, lv, _dead} = live(conn, ~p"/app/packs")
      html = render(lv)

      assert html =~ "runner(s) advertise this"
      assert html =~ "canary-01"
      assert html =~ "staging"
    end

    test "the pending card lists the pack's actions + risk so trust isn't blind", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)

      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            %{
              "id" => "acme.danger",
              "pack_id" => "acme-tools",
              "title" => "Do the dangerous thing",
              "kind" => "exec",
              "risk" => "high",
              "description" => "d",
              "args" => []
            }
          ],
          "packs" => %{"acme-tools" => %{"version" => "9.9", "hash" => "abc123"}}
        })

      {:ok, lv, _dead} = live(conn, ~p"/app/packs")
      html = render(lv)

      # The trust decision now shows WHAT it authorizes, not just the hash.
      assert html =~ "Trusting authorizes"
      assert html =~ "acme.danger"
      assert html =~ "high"
    end

    test "a trusted version exposes a View contents disclosure that lazily lists its actions",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      subject = Emisar.Fixtures.subject_for(user, account)

      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            %{
              "id" => "acme.audit",
              "pack_id" => "acme-tools",
              "title" => "Audit thing",
              "kind" => "exec",
              "risk" => "medium",
              "description" => "a",
              "args" => []
            }
          ],
          "packs" => %{"acme-tools" => %{"version" => "9.9", "hash" => "abc123"}}
        })

      {:ok, [pack_version], _} = Emisar.Catalog.list_pack_versions(subject)
      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, lv, _dead} = live(conn, ~p"/app/packs")

      # Collapsed by default — the action list isn't rendered until opened.
      assert render(lv) =~ "View contents"
      refute render(lv) =~ "acme.audit"

      # Opening the disclosure lazily loads + renders the action id + risk.
      html =
        render_click(lv, "inspect_pack", %{
          "id" => pack_version.id,
          "pack-id" => pack_version.pack_id,
          "version" => pack_version.version
        })

      assert html =~ "acme.audit"
      assert html =~ "medium"
    end

    test "Trust adopts the pending hash and clears the pending badge", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/packs")
      html = render_click(lv, "trust", %{"id" => pack_version.id})

      assert html =~ "Trusted acme-tools"
      refute render(lv) =~ "phx-click=\"trust\""
    end

    test "Reject through the typed-confirm dialog drops a never-trusted custom pack", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/packs")

      # Open the page-level reject dialog (stashes this version as the target),
      # type the pack token, then Confirm.
      render_click(lv, "open_reject", %{
        "id" => pack_version.id,
        "pack_id" => pack_version.pack_id,
        "version" => pack_version.version
      })

      type_confirm_token(lv, "reject-pack", "acme-tools v9.9")
      html = confirm_dialog(lv, "reject-pack", "Reject pack")

      assert html =~ "Rejected drift on acme-tools"
      # The flash quotes the pack name, so scope the absence check to the list.
      refute has_element?(lv, "#packs li", "acme-tools")
    end

    test "reject's typed-confirm: Confirm won't fire until the pack token matches", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/packs")

      render_click(lv, "open_reject", %{
        "id" => pack_version.id,
        "pack_id" => pack_version.pack_id,
        "version" => pack_version.version
      })

      # Empty + wrong token → Confirm disabled, `reject` never dispatched.
      assert_raise ArgumentError, ~r/disabled/, fn ->
        confirm_dialog(lv, "reject-pack", "Reject pack")
      end

      type_confirm_token(lv, "reject-pack", "acme-tools v0.0")

      assert_raise ArgumentError, ~r/disabled/, fn ->
        confirm_dialog(lv, "reject-pack", "Reject pack")
      end

      # The pending row is untouched — no bypassing event fired.
      assert has_element?(lv, "#packs li", "acme-tools")
    end

    test "the reject handler still works (and stays gated) when its event is dispatched directly",
         %{conn: conn} do
      # The dialog is UX friction, not the gate: a crafted `reject` that bypasses
      # the modal is still served by the unchanged, server-authz-gated handler.
      {conn, _user, account} = register_and_log_in(conn)
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/packs")
      html = render_click(lv, "reject", %{"id" => pack_version.id})

      assert html =~ "Rejected drift on acme-tools"
      refute has_element?(lv, "#packs li", "acme-tools")
    end

    test "a re-advertised hash shows the action-set DIFF (added critical action) on the re-trust card",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      subject = Emisar.Fixtures.subject_for(user, account)

      # Trust v1 (one low action) — snapshots the manifest.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            %{"id" => "acme.status", "pack_id" => "acme-tools", "risk" => "low", "kind" => "exec"}
          ],
          "packs" => %{"acme-tools" => %{"version" => "9.9", "hash" => "v1"}}
        })

      {:ok, [pack_version], _} = Emisar.Catalog.list_pack_versions(subject)
      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      # A new hash that ADDS a critical action → flips back to pending.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            %{
              "id" => "acme.status",
              "pack_id" => "acme-tools",
              "risk" => "low",
              "kind" => "exec"
            },
            %{
              "id" => "acme.wipe",
              "pack_id" => "acme-tools",
              "risk" => "critical",
              "kind" => "exec"
            }
          ],
          "packs" => %{"acme-tools" => %{"version" => "9.9", "hash" => "v2"}}
        })

      {:ok, lv, _dead} = live(conn, ~p"/app/packs")
      html = render(lv)

      assert html =~ "Changes since you last trusted"
      assert html =~ "added"
      assert html =~ "acme.wipe"
      assert html =~ "critical"
    end

    test "a viewer sees the pack but no Trust/Reject controls", %{conn: conn} do
      {_owner_conn, _user, account} = register_and_log_in(conn)
      _ = observe_pending_pack!(account)

      viewer = Emisar.Fixtures.user_fixture()

      _ =
        Emisar.Fixtures.membership_fixture(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/packs")
      html = render(lv)

      assert html =~ "acme-tools"
      refute html =~ "phx-click=\"trust\""
    end
  end
end
