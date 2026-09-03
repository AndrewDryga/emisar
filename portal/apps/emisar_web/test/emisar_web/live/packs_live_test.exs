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

    test "a crafted filter event with non-binary params does not crash the socket", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      # `name[]=` / `risk[]=` post lists; String.trim/1 would crash the socket.
      assert render_hook(lv, "filter", %{"name" => ["oops"], "risk" => ["bad"]})
    end

    test "lists in-scope packs in full and names the rest for discovery only", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _runner} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            %{
              "id" => "hidden.wipe",
              "pack_id" => "hidden-tools",
              "pack_version" => "7.7",
              "summary" => "Wipe the host",
              "risk" => "critical",
              "args" => []
            }
          ],
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("acme")
            },
            "hidden-tools" => %{
              "version" => "7.7",
              "hash" => Fixtures.Catalog.pack_hash("hidden")
            }
          }
        })

      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

      {:ok, access} =
        Emisar.Accounts.RunnerAccess.new(:all, [], [], :restricted, ["acme-tools"])

      Fixtures.Memberships.force_runner_access(membership, access)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "acme-tools"
      assert html =~ "9.9"
      assert html =~ "1 pack · 1 version"
      assert has_element?(lv, "#packs.mt-10")

      # The out-of-scope pack is NAMED, and that is all: no version row, no
      # hash, no action, no trust state, no advertiser.
      assert html =~ "Outside your pack access"
      assert has_element?(lv, "section.mt-12", "Outside your pack access")
      assert html =~ "hidden-tools"
      # Read the page's TEXT, not its markup: a version like "7.7" also occurs in
      # the coordinates of an inline icon's path data.
      text = html |> LazyHTML.from_fragment() |> LazyHTML.text()
      refute text =~ "7.7"
      refute text =~ "hidden.wipe"
      refute text =~ Fixtures.Catalog.pack_hash("hidden")
    end

    test "uses content-start spacing when only out-of-scope packs are visible", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: "hidden-tools"
      )

      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

      {:ok, access} =
        Emisar.Accounts.RunnerAccess.new(:all, [], [], :restricted, ["acme-tools"])

      Fixtures.Memberships.force_runner_access(membership, access)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      refute has_element?(lv, "#packs.mt-10")
      assert has_element?(lv, "section.mt-6", "Outside your pack access")
      refute has_element?(lv, "section.mt-12", "Outside your pack access")
    end

    test "a crafted contents event on an out-of-scope pack reveals nothing", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _runner} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [
            %{
              "id" => "hidden.wipe",
              "pack_id" => "hidden-tools",
              "pack_version" => "7.7",
              "summary" => "Wipe the host",
              "risk" => "critical",
              "args" => []
            }
          ],
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("acme")
            },
            "hidden-tools" => %{
              "version" => "7.7",
              "hash" => Fixtures.Catalog.pack_hash("hidden")
            }
          }
        })

      hidden =
        Emisar.Catalog.PackVersion.Query.all()
        |> Emisar.Catalog.PackVersion.Query.by_pack_id("hidden-tools")
        |> Emisar.Repo.one!()

      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

      {:ok, access} =
        Emisar.Accounts.RunnerAccess.new(:all, [], [], :restricted, ["acme-tools"])

      Fixtures.Memberships.force_runner_access(membership, access)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      # Discovery names the pack, so its version id is guessable — the contents
      # read is scoped in the Catalog, not by which chevrons the page drew.
      html =
        render_hook(lv, "inspect_pack", %{
          "id" => hidden.id,
          "pack-id" => "hidden-tools",
          "version" => "7.7"
        })

      refute html =~ "hidden.wipe"
      refute html =~ "Wipe the host"
    end
  end

  describe "trust decisions" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    defp persisted_owner_subject(account) do
      user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      Fixtures.Subjects.subject_for(user, account)
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
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("abc123")
            }
          }
        })

      {:ok, [pack_version], _meta} =
        Emisar.Catalog.list_pack_versions(persisted_owner_subject(account))

      pack_version
    end

    test "lists the pending pack with Trust/Reject for an owner", %{conn: conn, account: account} do
      pack_version = observe_pending_pack!(account)

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

      assert has_element?(
               lv,
               ~s(a[href="/app/#{account.slug}/audit?target_kind=pack_version&target_id=#{pack_version.id}"]),
               "View activity"
             )
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

      hash = Fixtures.Catalog.pack_hash("abc123")

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
          "packs" => %{"acme-tools" => %{"version" => "9.9", "hash" => hash}}
        })

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "runner still advertising this"
      assert html =~ "canary-01"
      assert html =~ "staging"

      # A never-trusted pack has no baseline hash to diff against, so the readout
      # skips the empty "trusted: (none yet)" and shows just the bytes on the runner.
      refute html =~ "(none yet)"
      assert html =~ "on the runner"
      assert html =~ hash
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
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("abc123")
            }
          }
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
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("abc123")
            }
          }
        })

      {:ok, [pack_version], _} = Emisar.Catalog.list_pack_versions(subject)
      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")

      # Collapsed by default — the action list isn't rendered until the row's
      # leading chevron opens it.
      refute render(lv) =~ "acme.audit"
      assert has_element?(lv, ~s(button[aria-expanded="false"][phx-click="inspect_pack"]))

      # Opening the expansion lazily loads + renders the action id + risk.
      html =
        render_click(lv, "inspect_pack", %{
          "id" => pack_version.id,
          "pack-id" => pack_version.pack_id,
          "version" => pack_version.version
        })

      assert html =~ "acme.audit"
      assert html =~ "medium"

      # The expansion stays OPEN across the stream re-insert — the server
      # tracks the open state, so the lazy-load re-render can't snap it shut.
      assert has_element?(lv, ~s(button[aria-expanded="true"]))

      # Toggling again closes it.
      render_click(lv, "inspect_pack", %{
        "id" => pack_version.id,
        "pack-id" => pack_version.pack_id,
        "version" => pack_version.version
      })

      refute render(lv) =~ "acme.audit"
      refute has_element?(lv, ~s(button[aria-expanded="true"]))
    end

    test "an opened contents disclosure survives a catalog reload", %{
      conn: conn,
      user: user,
      account: account
    } do
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
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("abc123")
            }
          }
        })

      {:ok, [pack_version], _} = Emisar.Catalog.list_pack_versions(subject)
      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")

      render_click(lv, "inspect_pack", %{
        "id" => pack_version.id,
        "pack-id" => pack_version.pack_id,
        "version" => pack_version.version
      })

      assert has_element?(lv, ~s(button[aria-expanded="true"]))

      # A reload — a peer's decision, the retention sweep, "Clean up now" — used
      # to replace the open set with whatever the FILTER matched, which with no
      # filter is nothing: the contents an admin opened to review snapped shut.
      send(lv.pid, :refresh_packs)

      assert render(lv) =~ "acme.audit"
      assert has_element?(lv, ~s(button[aria-expanded="true"]))
    end

    test "toggling contents re-reads only the opened action list", %{
      conn: conn,
      user: user,
      account: account
    } do
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
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("abc123")
            }
          }
        })

      {:ok, [pack_version], _} = Emisar.Catalog.list_pack_versions(subject)
      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")

      # A disclosure toggle changes nothing durable, so it must never re-read
      # the projection (on a real fleet that re-read was a visible per-click
      # delay) — the stream re-insert comes from the last load's group cache.
      # `render_click` is synchronous and the queries run in the view process,
      # so draining after it returns counts them deterministically.
      test_pid = self()
      view_pid = lv.pid
      handler = make_ref()

      :telemetry.attach(
        handler,
        [:emisar, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == view_pid, do: send(test_pid, :repo_query)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      toggle = fn ->
        render_click(lv, "inspect_pack", %{
          "id" => pack_version.id,
          "pack-id" => pack_version.pack_id,
          "version" => pack_version.version
        })

        drain_repo_query_count()
      end

      # First open reads current membership + scope, then exactly that action
      # list. It still does not rebuild the account projection.
      assert toggle.() == 3

      # Closing, and re-opening the already-cached list, read nothing.
      assert toggle.() == 0
      assert toggle.() == 0
      assert render(lv) =~ "acme.audit"
    end

    test "a PUBLISHED pack's header links to its registry page; a custom pack's doesn't", %{
      conn: conn,
      account: account
    } do
      # The registry page is pack-scoped, so the link rides the pack HEADER —
      # for any trust state (a pending or retired version is exactly when the
      # registry reference helps) — never a version row.
      caddy = Emisar.Catalog.PublishedRegistry.get("caddy")
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [],
          "packs" => %{
            # A hash that does NOT match the published one — the row lands
            # pending, and the pack-level link must render anyway.
            "caddy" => %{
              "version" => caddy.version,
              "hash" => Fixtures.Catalog.pack_hash("UNPUBLISHED")
            },
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("abc123")
            }
          }
        })

      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      # The published pack links out to its public registry page, in a new tab.
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
      assert has_element?(lv, ~s(button[aria-expanded="false"][phx-click="inspect_pack"]))

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

    test "a fleet descriptor conflict blocks Trust and names the disagreeing runners", %{
      conn: conn,
      account: account
    } do
      runner_alpha = Fixtures.Runners.create_runner(account_id: account.id, name: "alpha-box")
      runner_bravo = Fixtures.Runners.create_runner(account_id: account.id, name: "bravo-box")

      for {runner, description} <- [{runner_alpha, "Honest."}, {runner_bravo, "Hostile."}] do
        {:ok, _runner} =
          Emisar.Catalog.observe_state(runner, %{
            "hostname" => "host-1",
            "version" => "0.1.0",
            "labels" => %{},
            "actions" => [
              %{
                "id" => "acme.deploy",
                "pack_id" => "acme-tools",
                "title" => "Deploy",
                "kind" => "exec",
                "risk" => "high",
                "description" => description,
                "args" => []
              }
            ],
            "packs" => %{
              "acme-tools" => %{
                "version" => "9.9",
                "hash" => Fixtures.Catalog.pack_hash("abc123")
              }
            }
          })
      end

      {:ok, [pack_version], _meta} =
        Emisar.Catalog.list_pack_versions(persisted_owner_subject(account))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")
      html = render_click(lv, "trust", %{"id" => pack_version.id})

      assert html =~
               "Runners alpha-box and bravo-box disagree about what this version contains (action acme.deploy)."

      assert html =~ "Trust stays blocked until they advertise identical contents."
      # Fail-closed: the row stays pending with its Trust affordance intact.
      assert has_element?(lv, "#trust-#{pack_version.id}")
    end

    test "Reject through the typed-confirm dialog keeps the pack listed as rejected",
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

      assert html =~ "Rejected acme-tools v9.9. It stays listed as rejected"
      # The rejected row stays visible — quietly, with the fix-admin-mistake
      # Trust affordance — instead of vanishing from the list.
      assert has_element?(lv, "#packs li", "acme-tools")
      assert has_element?(lv, "#packs li", "Rejected — dispatch refuses this version")

      assert has_element?(
               lv,
               ~s([phx-click="open_pack_action"][phx-value-action="trust"][phx-value-id="#{pack_version.id}"])
             )
    end

    test "a rejected version can be trusted again from its quiet row", %{
      conn: conn,
      account: account
    } do
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")
      render_click(lv, "reject", %{"id" => pack_version.id})

      lv
      |> element(
        ~s([phx-click="open_pack_action"][phx-value-action="trust"][phx-value-id="#{pack_version.id}"])
      )
      |> render_click()

      html = confirm_dialog(lv, "pack-action", "Trust pack")

      assert html =~ "Trusted acme-tools v9.9."
      refute has_element?(lv, "#packs li", "Rejected — dispatch refuses this version")
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

      assert html =~ "Rejected acme-tools v9.9. It stays listed as rejected"
      assert has_element?(lv, "#packs li", "acme-tools")
    end

    test "a trusted, non-retired version shows no Retired flag or override CTA (overlay dormant)",
         %{conn: conn, user: user, account: account} do
      # The custom acme-tools pack carries no retirement watermark, so its
      # trusted row is never retired — the rose flag, the warning block, and
      # the "Override retirement" CTA all stay off. This locks the overlay
      # against false positives while exercising the `retired_notice` render
      # path on an ordinary row.
      subject = Fixtures.Subjects.subject_for(user, account)
      pack_version = observe_pending_pack!(account)
      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      refute html =~ "Retired"
      refute html =~ "Override retirement"
      refute has_element?(lv, ~s([id^="override-"]))
    end

    test "a trusted version below the shipped current shows a quiet update-available note",
         %{conn: conn, account: account} do
      # A shipped pack that retires nothing, trusted at a version below its
      # current: outdated-but-safe, so the gentle "update available" hint (never
      # rose/amber) names the successor + the install command.
      all_pack_ids =
        Emisar.Catalog.PackBaseline.all() |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      pack_id = List.first(all_pack_ids -- Map.keys(Emisar.Catalog.PackBaseline.retired_below()))
      current = Emisar.Catalog.PackBaseline.current_version(pack_id)

      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: pack_id,
        version: "0.0.0"
      )

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "Update available"
      assert html =~ "v#{current} has shipped"
      assert html =~ "emisar pack install #{pack_id}"
      # A neutral nudge, not a warning — no rose retired block on this row.
      refute html =~ "Retired by a newer release"
    end

    test "multiple outdated versions of one pack show a SINGLE update-available note",
         %{conn: conn, account: account} do
      # The nudge is a pack-level fact — `newer_version` returns the same current
      # shipped version for every outdated row — so it is said ONCE per pack, not
      # repeated on each stale version (the regression: it duplicated per version).
      all_pack_ids =
        Emisar.Catalog.PackBaseline.all() |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      pack_id = List.first(all_pack_ids -- Map.keys(Emisar.Catalog.PackBaseline.retired_below()))
      current = Emisar.Catalog.PackBaseline.current_version(pack_id)

      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: pack_id,
        version: "0.0.0"
      )

      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: pack_id,
        version: "0.0.1"
      )

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "v#{current} has shipped"
      occurrences = Regex.scan(~r/Update available/, html) |> length()
      assert occurrences == 1
    end

    test "no update note when the current version is installed beside an older one",
         %{conn: conn, account: account} do
      # The mixed case (the seeded postgres 0.2.11 + 0.2.9): you already run the
      # current shipped version on one runner and an older one on another. You HAVE
      # the latest, so nudging "update to <current>" — a version you already run —
      # would be wrong; stay silent.
      all_pack_ids =
        Emisar.Catalog.PackBaseline.all() |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      pack_id = List.first(all_pack_ids -- Map.keys(Emisar.Catalog.PackBaseline.retired_below()))
      current = Emisar.Catalog.PackBaseline.current_version(pack_id)

      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: pack_id,
        version: current
      )

      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: pack_id,
        version: "0.0.0"
      )

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      refute html =~ "Update available"
    end

    test "a trusted CURRENT version shows no update-available note",
         %{conn: conn, account: account} do
      {{pack_id, _v}, _hash} = Emisar.Catalog.PackBaseline.all() |> Enum.at(0)
      current = Emisar.Catalog.PackBaseline.current_version(pack_id)

      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: pack_id,
        version: current
      )

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      refute html =~ "Update available"
    end

    test "a retired version shows the rose retired block and NOT the update-available note",
         %{conn: conn, account: account} do
      # Retirement takes precedence — the stronger rose block owns the row; the
      # gentle hint stays silent and never stacks on top of it.
      {pack_id, _watermark} =
        Emisar.Catalog.PackBaseline.retired_below() |> Enum.sort() |> List.first()

      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: pack_id,
        version: "0.0.0"
      )

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "Retired by a newer release"
      refute html =~ "Update available"
    end

    test "a retired trusted version WITH runners still on it shows the update fix + override CTA",
         %{conn: conn, account: account} do
      # The prod-shaped row: trusted under an older release, then a newer
      # release raised the pack's watermark — trusted + retired + NO override
      # stamp — and a runner is STILL advertising the old version. The trust API
      # can't arrange trusted+retired (trusting a retired version IS the
      # override), so the fixture inserts the row directly against a real shipped
      # watermark ("0.0.0" sits strictly below every one); the runner's own
      # advertised `packs` map is what makes it "still on it". The fix is to
      # update those runners; override is the escape hatch only for when you
      # genuinely can't yet.
      {pack_id, _watermark} =
        Emisar.Catalog.PackBaseline.retired_below() |> Enum.sort() |> List.first()

      runner = Fixtures.Runners.create_runner(account_id: account.id)

      pack_version =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: "0.0.0"
        )

      Fixtures.Runners.advertise_packs(runner, %{pack_id => %{"version" => "0.0.0"}})

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "Retired by a newer release"
      assert html =~ "update the runners still on it"
      assert html =~ "Override retirement"
      assert has_element?(lv, "#override-#{pack_version.id}")
      # Removal is futile while a runner re-advertises it, so it's dropped here.
      refute html =~ "Remove version"
    end

    test "a retired trusted version with NO runners recommends removal, not override",
         %{conn: conn, account: account} do
      # Same trusted+retired row, but every runner has updated away — nothing
      # advertises it (no RunnerAction). There's nothing to update and nothing to
      # keep running, so the block recommends removing the dead version and drops
      # the override escape hatch entirely.
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
      assert html =~ "no runner is on it"
      assert html =~ "Remove version"
      refute html =~ "Override retirement"
      refute has_element?(lv, "#override-#{pack_version.id}")
    end

    test "a fleet too large to read whole offers neither Remove nor Override",
         %{conn: conn, account: account} do
      # The page reads 100 runners; past that it cannot prove the retired
      # version is unused, so "no runner is on it — remove it" would be a lie.
      # It says the fleet is only partly read and offers updating instead.
      {pack_id, _watermark} =
        Emisar.Catalog.PackBaseline.retired_below() |> Enum.sort() |> List.first()

      pack_version =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: "0.0.0"
        )

      for _ <- 1..101 do
        Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      end

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "Retired by a newer release"
      assert html =~ "more runners than this page"
      assert html =~ "emisar pack install #{pack_id}"
      refute html =~ "no runner is on it"
      refute html =~ "Remove version"
      refute html =~ "Override retirement"
      refute has_element?(lv, "#override-#{pack_version.id}")
    end

    test "a partly-read fleet states a floor, never an exact advertiser count",
         %{conn: conn, account: account} do
      {pack_id, _watermark} =
        Emisar.Catalog.PackBaseline.retired_below() |> Enum.sort() |> List.first()

      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: pack_id,
        version: "0.0.0"
      )

      # Named first in group/name order, so it survives the 100-runner cap.
      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "aaa-canary",
          group: "aaa",
          connected?: false
        )

      Fixtures.Runners.advertise_packs(runner, %{pack_id => %{"version" => "0.0.0"}})

      for _ <- 1..101 do
        Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      end

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "At least 1"
      assert html =~ "aaa-canary"
      assert html =~ "others may be on it too"
      assert html =~ "Override retirement"
    end

    test "a first-seen retired version reads as retired (upgrade the runner), not an unknown pack",
         %{conn: conn, account: account} do
      # A lagging runner advertises a SHIPPED pack at a version below its
      # retirement watermark — never trusted, so it lands pending, but the
      # watermark prunes it from the baseline (lookup == nil). It must NOT read
      # as "a pack we don't ship a baseline for" with a plain Trust: it's OUR
      # pack, retired by a security fix, and the remedy is upgrading the runner,
      # not re-authorizing the superseded bytes.
      {pack_id, _watermark} =
        Emisar.Catalog.PackBaseline.retired_below() |> Enum.sort() |> List.first()

      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _runner} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "host-1",
          "version" => "0.1.0",
          "labels" => %{},
          "actions" => [],
          "packs" => %{
            pack_id => %{
              "version" => "0.0.0",
              "hash" => Fixtures.Catalog.pack_hash("abc123")
            }
          }
        })

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "Retired by a newer release"
      assert html =~ "emisar pack install #{pack_id}"
      assert html =~ "Trust anyway"
      refute html =~ "pack we don&#39;t ship a baseline for"

      # The command updates the PACK on that host, not the runner binary, and
      # the body names where to run it.
      assert html =~ "Update the pack to"
      refute html =~ "Update the runner to"
      assert html =~ "Update the pack on the runners still on it"
      # The count sits in its own span, so the noun is what reads back here —
      # singular, because exactly one runner advertises it.
      assert html =~ "runner still on this retired version"
      refute html =~ "runners still on this retired version"
      # Named by the runner the operator knows, not the hostname it reported.
      assert html =~ runner.name
    end

    test "a retired version awaiting review that NO runner advertises offers only Reject",
         %{conn: conn, account: account} do
      # The reported state: a pending row below the watermark, and every runner
      # has since moved off it — a complete fleet read finds nobody. Claiming
      # "runners are still on the old version" there is false, and an update
      # command fixes a problem that no longer exists; rejecting is what clears
      # the row.
      {pack_id, _watermark} =
        Emisar.Catalog.PackBaseline.retired_below() |> Enum.sort() |> List.first()

      Fixtures.Catalog.create_observed_pack_version(
        account_id: account.id,
        pack_id: pack_id,
        version: "0.0.0"
      )

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "Retired by a newer release"
      assert html =~ "No runner advertises it now"
      refute html =~ "still on it"
      refute html =~ "emisar pack install #{pack_id}"
      assert html =~ "Reject"
    end

    test "a retired-blocked version lights the Packs nav badge; overriding clears it", %{
      conn: conn,
      account: account
    } do
      # The retired fleet state had NO nav signal — the badge counted only
      # pending trust reviews, not retired versions awaiting a decision. A runner
      # is still on the old version, so override is the offered resolution.
      {pack_id, _watermark} =
        Emisar.Catalog.PackBaseline.retired_below() |> Enum.sort() |> List.first()

      runner = Fixtures.Runners.create_runner(account_id: account.id)

      pack_version =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: "0.0.0"
        )

      Fixtures.Runners.advertise_packs(runner, %{pack_id => %{"version" => "0.0.0"}})

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      badge = "a[href='/app/#{account.slug}/packs'] span.tabular-nums"
      assert has_element?(lv, badge, "1")

      render_click(lv, "override_retirement", %{"id" => pack_version.id})

      refute has_element?(lv, badge)
    end

    test "a rejected retired version shows neither the chip nor the rose warning", %{
      conn: conn,
      user: user,
      account: account
    } do
      # Revoking trust in a retired version is the quiet path: rejected already
      # means dispatch-blocked, so stacking a RETIRED marker on it would be
      # noise — the alert (and chip) return only if it's trusted again.
      subject = Fixtures.Subjects.subject_for(user, account)

      {pack_id, _watermark} =
        Emisar.Catalog.PackBaseline.retired_below() |> Enum.sort() |> List.first()

      pack_version =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: "0.0.0"
        )

      {:ok, _} = Emisar.Catalog.revoke_pack_version_trust(pack_version.id, subject)

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      refute html =~ "RETIRED"
      refute html =~ "Retired by a newer release"
      refute has_element?(lv, "#override-#{pack_version.id}")
      assert has_element?(lv, "#packs li", "Rejected — dispatch refuses this version")
    end

    test "the override-retirement handler re-trusts and stays gated when dispatched directly",
         %{conn: conn, user: user, account: account} do
      # The "Override retirement" CTA only renders on a genuinely-retired row — but a
      # crafted event against a non-retired row still hits the
      # server-authz-gated handler, which stamps the audited override on the
      # trusted row and flashes the confirmation.
      subject = Fixtures.Subjects.subject_for(user, account)
      pack_version = observe_pending_pack!(account)
      {:ok, trusted} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")
      html = render_click(lv, "override_retirement", %{"id" => trusted.id})

      assert html =~ "Overrode the retirement of acme-tools"
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

    test "an owner revokes trust from the row's quiet control — the version turns rejected", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.subject_for(user, account)
      pack_version = observe_pending_pack!(account)
      {:ok, trusted} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      selector =
        ~s([phx-click="open_pack_action"][phx-value-action="revoke_trust"][phx-value-id="#{trusted.id}"])

      assert has_element?(lv, selector)

      lv |> element(selector) |> render_click()
      html = confirm_dialog(lv, "pack-action", "Revoke trust")

      assert html =~ "Revoked trust in acme-tools v9.9."
      assert has_element?(lv, "#packs li", "Rejected — dispatch refuses this version")
      refute has_element?(lv, selector)
    end

    test "a viewer's crafted revoke-trust event is denied", %{account: account} do
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

      html = render_click(lv, "revoke_trust", %{"id" => pack_version.id})

      assert html =~ "Admin required to revoke pack trust."
    end

    test "an owner deletes a version — the row disappears with the re-insert warning", %{
      conn: conn,
      account: account
    } do
      pack_version = observe_pending_pack!(account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      selector =
        ~s([phx-click="open_pack_action"][phx-value-action="delete_version"][phx-value-id="#{pack_version.id}"])

      assert has_element?(lv, selector)
      refute has_element?(lv, "#pack-action")

      lv |> element(selector) |> render_click()
      assert has_element?(lv, "#pack-action")
      html = confirm_dialog(lv, "pack-action", "Delete version")

      assert html =~ "Deleted acme-tools v9.9."
      assert html =~ "re-insert it as a fresh trust decision"
      refute has_element?(lv, "#packs li", "acme-tools")
    end

    test "an owner deletes a whole pack from its header control", %{
      conn: conn,
      account: account,
      user: user
    } do
      low_runner = Fixtures.Runners.create_runner(account_id: account.id)
      high_runner = Fixtures.Runners.create_runner(account_id: account.id)

      for {runner, version, action} <- [
            {low_runner, "1.0", action_payload("acme.status", "acme-tools", "low")},
            {high_runner, "2.0", action_payload("acme.wipe", "acme-tools", "high")}
          ] do
        {:ok, _runner} =
          Emisar.Catalog.observe_state(runner, %{
            "hostname" => "host-#{version}",
            "version" => "0.1.0",
            "labels" => %{},
            "actions" => [action],
            "packs" => %{
              "acme-tools" => %{
                "version" => version,
                "hash" => Fixtures.Catalog.pack_hash(version)
              }
            }
          })
      end

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      html = filter(lv, "", "high")
      assert html =~ "acme.wipe"
      refute html =~ "acme.status"

      selector =
        ~s([phx-click="open_pack_action"][phx-value-action="delete_pack"][phx-value-pack-id="acme-tools"])

      assert has_element?(lv, selector)

      lv |> element(selector) |> render_click()
      confirmation = render(lv)

      assert confirmation =~ "Removes every recorded version of"
      assert confirmation =~ "acme-tools"
      refute confirmation =~ "Removes all 1 version"

      html = confirm_dialog(lv, "pack-action", "Delete pack")

      assert html =~ "Deleted acme-tools (2 versions)."
      refute has_element?(lv, "#packs li", "acme-tools")

      subject = Fixtures.Subjects.subject_for(user, account)
      assert {:ok, [], _meta} = Emisar.Catalog.list_pack_versions(subject)
    end

    test "a viewer sees no delete controls and their crafted delete is denied", %{
      account: account
    } do
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

      refute has_element?(
               lv,
               ~s([phx-click="open_pack_action"][phx-value-action="delete_version"][phx-value-id="#{pack_version.id}"])
             )

      refute has_element?(
               lv,
               ~s([phx-click="open_pack_action"][phx-value-action="delete_pack"][phx-value-pack-id="acme-tools"])
             )

      render_click(lv, "open_pack_action", %{
        "action" => "delete_version",
        "id" => pack_version.id
      })

      refute has_element?(lv, "#pack-action")

      html = render_click(lv, "delete_version", %{"id" => pack_version.id})
      assert html =~ "Admin required to delete packs."

      html = render_click(lv, "delete_pack", %{"pack_id" => "acme-tools"})
      assert html =~ "Admin required to delete packs."

      # The pending row survives both crafted attempts.
      assert has_element?(lv, "#packs li", "acme-tools")
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
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("v1")
            }
          }
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
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("v2")
            }
          }
        })

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")
      html = render(lv)

      assert html =~ "Changes since you last trusted"
      assert html =~ "added"
      assert html =~ "acme.wipe"
      assert html =~ "critical"
    end

    # A rewrite the risk pills cannot show — the model-facing description and the
    # output contract a runbook binds to — is exactly what the operator is being
    # asked to re-trust, so the changed row has to name the fields that moved.
    test "a changed row names the descriptor fields that moved, beyond risk and kind",
         %{conn: conn, user: user, account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _observed} =
        Emisar.Catalog.observe_state(
          runner,
          drift_state("Read current service status.", nil, "v1")
        )

      {:ok, [pack_version], _metadata} = Emisar.Catalog.list_pack_versions(subject)
      {:ok, _trusted} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      output_schema = %{"type" => "object", "properties" => %{"up" => %{"type" => "boolean"}}}

      {:ok, _redvertised} =
        Emisar.Catalog.observe_state(
          runner,
          drift_state("Now also reads the queue.", output_schema, "v2")
        )

      {:ok, lv, _dead} = live(conn, ~p"/app/#{account}/packs")

      changed =
        lv |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("li") |> LazyHTML.text()

      assert changed =~ "~ changed"
      assert changed =~ "description, output_schema, summary"
      refute changed =~ "risk,"
    end

    defp drift_state(description, output_schema, hash) do
      %{
        "hostname" => "h",
        "version" => "0.1.0",
        "labels" => %{},
        "actions" => [
          %{
            "id" => "acme.status",
            "pack_id" => "acme-tools",
            "title" => "Status",
            "description" => description,
            "output_schema" => output_schema,
            "risk" => "low",
            "kind" => "exec",
            "args" => []
          }
        ],
        "packs" => %{
          "acme-tools" => %{"version" => "9.9", "hash" => Fixtures.Catalog.pack_hash(hash)}
        }
      }
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
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("abc123")
            },
            "acme-extras" => %{
              "version" => "1.0",
              "hash" => Fixtures.Catalog.pack_hash("def456")
            }
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
          "packs" => %{
            "account-b-pack" => %{
              "version" => "1.0",
              "hash" => Fixtures.Catalog.pack_hash("bbb111")
            }
          }
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
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("abc123")
            }
          }
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

    test "invalid pack contents explain why retrying trust cannot work", %{
      conn: conn,
      user: user,
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
              "id" => "acme.invalid",
              "pack_id" => "acme-tools",
              "title" => String.duplicate("t", 161),
              "kind" => "exec",
              "risk" => "low",
              "description" => "Inspect state.",
              "args" => []
            }
          ],
          "packs" => %{
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("invalid")
            }
          }
        })

      subject = Fixtures.Subjects.subject_for(user, account)
      {:ok, [pack_version], _meta} = Emisar.Catalog.list_pack_versions(subject)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      html = render_click(lv, "trust", %{"id" => pack_version.id})

      assert html =~
               "Pack contents are invalid — fix the pack and have the runner advertise it again."
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
      # …but the trusted-only contents chevron is absent.
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
            "acme-tools" => %{
              "version" => "9.9",
              "hash" => Fixtures.Catalog.pack_hash("abc123")
            },
            "acme-extras" => %{
              "version" => "1.0",
              "hash" => Fixtures.Catalog.pack_hash("def456")
            }
          }
        })

      subject = persisted_owner_subject(account)
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

      assert html =~ "Rejected acme-extras v1.0. It stays listed as rejected"
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

  describe "live catalog refresh" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "a pack advertised after mount appears without navigation", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _dead_html} = live(conn, ~p"/app/#{account}/packs")
      refute render(lv) =~ "acme-tools"

      _pack_version = observe_pending_pack!(account)

      # The observe broadcast reaches this page's own handler — the shell hook
      # that keeps the sidebar badge current forwards it instead of swallowing
      # it — and queues one coalesced reload. Reading the queued flag syncs on
      # that message; the timer is then fired directly (the runners-page
      # :reveal_troubleshooting precedent) instead of sleeping the debounce out.
      assert :sys.get_state(lv.pid).socket.assigns.refresh_queued?
      send(lv.pid, :refresh_packs)

      assert render(lv) =~ "acme-tools"
    end
  end

  describe "automatic cleanup" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    defp stale_pack_version!(account) do
      pack_version = observe_pending_pack!(account)
      forty_days_ago = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
      # The sweep keeps versions a connected runner still advertises — the
      # stale row's sole advertiser (observe_pending_pack!'s runner) must be
      # durably gone for it to be sweepable.
      runner = Emisar.Repo.get_by!(Emisar.Runners.Runner, account_id: account.id)
      Fixtures.Runners.mark_disconnected_at(runner, forty_days_ago)
      Fixtures.Catalog.backdate_pack_version_last_seen(pack_version, forty_days_ago)
    end

    test "an owner turns the retention window on from the select", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/packs")

      assert html =~ "Automatic cleanup"
      # Off is the default — the rail select shows it as the selected option.
      assert has_element?(lv, ~s(#packs-cleanup option[value=""][selected]))

      html =
        lv
        |> element("#packs-cleanup form")
        |> render_change(%{"days" => "30"})

      assert html =~ "Automatic cleanup on — pack versions unseen for 30 days are removed daily."
      assert has_element?(lv, ~s(#packs-cleanup option[value="30"][selected]))

      assert {:ok, settings} = Emisar.Accounts.fetch_account_settings(account.id)
      assert settings.pack_unseen_retention_days == 30
    end

    test "an owner turns the retention window back off", %{conn: conn, account: account} do
      _account =
        Fixtures.Accounts.set_account_settings(account, %{pack_unseen_retention_days: 30})

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      html =
        lv
        |> element("#packs-cleanup form")
        |> render_change(%{"days" => ""})

      assert html =~ "Automatic cleanup turned off — pack versions are kept."
      assert has_element?(lv, ~s(#packs-cleanup option[value=""][selected]))

      assert {:ok, settings} = Emisar.Accounts.fetch_account_settings(account.id)
      assert settings.pack_unseen_retention_days == nil
    end

    test "a malformed period is refused and the stored window stands", %{
      conn: conn,
      account: account
    } do
      _account =
        Fixtures.Accounts.set_account_settings(account, %{pack_unseen_retention_days: 30})

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      assert render_click(lv, "set_pack_retention", %{"days" => "soon"}) =~
               "Pick a valid cleanup period."

      assert {:ok, settings} = Emisar.Accounts.fetch_account_settings(account.id)
      assert settings.pack_unseen_retention_days == 30
    end

    test "the 1-day window is offered and reads in the singular", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      html =
        lv
        |> element("#packs-cleanup form")
        |> render_change(%{"days" => "1"})

      assert html =~ "Automatic cleanup on — pack versions unseen for 1 day are removed daily."
      assert has_element?(lv, ~s(#packs-cleanup option[value="1"][selected]))
    end

    test "Clean up now removes versions past the window", %{
      conn: conn,
      user: user,
      account: account
    } do
      _account =
        Fixtures.Accounts.set_account_settings(account, %{pack_unseen_retention_days: 30})

      _stale = stale_pack_version!(account)
      _subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")
      html = render_click(lv, "cleanup_now", %{})

      assert html =~ "Removed 1 pack version no runner has advertised recently."
      refute has_element?(lv, "#packs li", "acme-tools")
    end

    test "Clean up now with cleanup off explains the prerequisite", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

      assert render_click(lv, "cleanup_now", %{}) =~ "Turn on automatic cleanup first."
    end

    test "a viewer sees the read-only note and crafted events are denied", %{account: account} do
      _account =
        Fixtures.Accounts.set_account_settings(account, %{pack_unseen_retention_days: 30})

      stale = stale_pack_version!(account)

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/packs")

      # The schedule they can't set is still ON the page as a value, with the
      # requirement on the lock's tooltip rather than a prose tail.
      assert html =~ "After 30 days unseen"
      assert html =~ "Only owners and admins with full pack access can change this."
      refute has_element?(lv, "#packs-cleanup form")

      assert render_click(lv, "set_pack_retention", %{"days" => "7"}) =~
               "Only owners and admins with full pack access can change this setting."

      assert render_click(lv, "cleanup_now", %{}) =~ "Admin required to clean up the catalog."

      # The stale row survived both crafted attempts, and the window is untouched.
      assert Emisar.Repo.reload(stale)
      assert {:ok, settings} = Emisar.Accounts.fetch_account_settings(account.id)
      assert settings.pack_unseen_retention_days == 30
    end

    test "a pack-restricted admin cannot arm the account-wide schedule", %{account: account} do
      _account =
        Fixtures.Accounts.set_account_settings(account, %{pack_unseen_retention_days: 30})

      admin = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {:ok, restricted} =
        Emisar.Accounts.RunnerAccess.new(:all, [], [], :restricted, ["postgres"])

      Fixtures.Memberships.force_runner_access(membership, restricted)

      {:ok, lv, html} =
        build_conn() |> log_in_user(admin) |> live(~p"/app/#{account}/packs")

      assert html =~ "After 30 days unseen"
      assert html =~ "Only owners and admins with full pack access can change this."
      refute has_element?(lv, "#pack-retention-form")

      assert render_click(lv, "set_pack_retention", %{"days" => "7"}) =~
               "Only owners and admins with full pack access can change this setting."

      assert {:ok, settings} = Emisar.Accounts.fetch_account_settings(account.id)
      assert settings.pack_unseen_retention_days == 30
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
            "postgres" => %{
              "version" => "1.0",
              "hash" => Fixtures.Catalog.pack_hash("hp")
            },
            "nginx" => %{"version" => "1.0", "hash" => Fixtures.Catalog.pack_hash("hn")}
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
      assert has_element?(lv, ~s(button[aria-expanded="true"]))
    end

    test "search matches an action id and surfaces its pack, expanded", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      # The pack id "postgres" doesn't contain "postgres.activity" — the ACTION does.
      filter(lv, "postgres.activity", "")
      assert has_element?(lv, "li", "postgres.activity")
      refute has_element?(lv, "h2", "nginx")
    end

    test "search still matches a pack id (and drops non-matches)", %{conn: conn, account: account} do
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      html = filter(lv, "nginx", "")
      assert html =~ "nginx.reload"
      refute html =~ "postgres.kill_backend"
    end

    test "a combined filter one action satisfies expands the pack on that action alone", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      html = filter(lv, "kill", "high")

      assert has_element?(lv, "h2", "postgres")
      refute has_element?(lv, "h2", "nginx")
      # The disclosure auto-opens and lists only what matched — one action, not
      # the pack's other (low) one.
      assert has_element?(lv, ~s(button[aria-expanded="true"]))
      assert html =~ "postgres.kill_backend"
      assert has_element?(lv, ~s([data-role="pack-action-match-summary"]), "1 matching action")

      assert has_element?(
               lv,
               ~s([data-role="pack-action-match-summary"] + ul),
               "postgres.kill_backend"
             )

      refute has_element?(lv, ~s([data-role="pack-version-facts"]), "matching action")
    end

    test "a combined filter two DIFFERENT actions satisfy keeps the pack collapsed", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      # "activity" hits the low action, "high" hits the other one — the pack
      # stays listed, but no single action satisfies both, so there's nothing
      # specific to open.
      html = filter(lv, "activity", "high")

      assert has_element?(lv, "h2", "postgres")
      refute has_element?(lv, "h2", "nginx")
      refute has_element?(lv, ~s(button[aria-expanded="true"]))
      refute html =~ "matching action"
      refute html =~ "postgres.kill_backend"
    end

    test "clearing the filter restores every pack and re-collapses the disclosures", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/packs")

      filter(lv, "", "high")
      assert has_element?(lv, ~s(button[aria-expanded="true"]))

      html = filter(lv, "", "")

      assert has_element?(lv, "h2", "postgres")
      assert has_element?(lv, "h2", "nginx")
      refute has_element?(lv, ~s(button[aria-expanded="true"]))
      refute html =~ "postgres.kill_backend"
      assert html =~ "2 packs · 2 versions"
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

  test "a crafted event that drops its required key is a no-op, not a crash", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/packs")

    # The payload is the operator's own socket, so this is self-inflicted — but
    # a FunctionClauseError kills the view and takes any unsaved page state
    # with it, and leaves crash noise in production error tracking.
    for event <-
          ~w(trust reject revoke_trust delete_version delete_pack set_pack_retention override_retirement open_reject open_pack_action inspect_pack) do
      assert render_click(lv, event, %{})
    end

    assert Process.alive?(lv.pid)
  end

  defp drain_repo_query_count(count \\ 0) do
    receive do
      :repo_query -> drain_repo_query_count(count + 1)
    after
      0 -> count
    end
  end
end
