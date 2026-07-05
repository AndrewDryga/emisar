defmodule EmisarWeb.AgentsLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.ApiKeys
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.Repo

  describe "GET /app/agents" do
    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/anon/settings/agents")
    end

    test "mount renders the client picker but does NOT auto-mint a key", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents")

      assert html =~ "LLM agents"
      assert html =~ "Connect an agent"

      # All client tiles are rendered.
      assert html =~ "Claude.ai"
      assert html =~ "ChatGPT"
      assert html =~ "Claude Code"
      assert html =~ "Claude Desktop"
      assert html =~ "Cursor"
      assert html =~ "Gemini CLI"
      assert html =~ "Codex CLI"

      # No key minted until a client is picked.
      assert Repo.all(ApiKey) == []
      refute html =~ "EMISAR_API_KEY"
    end

    # Before any client is picked, the panel is just the picker — no mint,
    # no snippet, no reserved dead space below the tabs.
    test "no client picked → picker only, nothing minted", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents")

      # Empty account: the connect flow IS the page (inline, no detour) —
      # and no title CTA duplicating it.
      assert html =~ "Connect an agent"
      refute html =~ ~p"/app/#{account}/settings/agents/connect"
      assert Repo.all(ApiKey) == []
    end

    test "the dedicated /connect page carries the flow; the index gets the title CTA once agents exist",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents/connect")
      assert html =~ "we only mint a key once you choose"
      assert html =~ "Connect an agent"

      # With a live key the index collapses to the list + a title-row CTA
      # into the flow (the Runners "Connect a runner" pattern).
      subject = owner_subject(user, account)

      {:ok, _raw, _key} =
        ApiKeys.create_key(%{name: "Bot"}, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents")
      assert html =~ ~p"/app/#{account}/settings/agents/connect"
      refute html =~ "we only mint a key once you choose"
    end

    test "the list has status/name filters + the custom tab opens the key-builder form",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      # The filter bar renders only once there's something to filter —
      # account-empty hides it (the pitch leads instead).
      subject = owner_subject(user, account)

      {:ok, _raw, _key} =
        ApiKeys.create_key(%{name: "Bot"}, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents")

      # Part b — the list filter bar (rendered once keys exist).
      assert html =~ "Name"
      assert html =~ "Status"

      # Part a — the custom-key form's purpose copy appears once the operator
      # opens the "custom" tab (on the CONNECT page).
      {:ok, connect_lv, _html} = live(conn, ~p"/app/#{account}/settings/agents/connect")
      custom = render_click(connect_lv, "select_client", %{"client" => "custom"})
      assert custom =~ "Create a key by hand"
    end

    test "the default status filter is the baseline — no clear-× until moved off it",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      # Default view (status=live) is the baseline, not an operator-applied filter,
      # so it doesn't raise the clear-filters link.
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/agents")
      refute has_element?(lv, "a", "Clear filters")

      # Moving Status off its default surfaces the clear link.
      {:ok, filtered, _html} = live(conn, ~p"/app/#{account}/settings/agents?status=revoked")
      assert has_element?(filtered, "a", "Clear filters")

      # Picking "All" (a blank value) is ALSO a deviation from the default
      # "live", so it reads active — the control gets the brand accent and the
      # clear link appears. (Blank ≠ inactive when the default isn't blank.)
      {:ok, all, all_html} = live(conn, "/app/#{account.slug}/settings/agents?status=")
      assert has_element?(all, "a", "Clear filters")
      assert all_html =~ "border-brand-500/60"
    end

    test "selecting Claude.ai (remote MCP) shows URL + bearer header instead of bridge snippet",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      html = lv |> render_click("select_client", %{"client" => "claude_web"})

      # Mint still happens — same flow, just remote transport.
      [auto] = Repo.all(ApiKey)
      assert auto.account_id == account.id
      assert auto.name == "Claude.ai"

      # Remote-MCP UI is shown:
      assert html =~ "/api/mcp/rpc"
      assert html =~ "Authorization: Bearer emk-"
      assert html =~ "Steps for Claude.ai"
      # The reveal reads as a new live credential, not setup copy.
      assert html =~ "New key minted"
      assert html =~ "Settings &rarr; Connectors" or html =~ "Settings → Connectors"

      # The local-bridge snippet shape is NOT shown for this client.
      refute html =~ "EMISAR_API_KEY"
      refute html =~ "/usr/local/bin/emisar-mcp"

      # The install-emisar-mcp block does not render at all for remote
      # MCP clients — it's a local-bridge-only concern.
      refute html =~ "install-mcp.sh"
      refute html =~ "Install the bridge"
    end

    test "selecting ChatGPT shows the remote MCP panel too", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      html = lv |> render_click("select_client", %{"client" => "chatgpt"})

      [auto] = Repo.all(ApiKey)
      assert auto.name == "ChatGPT"
      assert html =~ "/api/mcp/rpc"
      assert html =~ "Steps for ChatGPT"
    end

    test "selecting a client mints a key named after the client + inlines snippet", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      html = lv |> render_click("select_client", %{"client" => "claude_desktop"})

      # The mint happened.
      [auto] = Repo.all(ApiKey)
      assert auto.account_id == account.id
      assert auto.name == "Claude Desktop"
      assert ApiKey.auto_unused?(auto)

      # Snippet shows the bridge config with EMISAR_CLIENT stamped so
      # the cloud audit can attribute calls back to this client.
      assert html =~ "EMISAR_API_KEY"
      assert html =~ "EMISAR_CLIENT"
      assert html =~ "claude-desktop"
      assert html =~ "emk-"
      assert html =~ "New key minted"

      # Auto-unused — operator's list is still empty until an MCP call
      # promotes it.
      assert {:ok, [], _} = ApiKeys.list_api_keys_for_account(owner_subject(user, account))
    end

    test "an MCP call promotes the picked-key to a visible Connected LLM", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      html = lv |> render_click("select_client", %{"client" => "claude_code"})

      [_, raw] = Regex.run(~r/EMISAR_API_KEY=(emk-[A-Za-z0-9_-]+)/, html)
      [%ApiKey{} = auto] = Repo.all(ApiKey)
      assert auto.name == "Claude Code"

      promoted = ApiKeys.peek_api_key_by_secret(raw)
      assert promoted.id == auto.id
      assert is_nil(promoted.auto_generated_at)
      assert promoted.last_used_at != nil

      assert {:ok, [%ApiKey{id: id}], _} =
               ApiKeys.list_api_keys_for_account(owner_subject(user, account))

      assert id == auto.id
    end

    test "agents list shows the creator's email", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _raw, _key} =
        ApiKeys.create_key(%{name: "manual-bot"}, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents")

      assert html =~ "manual-bot"
      assert html =~ user.email
    end

    test "each agent links to its run activity, including after it's revoked", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _raw, key} =
        ApiKeys.create_key(
          %{name: "manual-bot"},
          subject
        )

      {:ok, _} = ApiKeys.revoke_api_key(key, subject)

      # Revoked keys are excluded by default now — filter them in to see one.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents?status=revoked")

      # "What did this agent do" is exactly what you want after killing a key —
      # the (revoked) row still deep-links the RUNS feed scoped to this agent's
      # key (agent activity lives on the run, not the engine-attributed audit
      # actor). Both params: source picks the Dispatched-by kind, api_key_id
      # the agent, so the runs bar lands with the pair visibly active.
      assert html =~ "View activity"
      assert html =~ "source=mcp"
      assert html =~ "api_key_id=#{key.id}"
    end

    test "revoked keys are hidden by default + an Owner filter is offered", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _raw, _live} =
        ApiKeys.create_key(
          %{name: "live-bot"},
          subject
        )

      {:ok, _raw, dead} =
        ApiKeys.create_key(
          %{name: "dead-bot"},
          subject
        )

      {:ok, _} = ApiKeys.revoke_api_key(dead, subject)

      # Default view: live only — no clutter from dead credentials.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents")
      assert html =~ "live-bot"
      refute html =~ "dead-bot"
      # The Owner filter is offered, with the creator as an option.
      assert html =~ ~s(name="owner")
      assert html =~ user.email

      # Revoked are reachable via the Status filter.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents?status=revoked")
      assert html =~ "dead-bot"
      refute html =~ "live-bot"
    end

    test "agents list shows the MCP client a key reported (clientInfo)", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _raw, key} =
        ApiKeys.create_key(
          %{name: "prod-mcp"},
          subject
        )

      {:ok, _} =
        ApiKeys.record_client_info(key, %{
          "name" => "claude-code",
          "title" => "Claude Code",
          "version" => "1.2.3"
        })

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents")

      # The reported client shows even though the key is named generically —
      # it's the actual client. The human "title" is preferred over the
      # machine "name", with the version appended.
      assert html =~ "Claude Code"
      # The client VERSION is detail material, not row meta.
      refute html =~ "Claude Code 1.2.3"
      refute html =~ "claude-code 1.2.3"
    end

    test "status badge derives from last_used_at", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      # Active: last_used 2 min ago
      {:ok, _, active} =
        ApiKeys.create_key(%{name: "ActiveBot"}, subject)

      active
      |> Ecto.Changeset.change(last_used_at: DateTime.add(DateTime.utc_now(), -120, :second))
      |> Repo.update!()

      # Idle: last_used 2 h ago
      {:ok, _, idle} =
        ApiKeys.create_key(%{name: "IdleBot"}, subject)

      idle
      |> Ecto.Changeset.change(last_used_at: DateTime.add(DateTime.utc_now(), -2 * 3600, :second))
      |> Repo.update!()

      # Never used: leave last_used_at nil
      {:ok, _, _never} =
        ApiKeys.create_key(%{name: "NeverBot"}, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/agents")

      # Status words are lowercase dot+word (one casing family console-wide).
      assert html =~ "active</span>" or html =~ "active\n"
      assert html =~ "idle"
      assert html =~ "never used"
      # Stat counters: 1 active, 1 idle, 1 never_used
      assert html =~ "ActiveBot"
      assert html =~ "IdleBot"
      assert html =~ "NeverBot"
    end

    test "custom-key form shows validation errors inline on the field, not in a flash",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      # The custom-key builder form only renders after the Custom tab is
      # picked (no quick-mint on that tab).
      lv |> render_click("select_client", %{"client" => "custom"})

      html =
        lv
        |> form("#api_key_form", %{"api_key" => %{"name" => ""}})
        |> render_submit()

      # Inline field error rendered by <.input>/<.error> under the name
      # input…
      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      # …and no flash banner dumping a humanized changeset.
      refute html =~ "Could not create key"
      # No key was persisted on the invalid submit.
      assert Repo.all(ApiKey) == []
    end

    # A custom create persists an MCP key (`kind: :mcp`), resets the form, and
    # reloads the list so the new key is visible. The one-time secret reveal is
    # covered separately below ("custom create reveals the raw secret once").
    test "custom create persists an MCP key and reloads the list", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      lv |> render_click("select_client", %{"client" => "custom"})

      html =
        lv
        |> form("#api_key_form", %{
          "api_key" => %{"name" => "my-custom-bot", "description" => "laptop bridge"}
        })
        |> render_submit()

      # The key persisted as an MCP-kind credential.
      [key] = Repo.all(ApiKey)
      assert key.name == "my-custom-bot"
      assert key.kind == :mcp
      assert is_nil(key.auto_generated_at)

      # It's a visible (non-auto) key → shows in the default live list, and the
      # form reset (the name field is blank again).
      assert html =~ "my-custom-bot"
      assert {:ok, [_], _} = ApiKeys.list_api_keys_for_account(owner_subject(user, account))
      refute html =~ ~s(value="my-custom-bot")
    end

    # a `datetime-local` expiry on the custom-create form
    # (no seconds, no zone) is stored as UTC: `parse_expires_at` appends ":00Z"
    # before parsing, so "2030-12-25 at 10:30" persists as 10:30:00 UTC. (The
    # auth-keys form has the parallel; this is the agents path.)
    test "a custom key's expires_at is parsed from datetime-local as UTC", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      lv |> render_click("select_client", %{"client" => "custom"})

      lv
      |> form("#api_key_form", %{
        "api_key" => %{"name" => "expiring-bot", "expires_at" => "2030-12-25T10:30"}
      })
      |> render_submit()

      {:ok, keys, _} = ApiKeys.list_api_keys_for_account(owner_subject(user, account))
      key = Enum.find(keys, &(&1.name == "expiring-bot"))

      # The column is :utc_datetime_usec, so the stored value carries
      # microseconds — compare on the truncated instant.
      assert DateTime.truncate(key.expires_at, :second) == ~U[2030-12-25 10:30:00Z]
    end

    # The custom tab shows the one-time `@quick_secret` reveal after a create,
    # the same as the per-client tabs: "New key minted" + the emk- secret in the
    # DOM, copyable before the operator leaves the page.
    test "custom create reveals the raw secret once", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      lv |> render_click("select_client", %{"client" => "custom"})

      html =
        lv
        |> form("#api_key_form", %{"api_key" => %{"name" => "my-custom-bot"}})
        |> render_submit()

      assert html =~ "New key minted"
      assert html =~ ~r/emk-[A-Za-z0-9_-]{10,}/
    end

    test "rotating a key from its row mints a successor and reveals the new secret",
         %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {:ok, _raw, key} =
        ApiKeys.create_key(%{name: "rotate-me"}, subject)

      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      html = render_click(lv, "rotate", %{"id" => key.id})

      assert html =~ "Key rotated"
      assert html =~ ~r/emk-[A-Za-z0-9_-]{10,}/

      # Successor minted alongside the original — both visible, neither revoked.
      {:ok, keys, _} = ApiKeys.list_api_keys_for_account(subject)
      assert length(keys) == 2
      assert Enum.all?(keys, &is_nil(&1.revoked_at))
    end

    # picking a real client mints + shows a quick_secret;
    # switching to the Custom tab clears that shown secret (one-time-secret
    # hygiene), and re-picking a real client re-enters the quick-mint clause.
    test "switching to Custom clears a previously-shown quick secret", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      # Pick a local client → quick_secret shown in its snippet. Claude Code's
      # snippet is the docker `-e EMISAR_API_KEY=emk-…` form (bare equals).
      html = lv |> render_click("select_client", %{"client" => "claude_code"})
      [_, raw] = Regex.run(~r/EMISAR_API_KEY=(emk-[A-Za-z0-9_-]+)/, html)

      # Switch to Custom → the previously-revealed secret is gone from the page.
      custom = lv |> render_click("select_client", %{"client" => "custom"})
      refute custom =~ raw

      # Re-picking a real client re-enters the quick-mint clause (a fresh secret).
      again = lv |> render_click("select_client", %{"client" => "claude_code"})
      assert again =~ ~r/EMISAR_API_KEY=emk-[A-Za-z0-9_-]+/
    end

    test "Claude Code setup offers the optional auto-permit step with the verified rule",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      html = lv |> render_click("select_client", %{"client" => "claude_code"})

      # The optional step is present, framed as safe BECAUSE emisar gates
      # server-side (auto-permit only drops the client's own prompt).
      assert html =~ "Skip the per-tool prompts"
      assert html =~ "server-side"
      # The verified Claude Code rule — wildcard over the emisar MCP server.
      assert html =~ "mcp__emisar__*"
      assert html =~ "permissions"
    end

    test "Codex setup gives an honest pointer, not an invented per-server key",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      html = lv |> render_click("select_client", %{"client" => "codex"})

      # No per-server allowlist exists for Codex — we point at its global
      # approval_policy instead of fabricating a config key.
      assert html =~ "Skip the per-tool prompts"
      assert html =~ "approval_policy"
      assert html =~ "globally, not per-server"
    end

    # the agents list is account-scoped: A's admin sees A's
    # keys and never B's, even with both present. (The foreign-slug 404 lives in
    # account_slug_authz_test; this asserts the in-account data scoping.)
    test "cross-account — A's admin sees only A's keys, never B's", %{conn: conn} do
      {conn, user, account_a} = register_and_log_in(conn)

      {:ok, _raw, _key_a} =
        ApiKeys.create_key(
          %{name: "alpha-bot"},
          owner_subject(user, account_a)
        )

      {_user_b, account_b, subject_b} = Fixtures.Subjects.owner_subject()

      {:ok, _raw, _key_b} =
        ApiKeys.create_key(
          %{name: "bravo-bot"},
          subject_b
        )

      refute account_b.id == account_a.id

      {:ok, _lv, html} = live(conn, ~p"/app/#{account_a}/settings/agents")

      assert html =~ "alpha-bot"
      refute html =~ "bravo-bot"
    end

    # quick-mint/create/revoke are manage-gated (admin+); an
    # operator who forces the `revoke` event gets the gated flash and the key is
    # NOT revoked.
    test "an operator cannot revoke — forced event gated, key untouched", %{conn: conn} do
      {_owner_conn, owner, account} = register_and_log_in(conn)

      {:ok, _raw, key} =
        ApiKeys.create_key(
          %{name: "live-bot"},
          owner_subject(owner, account)
        )

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn()
        |> log_in_user(operator)
        |> live(~p"/app/#{account}/settings/agents")

      assert render_click(lv, "revoke", %{"id" => key.id}) =~
               "You don&#39;t have permission to do that."

      assert is_nil(Repo.reload!(key).revoked_at)
    end

    # the happy path: an admin clicks Revoke (the button
    # carries a 401-warning data-confirm), the account-scoped fetch resolves the
    # key, `revoke_api_key` retires it, a "API key revoked." flash shows, and the
    # list reloads (the now-revoked key drops out of the default live view).
    test "an admin revokes a key → flash + list reloads", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      {:ok, _raw, key} =
        ApiKeys.create_key(
          %{name: "doomed-bot"},
          owner_subject(user, account)
        )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/agents")
      assert html =~ "doomed-bot"

      html = render_click(lv, "revoke", %{"id" => key.id})

      assert html =~ "API key revoked."
      # The key is retired…
      assert Repo.reload!(key).revoked_at != nil
      # …and the default (live-only) list reloaded without it.
      refute html =~ "doomed-bot"
    end

    # an operator holds
    # view_api_keys (the page renders) and issue_quick_key (quick-mint is the
    # operator's LEGIT flow) — while custom create + revoke stay manage-gated.
    test "an operator quick-mints; custom create and revoke stay gated", %{conn: conn} do
      {_owner_conn, owner, account} = register_and_log_in(conn)

      {:ok, _raw, key} =
        ApiKeys.create_key(
          %{name: "view-me-bot"},
          owner_subject(owner, account)
        )

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/settings/agents")

      # The page renders for the operator (they hold view_api_keys)…
      assert html =~ "LLM agents"
      assert html =~ "view-me-bot"
      # …but the Revoke control isn't even rendered (manage-gated in the template).
      refute html =~ "phx-click=\"revoke\""

      denial = "You don&#39;t have permission to do that."

      # quick-mint via a client tile → the operator's legit flow succeeds.
      refute render_click(lv, "select_client", %{"client" => "claude_code"}) =~ denial
      assert Enum.count(Repo.all(ApiKey)) == 2
      # custom create → still manage-gated, no third key.
      assert render_click(lv, "create", %{"api_key" => %{"name" => "sneaky"}}) =~ denial
      # revoke an existing key → still manage-gated, key untouched.
      assert render_click(lv, "revoke", %{"id" => key.id}) =~ denial

      assert Enum.count(Repo.all(ApiKey)) == 2
      assert is_nil(Repo.reload!(key).revoked_at)
    end

    # picking the "Custom" pseudo-client swaps the per-client
    # snippet for the key-builder form (selected_client="custom") and mints
    # nothing: it's a pure UI-state toggle, so the DB stays empty until the form
    # is actually submitted.
    test "the Custom tile swaps the snippet for the key-builder form, no mint", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      render_click(lv, "select_client", %{"client" => "custom"})

      # The key-builder form is now on the page (it only renders under "custom")…
      assert has_element?(lv, "#api_key_form")
      # …and selecting Custom minted no key (no quick-mint on this tab).
      assert Repo.all(ApiKey) == []
    end

    # a forged/foreign key id revoke is a quiet no-op: the
    # account-scoped `fetch_api_key_by_id` returns not-found, so nothing is
    # revoked and no error leaks the foreign key's existence.
    test "a forged/foreign key id revoke is a quiet no-op", %{conn: conn} do
      {conn, _user, account_a} = register_and_log_in(conn)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      {:ok, _raw, foreign_key} =
        ApiKeys.create_key(
          %{name: "b-bot"},
          subject_b
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account_a}/settings/agents")

      # A's admin pushes revoke for B's key id — scoped fetch misses → no-op.
      render_click(lv, "revoke", %{"id" => foreign_key.id})

      # The foreign key is untouched (never reachable from A's session).
      assert is_nil(Repo.reload!(foreign_key).revoked_at)
    end

    test "survives an account-topic broadcast it doesn't render", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _} = live(conn, ~p"/app/#{account}/settings/agents")

      # The pending-badge hooks subscribe every authenticated LV to the
      # account's approvals/packs topics and forward those broadcasts.
      # This page renders neither — it must absorb the message, not crash.
      send(lv.pid, {:approval_updated, %{id: Ecto.UUID.generate()}})

      assert render(lv) =~ "LLM agents"
    end
  end
end
