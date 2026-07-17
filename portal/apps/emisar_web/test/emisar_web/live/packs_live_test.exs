defmodule EmisarWeb.PacksLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/packs" do
    test "redirects anonymous users", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/anon/packs")
    end

    test "renders the empty state when the account has no pack observations", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/packs")

      assert html =~ "Packs"
      assert html =~ "No packs reported yet"
    end
  end

  describe "trust decisions" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    defp observe_pending_pack!(account) do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

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
          Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
        )

      pack_version
    end

    test "lists the pending pack with Trust/Reject for an owner", %{conn: conn, account: account} do
      _ = observe_pending_pack!(account)

      {:ok, lv, _dead_html} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "acme-tools"
      # Trust opens a plain (amber) confirm modal — trusting adopts code
      # fleet-wide; Reject (irreversible-feeling) opens the typed-confirm dialog.
      # Neither dispatches straight away.
      assert html =~ "Trust pack"
      assert has_element?(lv, ~s([id^="trust-"]))
      assert html =~ "open_reject"
      assert has_element?(lv, "#reject-pack")
    end

    test "the pending card names the runners advertising the pack (blast radius)", %{
      conn: conn,
      account: account
    } do
      runner =
        Fixtures.Runners.create_runner(
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

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "runner(s) advertise this"
      assert html =~ "canary-01"
      assert html =~ "staging"

      # The mono trusted/advertising readout (the <.kv layout={:grid}> rows):
      # a never-trusted pack has no baseline hash, and advertises abc123.
      assert html =~ "trusted:"
      assert html =~ "— (none yet)"
      assert html =~ "advertising:"
      assert html =~ "abc123"
    end

    test "the pending card lists the pack's actions + risk so trust isn't blind", %{
      conn: conn,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

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

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      # The trust decision now shows WHAT it authorizes, not just the hash.
      assert html =~ "Trusting authorizes"
      assert html =~ "acme.danger"
      assert html =~ "high"
    end

    test "a trusted version exposes a View contents disclosure that lazily lists its actions",
         %{conn: conn, user: user, account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(user, account)

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

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")

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

      # The disclosure stays OPEN across the lazy-load re-render — the bug was the
      # stream re-insert stripping the browser's native `<details open>` and
      # snapping it shut on the first click. The server now tracks the open state.
      assert has_element?(lv, "details[open]")

      # Toggling again closes it — the server's open state mirrors the browser's
      # native toggle, so they stay in sync instead of fighting.
      render_click(lv, "inspect_pack", %{
        "id" => pack_version.id,
        "pack-id" => pack_version.pack_id,
        "version" => pack_version.version
      })

      refute has_element?(lv, "details[open]")
    end

    test "a trusted PUBLISHED version links to its registry page; a custom one doesn't", %{
      conn: conn,
      user: user,
      account: account
    } do
      caddy = EmisarWeb.PacksRegistry.get("caddy")
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            %{
              "id" => "caddy.version",
              "pack_id" => "caddy",
              "title" => "Version",
              "kind" => "exec",
              "risk" => "low",
              "description" => "d",
              "args" => []
            },
            %{
              "id" => "acme.audit",
              "pack_id" => "acme-tools",
              "title" => "Audit",
              "kind" => "exec",
              "risk" => "low",
              "description" => "d",
              "args" => []
            }
          ],
          "packs" => %{
            # caddy advertised with its PUBLISHED hash → auto-trusts (matches baseline).
            "caddy" => %{"version" => caddy.version, "hash" => caddy.content_hash},
            "acme-tools" => %{"version" => "9.9", "hash" => "abc123"}
          }
        })

      # Trust the custom pack too, so both rows are trusted — only the published one links.
      {:ok, versions, _} = Emisar.Catalog.list_pack_versions(subject)
      acme = Enum.find(versions, &(&1.pack_id == "acme-tools"))
      {:ok, _} = Emisar.Catalog.trust_pack_version(acme.id, subject)

      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      # The published version links out to its public registry page, in a new tab.
      assert has_element?(lv, ~s(a[href="/packs/caddy"][target="_blank"]), "Registry")
      # The custom pack has no public registry page → no link.
      refute has_element?(lv, ~s(a[href="/packs/acme-tools"]))
    end

    test "a no-baseline (TOFU) pending pack shows the 'no baseline' block copy", %{
      conn: conn,
      account: account
    } do
      # a custom pack we ship no baseline for pins pending with
      # a NIL trusted hash (`hash == nil`), so the banner reads the TOFU copy ("a
      # pack we don't ship a baseline for. Dispatch is blocked until you approve its
      # contents.") rather than the hash-drift copy. `observe_pending_pack!` lands
      # exactly that state.
      _ = observe_pending_pack!(account)

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "pack we don&#39;t ship a baseline for"
      assert html =~ "Dispatch is blocked"
      # The hash-drift copy must NOT show — there's no prior trusted hash to drift from.
      refute html =~ "advertising a different hash"
    end

    test "a trusted version advertising no actions shows the empty View-contents copy", %{
      conn: conn,
      user: user,
      account: account
    } do
      # opening the disclosure for a trusted version that
      # advertises zero actions caches `[]` and renders the empty-set copy ("No
      # actions advertised for this version right now."), not a blank panel or a
      # crash. The runner pinned the pack with an empty actions list, then trust it.
      subject = Fixtures.Subjects.subject_for(user, account)
      pack_version = observe_pending_pack!(account)
      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      assert render(lv) =~ "View contents"

      html =
        render_click(lv, "inspect_pack", %{
          "id" => pack_version.id,
          "pack-id" => pack_version.pack_id,
          "version" => pack_version.version
        })

      assert html =~ "No actions advertised for this version right now."
    end

    test "Trust adopts the pending hash and clears the pending badge", %{
      conn: conn,
      account: account
    } do
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")
      html = render_click(lv, "trust", %{"id" => pack_version.id})

      assert html =~ "Trusted acme-tools"
      refute render(lv) =~ "phx-click=\"trust\""
    end

    test "Reject through the typed-confirm dialog hides a never-trusted custom pack from the list",
         %{
           conn: conn,
           account: account
         } do
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

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

    test "reject's typed-confirm: Confirm won't fire until the pack token matches", %{
      conn: conn,
      account: account
    } do
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

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
         %{conn: conn, account: account} do
      # The dialog is UX friction, not the gate: a crafted `reject` that bypasses
      # the modal is still served by the unchanged, server-authz-gated handler.
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")
      html = render_click(lv, "reject", %{"id" => pack_version.id})

      assert html =~ "Rejected drift on acme-tools"
      refute has_element?(lv, "#packs li", "acme-tools")
    end

    test "a trusted, non-retired version shows no Retired flag or override CTA (overlay dormant)",
         %{conn: conn, user: user, account: account} do
      # The custom acme-tools pack carries no retirement watermark, so its
      # trusted row is never retired — the rose flag, the warning block, and
      # the "Trust anyway" CTA all stay off. This locks the overlay against
      # false positives while exercising the `retired_notice` render path on
      # an ordinary row.
      subject = Fixtures.Subjects.subject_for(user, account)
      pack_version = observe_pending_pack!(account)
      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      refute html =~ "Retired"
      refute html =~ "Trust anyway"
      refute has_element?(lv, ~s([id^="override-"]))
    end

    test "a retired trusted version renders the rose warning with the admin override CTA",
         %{conn: conn, account: account} do
      # The prod-shaped row: trusted under an older release, then a newer
      # release raised the pack's watermark — trusted + retired + NO override
      # stamp. The trust API can't arrange it (trusting a retired version IS
      # the override), so the fixture inserts the row directly against a real
      # shipped watermark; "0.0.0" sits strictly below every one.
      {pack_id, _watermark} =
        Emisar.Catalog.PackBaseline.retired_below() |> Enum.sort() |> List.first()

      pack_version =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: "0.0.0"
        )

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "Retired by a newer release"
      assert html =~ "Trust anyway"
      assert has_element?(lv, "#override-#{pack_version.id}")
    end

    test "the override-retirement handler re-trusts and stays gated when dispatched directly",
         %{conn: conn, user: user, account: account} do
      # The "Trust anyway" CTA only renders on a genuinely-retired row — but a
      # crafted event against a non-retired row still hits the
      # server-authz-gated handler, which stamps the audited override on the
      # trusted row and flashes the confirmation.
      subject = Fixtures.Subjects.subject_for(user, account)
      pack_version = observe_pending_pack!(account)
      {:ok, trusted} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")
      html = render_click(lv, "override_retirement", %{"id" => trusted.id})

      assert html =~ "Re-trusted retired acme-tools"
    end

    test "a viewer's crafted override-retirement event is denied", %{account: account} do
      pack_version = observe_pending_pack!(account)

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/packs")

      html = render_click(lv, "override_retirement", %{"id" => pack_version.id})

      assert html =~ "Admin required to override pack retirement."
    end

    test "a re-advertised hash shows the action-set DIFF (added critical action) on the re-trust card",
         %{conn: conn, user: user, account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(user, account)

      # Trust v1 (one low action) — snapshots the manifest.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            %{
              "id" => "acme.status",
              "pack_id" => "acme-tools",
              "title" => "Status",
              "description" => "Read current service status.",
              "risk" => "low",
              "kind" => "exec",
              "args" => []
            }
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
              "title" => "Status",
              "description" => "Read current service status.",
              "risk" => "low",
              "kind" => "exec",
              "args" => []
            },
            %{
              "id" => "acme.wipe",
              "pack_id" => "acme-tools",
              "title" => "Wipe",
              "description" => "Delete test state.",
              "risk" => "critical",
              "kind" => "exec",
              "args" => []
            }
          ],
          "packs" => %{"acme-tools" => %{"version" => "9.9", "hash" => "v2"}}
        })

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "Changes since you last trusted"
      assert html =~ "added"
      assert html =~ "acme.wipe"
      assert html =~ "critical"
    end

    test "a viewer sees the pack but no Trust/Reject controls", %{account: account} do
      _ = observe_pending_pack!(account)

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "acme-tools"
      refute html =~ "phx-click=\"trust\""
    end

    test "the trust-review banner is singular for one pending version", %{
      conn: conn,
      account: account
    } do
      _ = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      assert render(lv) =~ "1 pack version needs trust review."
    end

    test "the trust-review banner pluralizes for several pending versions", %{
      conn: conn,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _runner} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [],
          # Two custom packs with no library baseline — both land pending.
          "packs" => %{
            "acme-tools" => %{"version" => "9.9", "hash" => "abc123"},
            "acme-extras" => %{"version" => "1.0", "hash" => "def456"}
          }
        })

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      assert render(lv) =~ "2 pack versions need trust review."
    end

    test "an operator sees the pending banner but no Trust/Reject controls", %{account: account} do
      # operator holds `view_catalog` (the pending banner that
      # explains WHY dispatch is blocked renders) but not `manage_catalog`, so the
      # Trust / Reject buttons are hidden (`subject_can_manage_packs?`).
      _ = observe_pending_pack!(account)

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/packs")

      html = render(lv)

      assert html =~ "acme-tools"
      # The banner that explains the block is still there…
      assert html =~ "needs trust review."
      # …but no mutate controls.
      refute html =~ "phx-click=\"trust\""
      refute html =~ "open_reject"
    end

    test "another account's packs never appear on this page", %{conn: conn, account: account} do
      # `list_pack_versions` scopes to the subject's account
      # via `for_subject`, so a foreign account's pending pack is invisible here.
      {_b_conn, _b_user, b_account} = register_and_log_in(build_conn())
      b_runner = Fixtures.Runners.create_runner(account_id: b_account.id)

      {:ok, _} =
        Emisar.Catalog.observe_state(b_runner, %{
          "hostname" => "host-b",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [],
          "packs" => %{"account-b-pack" => %{"version" => "1.0", "hash" => "bbb111"}}
        })

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      refute html =~ "account-b-pack"
      # A's own page reads as genuinely empty, not as B's inventory.
      assert html =~ "No packs reported yet"
    end

    test "a runner-advertised action title containing HTML renders escaped, not as raw markup",
         %{conn: conn, account: account} do
      # `action_id`/`title` are attacker-influenced (a runner
      # advertises them). The pending card renders them through escaped HEEx
      # (IL-16), so a <script> title shows up as literal text, never live markup.
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            %{
              "id" => "acme.evil",
              "pack_id" => "acme-tools",
              "title" => "<script>alert('xss')</script>",
              "kind" => "exec",
              "risk" => "high",
              "description" => "d",
              "args" => []
            }
          ],
          "packs" => %{"acme-tools" => %{"version" => "9.9", "hash" => "abc123"}}
        })

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      # Escaped form is present; the live <script> tag is not.
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>alert"
    end

    test "an operator's crafted trust event is denied — nothing trusted", %{account: account} do
      # the Trust button is hidden for an operator, but a
      # crafted `trust` event still hits the handler. `trust_pack_version` requires
      # `manage_catalog` → {:error,:unauthorized} → "Admin required to trust packs."
      # The pending row is untouched.
      pack_version = observe_pending_pack!(account)

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/packs")

      html = render_click(lv, "trust", %{"id" => pack_version.id})

      assert html =~ "Admin required to trust packs."
      # Still pending — it remains in the list.
      assert has_element?(lv, "#packs li", "acme-tools")
    end

    test "a viewer's crafted trust event is denied", %{account: account} do
      # (crafted form) — same `manage_catalog` gate, laxest role.
      pack_version = observe_pending_pack!(account)

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/packs")

      html = render_click(lv, "trust", %{"id" => pack_version.id})

      assert html =~ "Admin required to trust packs."
      assert has_element?(lv, "#packs li", "acme-tools")
    end

    test "a pending version offers no View-contents disclosure (only trusted rows do)", %{
      conn: conn,
      account: account
    } do
      # "View contents" is gated `:if={v.trust_state ==
      # :trusted}`. A pending version already renders its full advertised action
      # set inline, so the disclosure must NOT appear on it (it's the trusted
      # row's after-the-fact re-inspection affordance).
      _ = observe_pending_pack!(account)

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      # The pending pack is on the page (its banner explains the block)…
      assert html =~ "acme-tools"
      assert html =~ "needs trust review."
      # …but the trusted-only disclosure is absent.
      refute html =~ "View contents"
      refute html =~ "inspect_pack"
    end

    test "reopening the reject dialog on a second version overwrites the target", %{
      conn: conn,
      account: account
    } do
      # `open_reject` overwrites `@reject_target` and
      # `confirm_reset` clears the typed value, so opening v1, resetting, then
      # opening v2 leaves the dialog naming v2's token (not the stale v1).
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # Two custom packs with no baseline → both land pending.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [],
          "packs" => %{
            "acme-tools" => %{"version" => "9.9", "hash" => "abc123"},
            "acme-extras" => %{"version" => "1.0", "hash" => "def456"}
          }
        })

      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      {:ok, versions, _} = Emisar.Catalog.list_pack_versions(subject)
      tools = Enum.find(versions, &(&1.pack_id == "acme-tools"))
      extras = Enum.find(versions, &(&1.pack_id == "acme-extras"))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      # Target acme-tools, type its token, then reset + reopen on acme-extras.
      render_click(lv, "open_reject", %{
        "id" => tools.id,
        "pack_id" => tools.pack_id,
        "version" => tools.version
      })

      type_confirm_token(lv, "reject-pack", "acme-tools v9.9")
      render_click(lv, "confirm_reset", %{})

      html =
        render_click(lv, "open_reject", %{
          "id" => extras.id,
          "pack_id" => extras.pack_id,
          "version" => extras.version
        })

      # The dialog now names acme-extras, and the stale v9.9 token typed value
      # was cleared, so Confirm gates against the NEW token.
      assert html =~ "acme-extras v1.0"

      assert_raise ArgumentError, ~r/disabled/, fn ->
        confirm_dialog(lv, "reject-pack", "Reject pack")
      end

      # Typing the new token unblocks it and rejects acme-extras (not acme-tools).
      type_confirm_token(lv, "reject-pack", "acme-extras v1.0")
      html = confirm_dialog(lv, "reject-pack", "Reject pack")

      assert html =~ "Rejected drift on acme-extras"
      assert has_element?(lv, "#packs li", "acme-tools")
    end

    test "an operator's crafted reject event is denied — nothing rejected", %{account: account} do
      # closes GOV-011 denial — the Reject button is hidden for an operator, but a
      # crafted `reject` (bypassing the typed-confirm dialog) still hits the gated
      # handler. `reject_pack_version` requires `manage_catalog` →
      # "Admin required to reject packs." The pending row survives.
      pack_version = observe_pending_pack!(account)

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/packs")

      html = render_click(lv, "reject", %{"id" => pack_version.id})

      assert html =~ "Admin required to reject packs."
      assert has_element?(lv, "#packs li", "acme-tools")
    end

    test "trust/reject of an already-resolved row flashes 'Nothing pending'", %{
      conn: conn,
      account: account
    } do
      # once the row is trusted (no longer
      # pending), a crafted `trust`/`reject` event (e.g. a stale tab, or the loser
      # of a race the locked re-read already serialized) returns `:not_pending`.
      # The LV handlers map that to "Nothing pending on that pack." rather than
      # crashing or re-resolving.
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      # Trust it once — the row flips to :trusted and drops off the pending set.
      render_click(lv, "trust", %{"id" => pack_version.id})

      # A second trust on the now-resolved row is the no-op-with-flash path.
      assert render_click(lv, "trust", %{"id" => pack_version.id}) =~
               "Nothing pending on that pack."

      # Same for a crafted reject against the resolved row.
      assert render_click(lv, "reject", %{"id" => pack_version.id}) =~
               "Nothing pending on that pack."
    end
  end

  describe "filtering by action" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = Fixtures.Subjects.subject_for(user, account)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # postgres carries a low + a high action; nginx is low-only — enough for the
      # risk filter to include/exclude and for action-name search to bite.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            action_payload("postgres.activity", "postgres", "low"),
            action_payload("postgres.kill_backend", "postgres", "high"),
            action_payload("nginx.reload", "nginx", "low")
          ],
          "packs" => %{
            "postgres" => %{"version" => "1.0", "hash" => "hp"},
            "nginx" => %{"version" => "1.0", "hash" => "hn"}
          }
        })

      # Trust both so each renders as a trusted row with a View-contents disclosure.
      {:ok, versions, _} = Emisar.Catalog.list_pack_versions(subject)
      for v <- versions, do: {:ok, _} = Emisar.Catalog.trust_pack_version(v.id, subject)

      %{conn: conn, account: account}
    end

    defp action_payload(id, pack, risk) do
      %{
        "id" => id,
        "pack_id" => pack,
        "title" => id,
        "kind" => "exec",
        "risk" => risk,
        "description" => "d",
        "args" => []
      }
    end

    defp filter(lv, name, risk) do
      lv
      |> form("form[phx-change=filter]", %{"name" => name, "risk" => risk})
      |> render_change()
    end

    test "risk filter keeps only packs with an action at that tier and auto-expands them", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      # Unfiltered: both packs, contents collapsed.
      html = render(lv)
      assert html =~ "postgres"
      assert html =~ "nginx"
      refute html =~ "postgres.kill_backend"

      # Filter to high: postgres has a high action, nginx (low-only) drops. The
      # match auto-expands, listing the high action without a manual click.
      html = filter(lv, "", "high")
      assert html =~ "postgres.kill_backend"
      refute html =~ "nginx.reload"
      assert has_element?(lv, "details[open]")
    end

    test "search matches an action id and surfaces its pack, expanded", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      # The pack id "postgres" doesn't contain "postgres.activity" — the ACTION does.
      html = filter(lv, "postgres.activity", "")
      assert html =~ "postgres.activity"
      refute html =~ "nginx.reload"
    end

    test "search still matches a pack id (and drops non-matches)", %{conn: conn, account: account} do
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      html = filter(lv, "nginx", "")
      assert html =~ "nginx.reload"
      refute html =~ "postgres.kill_backend"
    end

    test "a filter with no matches shows the filtered-empty line, not the account-empty state", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      html = filter(lv, "", "critical")
      assert html =~ "No packs advertise a critical-risk action."
      refute html =~ "No packs reported yet."
    end
  end
end
