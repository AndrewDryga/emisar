defmodule EmisarWeb.ApprovalDetailLiveTest do
  @moduledoc """
  The approval detail page + its decision panel. Regression coverage for
  two production crashes: a KeyError where the `decision_panel` component
  read `@grant_duration` but the call site only passed `can_decide?`, and
  a FunctionClauseError where clicking Deny submitted no `reason` but the
  handler head required `%{"reason" => reason}`.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Approvals, Audit, Repo, Runs}
  alias Emisar.Catalog.PublishedRegistry
  alias Emisar.Runners.Runner

  defp subscribe_approvals(account) do
    assert Approvals.subscribe_account_approvals(account.id) == :ok
  end

  defp assert_approval_broadcast(lv, request) do
    request_id = request.id
    assert_receive {:approval_updated, ^request_id}
    render(lv)
  end

  defp pending_request(account, requested_by, opts \\ []) do
    initiating_membership = Fixtures.Memberships.fetch_membership(account.id, requested_by.id)

    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: "runner-1",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.12"
      })
      |> Repo.insert()

    # An ordinary approvable request: the runner still advertises the action, so
    # the approve gate can re-resolve its trusted contract.
    Fixtures.Catalog.create_action(runner: runner)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        reason: "needs review",
        args: %{},
        initiating_membership_id: initiating_membership.id,
        status: :pending_approval
      })

    {:ok, request} =
      Approvals.create_request(run, requested_by.id, "please approve",
        allow_self_approval: Keyword.get(opts, :allow_self_approval, true),
        min_approvals: Keyword.get(opts, :min_approvals, 1)
      )

    request
  end

  defp pending_execution_request(account, requested_by) do
    Fixtures.Approvals.create_execution_request(account, requested_by, executable?: true)
  end

  test "renders human decision evidence and states that whole-run approval happens once", %{
    conn: conn
  } do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_execution_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Database maintenance"
    assert html =~ "Frozen runbook plan"
    assert html =~ "parallel · up to 2 at once"
    assert html =~ "1 stage · 2 actions · 2 runners"
    assert html =~ "postgres.config_validate"
    assert html =~ "db-01"
    assert html =~ "validate-primary"
    assert html =~ "token"
    assert html =~ "[REDACTED]"
    assert has_element?(lv, ~s(#approval-plan-stage-apply [data-steps-marker="parallel"]))
    refute has_element?(lv, "#approval-plan-stage-apply [data-steps-marker=number]")
    assert html =~ "This execution will not ask for another approval."
    assert html =~ "Emisar stops the execution."
    assert html =~ "Approve runbook"
    refute html =~ "postgres@1.4.2/sha256:"
    refute html =~ String.duplicate("1", 64)
    refute has_element?(lv, "details", "Arguments")
    refute html =~ "Allow the LLM to reuse this approval"
    refute html =~ "Approve and send"
  end

  test "identifies a draft test before the approver decides", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    request =
      Fixtures.Approvals.create_execution_request(account, user, %{execution_kind: :draft_test})

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Draft test · Database maintenance"
    assert has_element?(lv, "a", "View draft test")
    assert has_element?(lv, "button", "Approve draft test")
    refute html =~ "Approve runbook"
  end

  test "labels a requester with this account's directory name", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    other_account = Fixtures.Accounts.create_account()

    local_membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    _local = Fixtures.Memberships.sync_display_name(local_membership, "Local Contractor")

    other_membership =
      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: user.id,
        role: "operator"
      )

    _other = Fixtures.Memberships.sync_display_name(other_membership, "Other Employee")
    request = pending_request(account, user)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Local Contractor"
    refute html =~ "Other Employee"
  end

  test "approving a runbook follows the explicit non-ActionRun result branch", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_execution_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    html =
      render_submit(lv, "decide", %{
        "decision" => "approve",
        "reason" => "change window confirmed"
      })

    assert html =~ "Runbook approved. Eligible actions are being dispatched."
    assert has_element?(lv, ~s([data-shot="approval-verdict"]), "approved")
    assert has_element?(lv, ~s([data-shot="approval-decisions"]), "change window confirmed")
    subject = Fixtures.Subjects.subject_for(user, account)
    request_id = request.id

    assert {:ok, %{^request_id => %{final: event_id}}} =
             Audit.approval_event_refs([request.id], subject)

    assert has_element?(
             lv,
             ~s(a[href="/app/#{account.slug}/audit/#{event_id}"]),
             "View audit record"
           )

    refute html =~ "Approve runbook"
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

  test "the decision surface renders the agent's snapshotted evidence/expected chain",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        reason: "restart the stuck worker",
        evidence: "run 0f9c showed the queue depth climbing for 20m",
        expected: "queue depth drops to zero within a minute",
        args: %{},
        status: :pending_approval
      })

    {:ok, request} = Approvals.create_request(run, user.id, run.reason)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Evidence"
    assert html =~ "run 0f9c showed the queue depth climbing for 20m"
    assert html =~ "Expected"
    assert html =~ "queue depth drops to zero within a minute"
  end

  test "shows the resolved command when the pinned pack hash matches ours", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    # A runner's advertisement is mutable, so it is deliberately forged here:
    # a different default and a `sensitive` flag the published pack does not
    # declare. Neither may reach the preview.
    forged_args_schema = %{
      "args" => [
        %{"name" => "module", "type" => "string", "required" => true},
        %{"name" => "frequency", "type" => "string", "default" => "forged", "sensitive" => true}
      ]
    }

    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "cloud-init.single_module",
      pack_id: "cloud-init",
      pack_hash: PublishedRegistry.get("cloud-init").content_hash,
      kind: "exec",
      args_schema: forged_args_schema
    )

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "cloud-init.single_module",
        source: "operator",
        reason: "re-run module",
        args: %{"module" => "ssh"},
        expected_pack_hash: PublishedRegistry.get("cloud-init").content_hash
      })

    {:ok, request} = Approvals.create_request(run, user.id, "please approve")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # The omitted `frequency` falls back to the PUBLISHED pack's declared
    # default — exactly what the runner will do — so the approver sees the full
    # command, not just args, and not the advertisement's version of either.
    assert html =~ "cloud-init single --name=ssh --frequency=always"
    assert html =~ "what the runner will execute"
    refute html =~ "forged"
    refute html =~ "[REDACTED]"
  end

  test "shows the resolved command from the advertised hash when no hash is pinned",
       %{conn: conn} do
    # The seeded/queued case: the run carries no pinned hash, but the runner
    # advertises the exact bytes of our published pack.
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    pack = PublishedRegistry.get("systemd-deep")

    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "systemd.unit_restart",
      pack_id: "systemd-deep",
      pack_hash: pack.content_hash,
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

  test "hides the command when the pinned hash differs from our published bytes",
       %{conn: conn} do
    # The pinned hash is authoritative: a drift must never be papered over by
    # an advertisement that names our bytes. No command; args still show.
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    pack = PublishedRegistry.get("cloud-init")

    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "cloud-init.single_module",
      pack_id: "cloud-init",
      pack_hash: pack.content_hash,
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

  test "hides the command when the runner advertises no pack hash", %{conn: conn} do
    # An older runner that names no bytes proves nothing, and a matching
    # version is not a substitute — the preview stays off rather than promise a
    # command line we cannot tie to the pack on the host.
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    pack = PublishedRegistry.get("cloud-init")

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
        expected_pack_hash: pack.content_hash
      })

    {:ok, request} = Approvals.create_request(run, user.id, "please approve")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    refute html =~ "what the runner will execute"
    assert html =~ "ssh"
  end

  test "shows exact decimals while redacting sensitive arguments", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "database.scale",
      args_schema: %{
        "args" => [
          %{"name" => "ratio", "type" => "number"},
          %{"name" => "token", "type" => "string", "sensitive" => true}
        ]
      }
    )

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "database.scale",
        source: "mcp",
        reason: "scale precisely",
        args_raw: ~s({"ratio":0.1234567890123456789,"token":"secret-value"}),
        sensitive_arg_names: ["token"]
      })

    {:ok, request} = Approvals.create_request(run, user.id, "please approve")
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "0.1234567890123456789"
    assert html =~ "[REDACTED]"
    refute html =~ "0.12345678901234568"
    refute html =~ "secret-value"
  end

  test "renders the resolved command from the redacted arguments", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    # The pack's own schema does NOT declare `module` sensitive, so only the
    # run's recorded sensitivity can keep the value out of the command line.
    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "cloud-init.single_module",
      pack_id: "cloud-init",
      pack_hash: PublishedRegistry.get("cloud-init").content_hash,
      kind: "exec",
      args_schema: %{
        "args" => [
          %{"name" => "module", "type" => "string", "required" => true},
          %{"name" => "frequency", "type" => "string", "default" => "always"}
        ]
      }
    )

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "cloud-init.single_module",
        source: "operator",
        reason: "re-run module",
        args_raw: ~s({"module":"secret-module-value"}),
        sensitive_arg_names: ["module"],
        expected_pack_hash: PublishedRegistry.get("cloud-init").content_hash
      })

    {:ok, request} = Approvals.create_request(run, user.id, "please approve")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # Shell-quoted because the placeholder carries brackets — the same quoting
    # the runner applies, so the preview still reads as the real command.
    assert html =~ "cloud-init single &#39;--name=[REDACTED]&#39; --frequency=always"
    refute html =~ "secret-module-value"
  end

  test "hides both the arguments and the command when they no longer decode", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "cloud-init.single_module",
      pack_id: "cloud-init",
      pack_hash: PublishedRegistry.get("cloud-init").content_hash,
      kind: "exec",
      args_schema: %{"args" => [%{"name" => "module", "type" => "string", "required" => true}]}
    )

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "cloud-init.single_module",
        source: "operator",
        reason: "re-run module",
        args: %{"module" => "ssh"},
        status: :pending_approval,
        expected_pack_hash: PublishedRegistry.get("cloud-init").content_hash
      })

    {:ok, request} = Approvals.create_request(run, user.id, "please approve")
    Fixtures.Runs.put_malformed_args_raw(run, ~s({"canary":"secret-value",}))

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    refute html =~ "secret-value"
    refute html =~ "canary"
    refute html =~ "what the runner will execute"
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
    Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 86_400)

    request = pending_request(account, user)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Just this call (no grant)"
    assert html =~ "Next 24 hours"
    refute html =~ "Next 30 days"
    refute html =~ "Next 90 days"
  end

  test "cap 0 replaces the reuse menu with the standing-grants-disabled note", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 0)

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

    # The no-JS first paint renders from the remaining seconds Approvals
    # projected — the page never diffs the raw timestamp itself.
    assert html =~ ~r/Expires in 2[34]h/

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

  test "the reuse disclosure stays open while the decision form is edited", %{conn: conn} do
    # Every keystroke posts `grant_form_changed`, and a re-render strips the
    # browser-set `<details open>` — the section slammed shut on the operator
    # the moment they typed a note or picked a window. The open state is
    # server-owned now, so each re-render puts `open` back.
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")
    refute html =~ ~r/<details[^>]*\bid="grant-reuse"[^>]*\bopen\b/

    opened = lv |> element("#grant-reuse > summary") |> render_click()
    assert opened =~ ~r/<details[^>]*\bid="grant-reuse"[^>]*\bopen\b/

    changed =
      lv
      |> element("form[phx-change='grant_form_changed']")
      |> render_change(%{"reason" => "Ack from the on-call DBA.", "duration" => "one_day"})

    assert changed =~ ~r/<details[^>]*\bid="grant-reuse"[^>]*\bopen\b/

    # The same click closes it again — the server flip mirrors the native
    # toggle rather than fighting it.
    closed = lv |> element("#grant-reuse > summary") |> render_click()
    refute closed =~ ~r/<details[^>]*\bid="grant-reuse"[^>]*\bopen\b/
  end

  test "adjusting the reuse window keeps the note, match, and cap already entered", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")
    form = element(lv, "form[phx-change='grant_form_changed']")

    note = "Checked with the on-call DBA; replica lag is back under 1s."

    render_change(form, %{"duration" => "one_day", "reason" => note})

    # Widening the match and then changing the duration re-renders the whole
    # panel. Every field the operator filled has to come back — these were
    # uncontrolled, so a duration tweak silently cleared the note and snapped
    # the match back to the narrow default.
    changed =
      render_change(form, %{
        "duration" => "thirty_days",
        "reason" => note,
        "scope" => "any_args",
        "max_uses" => "5"
      })

    assert changed =~ note
    assert changed =~ ~r/<option(?=[^>]*\bvalue="any_args")(?=[^>]*\bselected)[^>]*>/
    assert changed =~ ~r/<input(?=[^>]*\bname="max_uses")(?=[^>]*\bvalue="5")[^>]*>/
  end

  test "a crafted use cap is refused at the form, settling nothing", %{conn: conn} do
    # The page posts raw values; Approvals owns what they mean. A cap it can't
    # type must come back as a fixable input error — not the stale-state path,
    # which would flip the panel to history for a request nobody decided.
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    note = "Capping this while we watch replica lag."

    html =
      lv
      |> form("form[phx-submit='decide']", %{})
      |> render_submit(%{
        "decision" => "approve",
        "reason" => note,
        "duration" => "one_day",
        "scope" => "any_args",
        "max_uses" => "0"
      })

    assert html =~ "Limit to must be a whole number of uses, at least 1."
    refute html =~ "Refresh to see the request"

    # Still decidable, still holding every value the operator typed.
    assert html =~ "Approve and send"
    assert html =~ note
    assert html =~ ~r/<option(?=[^>]*\bvalue="one_day")(?=[^>]*\bselected)[^>]*>/
    assert html =~ ~r/<option(?=[^>]*\bvalue="any_args")(?=[^>]*\bselected)[^>]*>/
    assert html =~ ~r/<input(?=[^>]*\bname="max_uses")(?=[^>]*\bvalue="0")[^>]*>/

    assert %{status: :pending, decided_by_id: nil} = Repo.reload!(request)
  end

  test "a crafted reuse window is refused before any decision is recorded", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    html =
      lv
      |> form("form[phx-submit='decide']", %{})
      |> render_submit(%{"decision" => "approve", "reason" => "", "duration" => "forever"})

    assert html =~ "Pick a reuse window from the list."
    assert html =~ "Approve and send"
    assert %{status: :pending} = Repo.reload!(request)
  end

  test "a crafted match scope is refused before any decision is recorded", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    html =
      lv
      |> form("form[phx-submit='decide']", %{})
      |> render_submit(%{
        "decision" => "approve",
        "reason" => "",
        "duration" => "one_day",
        "scope" => "everything"
      })

    assert html =~ "Pick how this grant matches arguments."
    assert html =~ "Approve and send"
    assert %{status: :pending} = Repo.reload!(request)
  end

  test "editing the form clears a previous rejection's message", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    lv
    |> form("form[phx-submit='decide']", %{})
    |> render_submit(%{"decision" => "approve", "duration" => "one_day", "max_uses" => "0"})

    changed =
      lv
      |> element("form[phx-change='grant_form_changed']")
      |> render_change(%{"duration" => "one_day", "max_uses" => "2"})

    refute changed =~ "Limit to must be a whole number of uses"
  end

  test "a refused self-approval keeps the note so it can be reused on Deny", %{conn: conn} do
    # A policy that forbids self-approval refuses the requester's approve but
    # leaves the panel live (denying your own request is fine), so the
    # justification they typed must survive the refusal.
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user, allow_self_approval: false)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    note = "Rolling back the migration instead — see incident 4412."

    html =
      lv
      |> form("form[phx-submit='decide']", %{})
      |> render_submit(%{"decision" => "approve", "reason" => note})

    assert html =~ "You can&#39;t approve your own request."
    assert html =~ note
  end

  test "a self-blocked requester gets deny-only copy, no Approve affordance", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user, allow_self_approval: false)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    # The intro must not describe the Approve button (or the reuse offer)
    # the self-blocked requester never sees — only the Deny they still have.
    assert html =~ "You can&#39;t use the normal approval path on your own request."
    assert html =~ "if waiting is unsafe, use the override"
    assert html =~ "You can still deny your own request — your decision is logged."
    refute html =~ "Approve runs this action once"
    refute html =~ "Approve and send"
    refute html =~ "Allow the LLM to reuse this approval"
  end

  test "the disconnected (dead) render shows the shared loading state", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    dead = conn |> get(~p"/app/#{account}/approvals/#{request.id}") |> html_response(200)

    assert dead =~ "Loading…"
    refute dead =~ "Loading approval"
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
    subscribe_approvals(account)

    # The reason textarea is optional — an empty submit still denies (this
    # path once raised FunctionClauseError on the missing `reason`).
    html =
      lv
      |> form("form[phx-submit='decide']", %{})
      |> render_submit(%{"decision" => "deny"})

    assert html =~ "Denied."
    assert_approval_broadcast(lv, request)
  end

  test "a denied request leads with the verdict callout, no live decide panel", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")
    subscribe_approvals(account)

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
    assert_approval_broadcast(lv, request)
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

  test "a lapsed request the sweeper hasn't denied yet reads expired, never pending", %{
    conn: conn
  } do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    # Still :pending in the DB — only the expiry has lapsed. The page must
    # normalize everywhere: a "pending" status badge above an
    # "Expired — auto-denied" verdict contradicts itself.
    request
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))
    |> Repo.update!()

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Expired — auto-denied"
    refute html =~ ~r/pending/i
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

  test "revoked pack access blocks a stale denial and leaves the approval page", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")
    assert html =~ "Approve and send"

    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

    {:ok, revoked_access} =
      Accounts.RunnerAccess.new(:all, [], [], :restricted, ["postgres"])

    Fixtures.Memberships.force_runner_access(membership, revoked_access)

    lv
    |> form("form[phx-submit='decide']", %{})
    |> render_submit(%{"decision" => "deny"})

    flash = assert_redirect(lv, ~p"/app/#{account}/approvals")
    assert flash["error"] == "Approval is no longer available under your current access."
    assert Repo.reload!(request).status == :pending
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

    Fixtures.Catalog.create_action(runner: runner)

    stale = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()
    %{attestation: attestation} = Fixtures.Runs.signed_attestation(issued_at: stale)

    run =
      Fixtures.Runs.create_signed_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        args: %{},
        status: :pending_approval,
        attestation: attestation
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

  test "a request whose action is already gone offers only Deny", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)
    runner_id = Repo.reload!(request).context["runner_id"]
    Fixtures.Catalog.delete_actions_for_runner(runner_id)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Action no longer available"
    assert html =~ "linux.uptime"
    assert html =~ "re-issue the request once"
    refute html =~ "Approve and send"
    refute html =~ "Allow the LLM to reuse this approval"
    assert has_element?(lv, "button", "Deny")
  end

  test "an action deleted while the page is open maps the approve refusal into the same state",
       %{conn: conn} do
    # The race the domain gate exists for: the page mounted against a live
    # contract, the runner stopped advertising the action, and the operator
    # clicked Approve. The refusal must read as the unavailable state, not a
    # generic "didn't record", and must leave the request decidable.
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")
    assert html =~ "Approve and send"

    runner_id = Repo.reload!(request).context["runner_id"]
    Fixtures.Catalog.delete_actions_for_runner(runner_id)

    note = "Confirmed with the on-call engineer."

    html =
      lv
      |> form("form[phx-submit='decide']", %{})
      |> render_submit(%{"decision" => "approve", "reason" => note})

    assert html =~ "no longer available"
    assert html =~ "Action no longer available"
    assert html =~ note
    refute html =~ "Approve and send"
    assert has_element?(lv, "button", "Deny")
    assert Repo.reload!(request).status == :pending
    refute_receive {:cloud_to_runner, _generation, _}, 100
  end

  test "warns when the target runner is offline (queues on approve)", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    # pending_request/2 targets a freshly-registered runner that never connects,
    # so the decision panel surfaces the shared offline notice.
    request = pending_request(account, user)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Runner offline"
    assert html =~ "queues and runs once the runner reconnects"

    run = Repo.get!(Runs.ActionRun, request.run_id)

    send(lv.pid, %{
      event: "presence_diff",
      payload: %{joins: %{run.runner_id => %{metas: [%{}]}}, leaves: %{}}
    })

    refute render(lv) =~ "Runner offline"
  end

  test "a nonexistent request id redirects to the approvals list with a flash", %{conn: conn} do
    # `fetch_approval_request_by_id` returns {:error,:not_found}
    # for an unknown id; mount redirects to /approvals rather than rendering a
    # half-empty detail page.
    {conn, _user, account} = register_and_log_in(conn)

    dest = ~p"/app/#{account}/approvals"

    assert {:error, {:live_redirect, %{to: ^dest}}} =
             live(conn, ~p"/app/#{account}/approvals/#{Ecto.UUID.generate()}")
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

    assert {:error, {:live_redirect, %{to: ^dest}}} =
             live(conn, ~p"/app/#{account}/approvals/#{foreign_request.id}")
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

  test "an owner chooses the approval override from the split action and sees the exception ledger",
       %{
         conn: conn
       } do
    {conn, owner, account} = register_and_log_in(conn)
    request = pending_request(account, owner, min_approvals: 3)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    refute html =~ "Break-glass approval"
    assert html =~ "0 of 3"

    assert has_element?(
             lv,
             ~s(#approval-action-split-primary[name="decision"][value="approve"]),
             "Approve and send"
           )

    assert has_element?(
             lv,
             "#approval-action-split-menu button",
             "Override required reviews…"
           )

    assert has_element?(lv, "#override-approval-reviews", "Override required reviews?")

    assert has_element?(
             lv,
             "#override-approval-reviews button[disabled]",
             "Override and send"
           )

    lv
    |> form("#approval-override-form")
    |> render_change(%{"reason" => "Restore the production database now"})

    assert has_element?(
             lv,
             "#override-approval-reviews",
             "Restore the production database now"
           )

    assert has_element?(lv, "#override-approval-reviews", "linux.uptime")

    type_confirm_token(lv, "override-approval-reviews", "wrong")

    assert has_element?(
             lv,
             "#override-approval-reviews button[disabled]",
             "Override and send"
           )

    type_confirm_token(lv, "override-approval-reviews", "OVERRIDE")

    refute has_element?(
             lv,
             "#override-approval-reviews button[disabled]",
             "Override and send"
           )

    html = confirm_dialog(lv, "override-approval-reviews", "Override and send")

    assert html =~ "Approval override recorded. The action was released for dispatch."
    assert has_element?(lv, ~s([data-shot="approval-verdict"]), "approved")

    assert has_element?(
             lv,
             ~s([data-shot="approval-decisions"]),
             "overrode the review requirement"
           )

    assert has_element?(
             lv,
             ~s([data-shot="approval-decisions"]),
             "Restore the production database now"
           )

    assert render(lv) =~ "0 of 3"
    assert render(lv) =~ "review requirement overridden"
    refute has_element?(lv, ~s([data-shot="approval-override"]))

    subject = owner_subject(owner, account)
    request_id = request.id

    assert {:ok, %{^request_id => %{override: event_id, final: final_event_id}}} =
             Audit.approval_event_refs([request.id], subject)

    assert final_event_id == event_id

    assert has_element?(
             lv,
             ~s([data-shot="approval-decisions"] a[href="/app/#{account.slug}/audit/#{event_id}"])
           )
  end

  test "a crafted blank override reports the required reason inline", %{conn: conn} do
    {conn, owner, account} = register_and_log_in(conn)
    request = pending_request(account, owner, min_approvals: 2)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    html = render_hook(lv, "override", %{"reason" => "   "})

    assert html =~ "Explain why the required reviews cannot be completed."
    assert has_element?(lv, "#override-reason[aria-invalid=true]")

    assert has_element?(
             lv,
             ~s(#override-reason[aria-describedby="override-reason-error"])
           )

    assert has_element?(lv, "#override-reason-error[role=alert]")
    assert %Approvals.Request{status: :pending} = Repo.reload!(request)
  end

  test "an owner who already voted keeps only the focused override path", %{conn: conn} do
    {conn, owner, account} = register_and_log_in(conn)
    request = pending_request(account, owner, min_approvals: 2)
    subject = owner_subject(owner, account)

    assert {:ok, {%Approvals.Request{status: :pending}, :pending}} =
             Approvals.approve_request(request, subject, "first review")

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "You&#39;ve already recorded your decision"
    refute has_element?(lv, "#approval-decision-form")

    assert has_element?(
             lv,
             ~s([data-shot="approval-override"] button),
             "Override required reviews…"
           )

    html = render_hook(lv, "override", %{"reason" => "No second reviewer is available"})

    assert html =~ "overrode the review requirement"
    assert has_element?(lv, ~s([data-shot="approval-decisions"]), "approved")
    assert html =~ "No second reviewer is available"
  end

  test "operators cannot see or craft the override action", %{conn: conn} do
    {_owner_conn, owner, account} = register_and_log_in(conn)
    request = pending_request(account, owner, min_approvals: 2)
    operator = Fixtures.Users.create_user()

    _membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

    operator_conn = log_in_user(build_conn(), operator)
    {:ok, lv, html} = live(operator_conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "Approve and send"
    refute has_element?(lv, ~s([data-shot="approval-override"]))

    render_hook(lv, "override", %{"reason" => "crafted"})

    assert %Approvals.Request{status: :pending} = Repo.reload!(request)
  end

  test "a self-blocked owner can use the focused override on a one-review request", %{conn: conn} do
    {conn, owner, account} = register_and_log_in(conn)
    request = pending_request(account, owner, allow_self_approval: false)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert html =~ "You can&#39;t use the normal approval path on your own request"
    assert html =~ "if waiting is unsafe, use the override"

    assert has_element?(
             lv,
             ~s([data-shot="approval-override"] button),
             "Override required reviews…"
           )
  end

  test "an approved multi-approver request lists every approver in Decisions", %{conn: conn} do
    {conn, owner, account} = register_and_log_in(conn)
    owner_membership = Fixtures.Memberships.fetch_membership(account.id, owner.id)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    Fixtures.Catalog.create_action(runner: runner)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        reason: "needs review",
        args: %{},
        initiating_membership_id: owner_membership.id,
        status: :pending_approval
      })

    {:ok, request} =
      Approvals.create_request(run, owner.id, "please approve", min_approvals: 2)

    first_approver = Fixtures.Users.create_user(full_name: "Casey Approver")

    first_membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: first_approver.id,
        role: "operator"
      )

    second_approver = Fixtures.Users.create_user(full_name: "Riley Reviewer")

    second_membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: second_approver.id,
        role: "operator"
      )

    first_subject = Fixtures.Subjects.membership_subject(first_membership)
    second_subject = Fixtures.Subjects.membership_subject(second_membership)

    assert {:ok, {%Approvals.Request{status: :pending}, :pending}} =
             Approvals.approve_request(request, first_subject, "first")

    assert {:ok, {%Approvals.Request{status: :approved}, %Runs.ActionRun{status: :sent}}} =
             Approvals.approve_request(request, second_subject, "second")

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert has_element?(lv, ~s([data-shot="approval-verdict"]), "approved")

    assert has_element?(
             lv,
             ~s([data-shot="approval-decisions"]),
             "Casey Approver"
           )

    assert has_element?(lv, ~s([data-shot="approval-decisions"]), "Riley Reviewer")
    refute has_element?(lv, ~s([data-shot="approval-verdict"]), "Casey Approver")
  end

  test "an exact request broadcast re-assigns its tally + Decisions live", %{
    conn: conn
  } do
    # The detail page subscribes to the exact request topic on connect. A
    # distinct operator records the first of two votes through the real context,
    # and the open page surfaces the new tally + decider without re-mounting.
    {conn, owner, account} = register_and_log_in(conn)
    request = pending_request(account, owner)

    request
    |> Ecto.Changeset.change(min_approvals: 2)
    |> Repo.update!()

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")
    # No votes yet — the tally reads 0 of 2 and no decider is named.
    assert html =~ "0 of 2"
    refute html =~ "Casey Approver"
    subscribe_approvals(account)

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

    assert_approval_broadcast(lv, request)

    # The broadcast reaches the still-open page; it re-assigns request + decisions.
    rendered = render(lv)
    assert rendered =~ "1 of 2"
    assert rendered =~ "Casey Approver"
  end

  test "a pending single-approver request hides the tally and empty Decisions section", %{
    conn: conn
  } do
    {conn, user, account} = register_and_log_in(conn)
    request = pending_request(account, user)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    refute html =~ ~r/Approvals<\/dt>/
    refute html =~ "Decisions</h3>"
  end

  test "a completed single-approver request renders its legacy final decision in Decisions", %{
    conn: conn
  } do
    {conn, user, account} = register_and_log_in(conn)

    request =
      Fixtures.Approvals.create_request(%{
        account_id: account.id,
        status: :approved,
        decided_by_id: user.id,
        decision_reason: "Reviewed the final plan."
      })

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert has_element?(lv, ~s([data-shot="approval-verdict"]), "approved")
    assert has_element?(lv, ~s([data-shot="approval-decisions"]), user.full_name)
    assert has_element?(lv, ~s([data-shot="approval-decisions"]), "Reviewed the final plan.")
    refute has_element?(lv, ~s([data-shot="approval-verdict"]), user.full_name)
  end

  test "a soft-deleted target runner makes the approval unavailable", %{conn: conn} do
    # Approval visibility is the same fail-closed target check used by the
    # decision transaction. A runner removed after the request was created
    # cannot leave behind a decision surface for an invalid target.
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

    assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
             live(conn, ~p"/app/#{account}/approvals/#{request.id}")

    assert path == ~p"/app/#{account}/approvals"
    assert flash_message(flash, "error") == "Approval not found."
    assert Repo.reload!(request).status == :pending
  end

  test "a removed requester is labelled as a former member and still renders", %{conn: conn} do
    # the requester user is soft-deleted, so `lookup_user/1`
    # (which scopes to not_deleted) returns nil while `requested_by_id` stays set.
    # The "Requested by" field names the missing account relationship without
    # exposing an opaque UUID. A hard delete instead nilifies requested_by_id.
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
    assert html =~ "Former member"
    # Sanity: the decision panel still rendered (the owner can decide).
    assert html =~ "Decide"
  end

  defp flash_message(flash, key) when is_map(flash), do: flash[key]

  defp flash_message(flash, key) when is_binary(flash) do
    EmisarWeb.Endpoint
    |> Phoenix.LiveView.Utils.verify_flash(flash)
    |> Map.get(key)
  end
end
