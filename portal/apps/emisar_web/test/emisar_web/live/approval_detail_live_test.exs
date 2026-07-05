defmodule EmisarWeb.ApprovalDetailLiveTest do
  @moduledoc """
  The approval detail page + its decision panel. Regression coverage for
  two production crashes: a KeyError where the `decision_panel` component
  read `@grant_duration` but the call site only passed `can_decide?`, and
  a FunctionClauseError where clicking Deny submitted no `reason` but the
  handler head required `%{"reason" => reason}`.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Approvals, Repo, Runs}
  alias Emisar.Runners.Runner
  alias EmisarWeb.PacksRegistry

  defp pending_request(account, requested_by) do
    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: "runner-1",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.12"
      })
      |> Repo.insert()

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        reason: "needs review",
        args: %{}
      })

    {:ok, request} = Approvals.create_request(run, requested_by.id, "please approve")
    request
  end

  test "a high-risk action shows its risk pill so the approver sees the stakes", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    Fixtures.Catalog.create_action(runner: runner, action_id: "linux.reboot", risk: "high")

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.reboot",
        source: "operator",
        reason: "rolling restart",
        args: %{}
      })

    {:ok, request} = Approvals.create_request(run, user.id, "please approve")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")
    # The risk is looked up from the catalog and rendered as a pill.
    assert html =~ "high"
  end

  test "shows the resolved command when the pinned pack hash matches ours", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    args_schema = %{
      "args" => [
        %{"name" => "module", "type" => "string", "required" => true},
        %{"name" => "frequency", "type" => "string", "default" => "always"}
      ]
    }

    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "cloud-init.single_module",
      pack_id: "cloud-init",
      kind: "exec",
      args_schema: args_schema
    )

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "cloud-init.single_module",
        source: "operator",
        reason: "re-run module",
        args: %{"module" => "ssh"},
        expected_pack_hash: PacksRegistry.get("cloud-init").content_hash
      })

    {:ok, request} = Approvals.create_request(run, user.id, "please approve")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # The omitted `frequency` falls back to its declared default — exactly what
    # the runner will do — so the approver sees the full command, not just args.
    assert html =~ "cloud-init single --name=ssh --frequency=always"
    assert html =~ "what the runner will execute"
  end

  test "shows the resolved command via the advertised version when no hash is pinned",
       %{conn: conn} do
    # The seeded/queued case: the run carries no pinned hash, but the runner
    # advertised the pack at a version that matches our compiled copy.
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    pack = PacksRegistry.get("systemd-deep")

    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "systemd.unit_restart",
      pack_id: "systemd-deep",
      pack_version: pack.version,
      kind: "exec",
      args_schema: %{"args" => [%{"name" => "unit", "type" => "string"}]}
    )

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "systemd.unit_restart",
        source: "operator",
        reason: "restart the api",
        args: %{"unit" => "checkout-api.service"},
        expected_pack_hash: nil
      })

    {:ok, request} = Approvals.create_request(run, user.id, "please approve")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "systemctl restart checkout-api.service"
    assert html =~ "what the runner will execute"
  end

  test "hides the command when a pinned hash differs, even if the version matches",
       %{conn: conn} do
    # A pinned hash is authoritative: a drift must never be papered over by a
    # coincidentally-matching advertised version. No command; args still show.
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    pack = PacksRegistry.get("cloud-init")

    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "cloud-init.single_module",
      pack_id: "cloud-init",
      pack_version: pack.version,
      kind: "exec",
      args_schema: %{"args" => [%{"name" => "module", "type" => "string"}]}
    )

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "cloud-init.single_module",
        source: "operator",
        reason: "re-run module",
        args: %{"module" => "ssh"},
        expected_pack_hash: "sha256:#{String.duplicate("0", 64)}"
      })

    {:ok, request} = Approvals.create_request(run, user.id, "please approve")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    refute html =~ "what the runner will execute"
    assert html =~ "ssh"
  end

  test "renders the decision panel for a decider without crashing", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # The panel renders the approve form (owner can decide) — this is the
    # exact path that raised KeyError on `@grant_duration` in production.
    assert html =~ "Decide"
    assert html =~ "Approve and send"
    # The reuse-window duration select renders its options and defaults to
    # "once" (the tracked @grant_duration), which keeps the grant fields hidden.
    assert html =~ ~s(name="duration")
    assert html =~ "Just this call (no grant)"
    assert html =~ "Next 90 days"
    assert html =~ ~r/<option(?=[^>]*\bvalue="once")(?=[^>]*\bselected)[^>]*>/
    # A held request shows when it auto-cancels so the decider can triage.
    assert html =~ "Expires"
    assert html =~ "expires"
    # Both decision buttons guard the most consequential click against a
    # double-submit.
    assert has_element?(lv, "button[phx-disable-with]", "Approve and send")
    assert has_element?(lv, "button[phx-disable-with]", "Deny")
  end

  test "the duration menu hides options above the account's grant-lifetime cap", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    # Cap standing grants at 1 day — the 30/90-day windows must not be offered.
    Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 86_400})

    request = pending_request(account, user)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Just this call (no grant)"
    assert html =~ "Next 24 hours"
    refute html =~ "Next 30 days"
    refute html =~ "Next 90 days"
  end

  test "cap 0 replaces the reuse menu with the standing-grants-disabled note", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 0})

    request = pending_request(account, user)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # No dead one-option select — the note says why the affordance is gone.
    refute html =~ "Allow the LLM to reuse this approval"
    assert html =~ "Standing grants are disabled for this account"
  end

  test "the decide panel carries a live expiry countdown that lapses server-side", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # The countdown is a JS hook seeded with the request's expiry (so it can tick)
    # and a lapse event (so it can flip the server to the terminal state at zero).
    assert html =~ ~s(phx-hook="ExpiryCountdown")
    assert html =~ ~s(data-lapsed-event="expiry_lapsed")
    assert html =~ DateTime.to_iso8601(request.expires_at)

    # Firing the lapse event re-fetches server-side; a still-future request stays in
    # the Decide panel — the server clock decides, not a (possibly skewed) client.
    lv |> element("#expiry-countdown-#{request.id}") |> render_hook("expiry_lapsed")
    assert has_element?(lv, "button", "Approve and send")
  end

  test "choosing a reuse window reveals the grant scope fields", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # Defaults to "once" (no grant) → Match / Limit-to fields hidden.
    refute html =~ "Same arguments only"

    # Pick a real duration → grant_duration threads back into the panel.
    changed =
      lv
      |> element("form[phx-change='grant_form_changed']")
      |> render_change(%{"duration" => "one_day"})

    assert changed =~ "Same arguments only"
    # The picked duration round-trips into the value-bound select (the LV
    # tracks it as @grant_duration), and the scope picker appears.
    assert changed =~ ~r/<option(?=[^>]*\bvalue="one_day")(?=[^>]*\bselected)[^>]*>/
    assert changed =~ ~s(name="scope")
  end

  test "the free-text decision controls each have an accessible name", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # The ONE decision note is placeholder-only by design, so it carries an
    # aria-label (a placeholder is not an accessible name for AT).
    assert html =~ ~s(aria-label="Decision note")

    # The max-uses input is only shown once a real grant window is picked; it
    # gets a visible eyebrow label associated by for/id.
    changed =
      lv
      |> element("form[phx-change='grant_form_changed']")
      |> render_change(%{"duration" => "one_day"})

    assert changed =~ ~s(<label for="grant_max_uses")
    assert changed =~ ~s(id="grant_max_uses")
    assert changed =~ ~s(name="max_uses")
  end

  test "denying does not crash when the form carries no reason", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # The reason textarea is optional — an empty submit still denies (this
    # path once raised FunctionClauseError on the missing `reason`).
    html =
      lv
      |> form("form[phx-submit='decide']", %{})
      |> render_submit(%{"decision" => "deny"})

    assert html =~ "Denied."
  end

  test "a denied request leads with the verdict callout, no live decide panel", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    html =
      lv
      |> form("form[phx-submit='decide']", %{"reason" => "duplicate of an earlier run"})
      |> render_submit(%{"decision" => "deny"})

    # The outcome LEADS the page (verdict callout carries the note); the live
    # decide panel is gone once the request is settled.
    assert html =~ "Denied"
    assert html =~ "duplicate of an earlier run"
    refute html =~ "Approve and send"
    assert Repo.reload!(request).decision_reason == "duplicate of an earlier run"
  end

  test "an expired request leads with the auto-denied verdict, no decide panel", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    request
    |> Ecto.Changeset.change(
      status: :expired,
      expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    )
    |> Repo.update!()

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Expired"
    assert html =~ "auto-denied"
    refute html =~ "Approve and send"
  end

  test "a decision that lost a race to expiry re-fetches and flips the panel", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")
    assert html =~ "Approve and send"

    # The request expires out from under the open page — its live broadcast
    # hasn't arrived yet, so simulate by expiring the row directly, then
    # deciding (approve and deny share the decision_failed defense).
    request
    |> Ecto.Changeset.change(
      status: :expired,
      expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    )
    |> Repo.update!()

    html =
      lv
      |> form("form[phx-submit='decide']", %{"reason" => ""})
      |> render_submit(%{"decision" => "deny"})

    assert html =~ "expired before your decision landed"
    # The form flipped to decision-history — no interactive decision left.
    refute html =~ "Approve and send"
  end

  test "approving a run whose signature aged out shows the re-issue prompt", %{conn: conn} do
    {conn, approver, account} = register_and_log_in(conn)

    {:ok, runner} =
      %{
        account_id: account.id,
        name: "signer",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.9"
      }
      |> Runner.Changeset.register()
      |> Repo.insert()

    # Enforcing runner, 1h freshness window; the parked run's signature is 2h old.
    {:ok, runner} =
      Emisar.Runners.apply_state(runner, %{
        "enforce_signatures" => true,
        "max_attestation_age_seconds" => 3600
      })

    stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        args: %{},
        status: :pending_approval,
        attestation: %{"key_id" => "k", "sig" => "x", "issued_at" => stale}
      })

    # A different requester so this is a real (non-self) approval.
    requester = Fixtures.Users.create_user()
    {:ok, request} = Approvals.create_request(run, requester.id, "please")

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    html =
      lv
      |> form("form[phx-submit='decide']", %{"reason" => "go"})
      |> render_submit(%{"decision" => "approve"})

    # The gate refuses up front with the actionable re-issue prompt, not a
    # generic "didn't record" — and the run is never finalized/dispatched.
    assert html =~ "expired before approval"
    assert html =~ "Re-issue it from your MCP client"
    assert Repo.reload!(request).status == :pending
    _ = approver
  end

  test "warns when the target runner is offline (queues on approve)", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    # pending_request/2 targets a freshly-registered runner that never connects,
    # so the decision panel surfaces the shared offline notice.
    request = pending_request(account, user)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Runner offline"
    assert html =~ "queues and runs once the runner reconnects"
  end

  test "a nonexistent request id redirects to the approvals list with a flash", %{conn: conn} do
    # `fetch_approval_request_by_id` returns {:error,:not_found}
    # for an unknown id; mount redirects to /approvals rather than rendering a
    # half-empty detail page.
    {conn, _user, account} = register_and_log_in(conn)

    dest = ~p"/app/#{account}/approvals"

    assert {:error, {:live_redirect, %{to: ^dest, flash: flash}}} =
             live(conn, ~p"/app/#{account}/approvals/#{Ecto.UUID.generate()}")

    assert flash["error"] == "Approval not found."
  end

  test "another account's request id is a 404 (redirect), not a 403", %{conn: conn} do
    # the URL carries account A's slug (the member is in A),
    # but the request id belongs to account B. `for_subject` scopes the fetch to A
    # → {:error,:not_found} → the same "Approval not found." redirect as a
    # nonexistent id (no tenant-existence leak, 404 not 403).
    {conn, _user, account} = register_and_log_in(conn)

    {_b_conn, b_user, b_account} = register_and_log_in(build_conn())
    foreign_request = pending_request(b_account, b_user)

    dest = ~p"/app/#{account}/approvals"

    assert {:error, {:live_redirect, %{to: ^dest, flash: flash}}} =
             live(conn, ~p"/app/#{account}/approvals/#{foreign_request.id}")

    assert flash["error"] == "Approval not found."
  end

  test "a multi-approver request shows the N-of-M tally and the per-vote Decisions card", %{
    conn: conn
  } do
    # (multi side) — a request needing 2 distinct approvals
    # surfaces the "Approvals" meta tally AND, once a vote is recorded, the
    # per-vote Decisions card (both gated on `min_approvals > 1`). A first
    # sub-threshold approve by a distinct operator leaves it pending with one vote.
    {conn, owner, account} = register_and_log_in(conn)
    request = pending_request(account, owner)

    request
    |> Ecto.Changeset.change(min_approvals: 2)
    |> Repo.update!()

    # A different operator records the first (of two) approvals — stays pending.
    # A distinct full_name so the Decisions card's decider label is unambiguous
    # (every fixture user is otherwise "Test User").
    approver = Fixtures.Users.create_user(full_name: "Casey Approver")

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: approver.id,
        role: "operator"
      )

    {:ok, {%Approvals.Request{status: :pending}, :pending}} =
      Approvals.approve_request(
        request,
        Fixtures.Subjects.subject_for(approver, account),
        "first"
      )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # The meta strip carries the distinct-approver tally…
    assert html =~ "1 of 2"
    # …and the Decisions card lists the recorded vote attributed to its decider.
    assert html =~ "Decisions"
    assert html =~ "Casey Approver"
  end

  test "an approval_updated broadcast for THIS request re-assigns its tally + Decisions live", %{
    conn: conn
  } do
    # the detail page subscribes to the account approval feed
    # on connect; an {:approval_updated, %{id}} for THIS request re-assigns the
    # request + its decisions in place (no reload). A distinct operator records the
    # first of two votes through the real context (which broadcasts), and the open
    # page surfaces the new "1 of 2" tally + the decider without re-mounting.
    {conn, owner, account} = register_and_log_in(conn)
    request = pending_request(account, owner)

    request
    |> Ecto.Changeset.change(min_approvals: 2)
    |> Repo.update!()

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")
    # No votes yet — the tally reads 0 of 2 and no decider is named.
    assert html =~ "0 of 2"
    refute html =~ "Casey Approver"

    approver = Fixtures.Users.create_user(full_name: "Casey Approver")

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: approver.id,
        role: "operator"
      )

    {:ok, {%Approvals.Request{status: :pending}, :pending}} =
      Approvals.approve_request(
        request,
        Fixtures.Subjects.subject_for(approver, account),
        "first"
      )

    # The broadcast reaches the still-open page; it re-assigns request + decisions.
    rendered = render(lv)
    assert rendered =~ "1 of 2"
    assert rendered =~ "Casey Approver"
  end

  test "a single-approver request hides the multi-approver tally and Decisions card", %{
    conn: conn
  } do
    # (single side) — a `min_approvals = 1` request reads no
    # differently than the plain single-approver flow: no "Approvals" tally, no
    # Decisions card (both are `min_approvals > 1` only).
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    refute html =~ ~r/Approvals<\/dt>/
    refute html =~ "Decisions</h3>"
  end

  test "a soft-deleted target runner degrades to the truncated runner-id fallback", %{conn: conn} do
    # the run preloads its runner via a LEFT join scoped to
    # `not_deleted()`, so a soft-deleted runner makes `@run.runner` nil. The meta
    # strip falls back to the request's context runner_id (truncated UUID) instead
    # of the runner name + link, and the page renders without crashing. (The same
    # fallback covers a fully-pruned run, where `@run` itself is nil — but a run
    # can't be hard-deleted while its request lives, since the request FKs the run
    # with on_delete: :delete_all.)
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    # The freshly-built struct holds context with atom keys; reload so the
    # JSONB round-trips to the string keys the page reads.
    runner_id = Repo.reload!(request).context["runner_id"]

    # Soft-delete the runner — the run stays fetchable, but its runner preload
    # comes back nil (the join excludes tombstoned rows).
    Emisar.Runners.Runner.Query.all()
    |> Emisar.Runners.Runner.Query.by_id(runner_id)
    |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # The action id still reads off the request context…
    assert html =~ "linux.uptime"
    # …and the runner falls back to the truncated id, not a name+link (no crash).
    assert html =~ String.slice(runner_id, 0, 12) <> "…"
  end

  test "a removed requester falls back to a short UUID label, still renders", %{conn: conn} do
    # the requester user is soft-deleted, so `lookup_user/1`
    # (which scopes to not_deleted) returns nil while `requested_by_id` stays set.
    # The "Requested by" field falls back to the short-UUID slice of the recorded
    # id (then em-dash), and the page still renders. (A HARD delete instead nilifies
    # requested_by_id via the FK, which is the em-dash branch — the soft-delete is
    # what exercises the short-UUID fallback this row documents.)
    {conn, _owner, account} = register_and_log_in(conn)

    # A separate requester we then soft-delete (keeping the request's requested_by_id).
    requester = Fixtures.Users.create_user()

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: Fixtures.Runners.create_runner(account_id: account.id).id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{},
        status: :pending_approval
      })

    {:ok, request} = Approvals.create_request(run, requester.id, "please approve")

    # Soft-delete the requester — the label resolver must tolerate the missing row.
    Emisar.Users.User.Query.all()
    |> Emisar.Users.User.Query.by_id(requester.id)
    |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    refute html =~ requester.email
    assert html =~ String.slice(requester.id, 0, 8) <> "…"
    # Sanity: the decision panel still rendered (the owner can decide).
    assert html =~ "Decide"
  end
end
