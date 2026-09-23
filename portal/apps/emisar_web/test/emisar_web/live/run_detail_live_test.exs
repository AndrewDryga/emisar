defmodule EmisarWeb.RunDetailLiveTest do
  @moduledoc """
  The run detail page surfaces the policy verdict that gated the run —
  the decision (allow / require_approval / deny) as a chip plus the
  reason — for every run, not just the ones waiting on approval.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Approvals, Audit, Repo, Runs}
  alias Emisar.Runs.RunEvent

  defp run_with(account, attrs) do
    runner_id =
      attrs[:runner_id] ||
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "runner-1",
          group: "default",
          hostname: "10.0.5.12",
          connected?: Map.get(attrs, :runner_connected?, true)
        ).id

    attrs = Map.delete(attrs, :runner_connected?)

    {:ok, run} =
      Runs.create_run(
        Map.merge(
          %{
            account_id: account.id,
            runner_id: runner_id,
            action_id: "linux.uptime",
            source: "mcp",
            args: %{}
          },
          attrs
        )
      )

    run
  end

  # A run the approve gate can release: the runner still advertises the action
  # and the run snapshots its trusted contract, so every recorded vote takes the
  # real decision path instead of a fixture flipping request columns without a
  # vote row — the ledger lists only votes that were actually cast.
  defp gated_run(account, requested_by, attrs \\ %{}) do
    initiating_membership = Fixtures.Memberships.fetch_membership(account.id, requested_by.id)

    runner =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "runner-1",
        group: "default",
        hostname: "10.0.5.12"
      )

    Fixtures.Catalog.create_action(runner: runner)

    run_with(
      account,
      Map.merge(
        %{
          runner_id: runner.id,
          requested_by_id: requested_by.id,
          initiating_membership_id: initiating_membership.id,
          status: :pending_approval,
          requires_approval: true,
          policy_decision: "require_approval",
          policy_reason: "High-risk config reload requires an admin approval",
          pack_ref: Fixtures.Catalog.default_pack_ref(),
          expected_pack_hash: Fixtures.Catalog.default_pack_hash()
        },
        attrs
      )
    )
  end

  # A named member who can decide — distinct full names keep each ledger row
  # attributable (every other fixture user is "Test User").
  defp reviewer(account, full_name, role \\ "admin") do
    user = Fixtures.Users.create_user(full_name: full_name)

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: role
      )

    Fixtures.Subjects.membership_subject(membership)
  end

  defp output_index(html, needle) do
    {position, _length} = :binary.match(html, needle)
    position
  end

  defp output_count(html, needle), do: length(:binary.matches(html, needle))

  test "View audit trail links the dispatch's request_id trace", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # Run events target the RUNNER, so the run's trail is its request_id trace
    # (transitions + grant use + cancel), not a target filter.
    assert html =~ "View audit trail"
    assert html =~ "Copy ID"
    assert html =~ "Created"
    assert html =~ ~s(request_id=#{run.request_id})
    refute html =~ "target_kind=action_run"
    refute html =~ "target_id=#{run.id}"
  end

  test "the Arguments panel shows exact numbers and redacts every sensitive value", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    run =
      run_with(account, %{
        args_raw: ~s({"ratio":0.1234567890123456789,"token":"secret-value"}),
        sensitive_arg_names: ["token"]
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "0.1234567890123456789"
    assert html =~ "[REDACTED]"
    refute html =~ "0.12345678901234568"
    refute html =~ "secret-value"
  end

  test "arguments that no longer decode render no panel instead of raw bytes", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{})
    Fixtures.Runs.put_malformed_args_raw(run, ~s({"canary":"secret-value",}))

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "secret-value"
    refute html =~ "canary"
  end

  test "a removed runner renders an unlinked label that keeps the full id", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id, name: "runner-1")
    run = run_with(account, %{runner_id: runner.id})
    Fixtures.Runners.mark_deleted(runner)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The runner row is gone — no live hyperlink into "Runner not found."
    refute html =~ ~p"/app/#{account}/runners/#{runner.id}"
    assert html =~ "Removed runner"
    assert html =~ ~s(title="#{runner.id}")
  end

  test "the header runner subtitle hides on phones; the Runner fact still names it", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The subtitle repeats the facts grid's Runner, so below sm it yields the
    # header width to the long mono action id instead of wrapping under it.
    assert html =~ ~s(<span class="hidden sm:inline">on runner-1</span>)
    assert output_count(html, "runner-1") >= 2
  end

  test "the policy panel explains the policy source and decision in one sentence",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    run =
      run_with(account, %{
        policy_decision: "require_approval",
        policy_reason: "The account policy requires approval for high-risk actions by default.",
        policy_version: 4
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The reason is a complete sentence because the same stored explanation is
    # also reused by approvals, email, MCP, and runbooks.
    assert html =~ "Policy"
    assert html =~ "The account policy requires approval for high-risk actions by default."
    assert html =~ ~r/·\s*v4/
  end

  test "an approved run's request details record the vote — who, when, why",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    run = gated_run(account, user)
    {:ok, request} = Approvals.create_request(run, "reload after validation")

    {:ok, _} =
      Approvals.approve_request(
        request,
        reviewer(account, "Jordan Approver"),
        "window open, config validated"
      )

    request_id = request.id

    {:ok, %{^request_id => %{final: event_id}}} =
      Audit.approval_event_refs([request_id], owner_subject(user, account))

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Approval"
    assert has_element?(lv, "#run-approval", "Approved")
    assert has_element?(lv, "#run-approval", "Jordan Approver")
    assert has_element?(lv, "#run-approval", "approved")
    assert has_element?(lv, "#run-approval", "“window open, config validated”")
    # A single approver has no quorum to count toward.
    refute html =~ "of 1 approvals"

    assert has_element?(
             lv,
             ~s(#run-approval a[href="/app/#{account.slug}/audit/#{event_id}"]),
             "View audit record"
           )
  end

  test "the first paint omits the Approval row instead of naming a former member",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    run = gated_run(account, user)
    {:ok, request} = Approvals.create_request(run, "reload after validation")

    {:ok, _} =
      Approvals.approve_request(
        request,
        reviewer(account, "Jordan Approver"),
        "window open, config validated"
      )

    static = conn |> get(~p"/app/#{account}/runs/#{run.id}") |> html_response(200)

    refute static =~ "Former member"
    refute static =~ "Jordan Approver"

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#run-approval", "Jordan Approver")
  end

  test "a User-only historical finalization keeps its time and note without a Member label",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    run = gated_run(account, user)
    {:ok, request} = Approvals.create_request(run, "reload after validation")
    jordan = reviewer(account, "Jordan Approver")

    Fixtures.Approvals.approve_request(
      request,
      jordan.actor.id,
      "validated config, deploy window open"
    )

    Fixtures.Runs.put_status(run, :sent)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "Waiting for approval"
    assert has_element?(lv, "#run-approval", "Approved")
    refute has_element?(lv, "#run-approval", "Jordan Approver")
    assert has_element?(lv, "#run-approval", "approved")
    assert has_element?(lv, "#run-approval", "“validated config, deploy window open”")
    assert has_element?(lv, "#run-approval time")
  end

  test "a multi-approver hold lists each vote with its note and the running tally",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    run = gated_run(account, user)
    {:ok, request} = Approvals.create_request(run, "needs two", min_approvals: 2)

    {:ok, {%Approvals.Request{status: :pending}, :pending}} =
      Approvals.approve_request(request, reviewer(account, "Casey Approver"), "first")

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Waiting for approval"
    assert has_element?(lv, "#run-approval", "Pending")
    assert has_element?(lv, "#run-approval", "1 of 2 approvals")
    assert has_element?(lv, "#run-approval", "Casey Approver")
    assert has_element?(lv, "#run-approval", "“first”")

    # The releasing vote lands while the page is open. It both closes the
    # request and flips the run, so either feed could repaint this one — the
    # sub-quorum test below is what pins the request subscription. The
    # broadcast is sent from this process after commit, so it is ordered ahead
    # of the render call below.
    {:ok, _} = Approvals.approve_request(request, reviewer(account, "Jordan Approver"), "second")

    assert has_element?(lv, "#run-approval", "Approved")
    assert has_element?(lv, "#run-approval", "2 of 2 approvals")
    assert has_element?(lv, "#run-approval", "Jordan Approver")
    assert has_element?(lv, "#run-approval", "“second”")
  end

  # The receipt is bounded in encoded bytes for the MCP page frame, and this
  # ledger reads the SAME projection — so a long note reaches the console
  # already cut. A clipped note inside quotation marks reads as the whole thing
  # the approver wrote, which is the one claim this ledger must not make.
  test "a note cut by the receipt's byte bound is marked, never quoted as whole",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    run = gated_run(account, user)
    {:ok, request} = Approvals.create_request(run, "reload after validation")

    # Well inside the 2000-grapheme note ceiling an approver may type, and past
    # the projection's 1000-encoded-byte bound.
    note = String.duplicate("a", 1_500) <> " and the tail the bound cuts"

    {:ok, _} = Approvals.approve_request(request, reviewer(account, "Jordan Approver"), note)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    ledger = lv |> element("#run-approval") |> render()

    assert ledger =~ String.duplicate("a", 1_000)
    refute ledger =~ "and the tail the bound cuts"
    assert has_element?(lv, "#run-approval p", "…")
  end

  # The reason the page subscribes to the request at all: a vote below quorum
  # changes the request and leaves the run untouched, so the run feed the page
  # already had cannot repaint it. Without Approvals.subscribe_request the
  # ledger would sit on its mount-time paint until something else moved the run.
  test "a vote that leaves the hold short of quorum repaints the open ledger",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    run = gated_run(account, user)
    {:ok, request} = Approvals.create_request(run, "needs three", min_approvals: 3)

    {:ok, {%Approvals.Request{status: :pending}, :pending}} =
      Approvals.approve_request(request, reviewer(account, "Casey Approver"), "first")

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#run-approval", "1 of 3 approvals")
    refute has_element?(lv, "#run-approval", "Jordan Approver")

    {:ok, {%Approvals.Request{status: :pending}, :pending}} =
      Approvals.approve_request(request, reviewer(account, "Jordan Approver"), "second")

    # The run never moved: only the request's own feed carries this vote.
    assert Repo.reload!(run).status == :pending_approval

    assert has_element?(lv, "#run-approval", "Pending")
    assert has_element?(lv, "#run-approval", "2 of 3 approvals")
    assert has_element?(lv, "#run-approval", "Jordan Approver")
    assert has_element?(lv, "#run-approval", "“second”")
  end

  test "an owner's override closes the ledger as its own receipt, never a vote",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn, %{user: %{full_name: "Maya Owner"}})
    run = gated_run(account, user)
    {:ok, request} = Approvals.create_request(run, "needs three", min_approvals: 3)

    {:ok, _} =
      Approvals.approve_request(request, reviewer(account, "Jordan Approver"), "one route")

    {:ok, {%Approvals.Request{status: :approved}, _run}} =
      Approvals.override_request(
        request,
        "Reviewers are unavailable during the incident.",
        owner_subject(user, account)
      )

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#run-approval", "Approved")
    assert has_element?(lv, "#run-approval", "1 of 3 approvals")
    assert has_element?(lv, "#run-approval", "Jordan Approver")
    assert has_element?(lv, "#run-approval", "“one route”")
    assert has_element?(lv, "#run-approval", "Maya Owner")

    assert has_element?(
             lv,
             "#run-approval",
             "overrode the review requirement · 2 approvals waived"
           )

    assert has_element?(lv, "#run-approval", "“Reviewers are unavailable during the incident.”")

    # One vote and one override: the override is neither tallied nor drawn as
    # a vote, and the page no longer names the overrider as "the approver".
    ledger = lv |> element("#run-approval") |> render()
    assert output_count(ledger, ~s(data-icon="action.approve")) == 1
    assert output_count(ledger, ~s(data-icon="state.warning")) == 1
    refute html =~ "Approved by"
  end

  test "an override whose receipt retention pruned still never reads as a vote",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn, %{user: %{full_name: "Maya Owner"}})
    run = gated_run(account, user)
    {:ok, request} = Approvals.create_request(run, "needs one")

    {:ok, {%Approvals.Request{status: :approved}, _run}} =
      Approvals.override_request(request, "Nobody else is on call.", owner_subject(user, account))

    Fixtures.Approvals.prune_override_receipt(request)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#run-approval", "Approved")
    ledger = lv |> element("#run-approval") |> render()
    assert output_count(ledger, ~s(data-icon="action.approve")) == 0
    refute ledger =~ "Maya Owner"
    refute ledger =~ "Nobody else is on call."
    refute html =~ "Approved by"
  end

  test "unknown historical finalization keeps its status without inventing an approver",
       %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn, %{user: %{full_name: "Maya Owner"}})
    run = gated_run(account, user)
    {:ok, request} = Approvals.create_request(run, "needs one")

    request
    |> Fixtures.Approvals.approve_request(user.id, "Emergency release.")
    |> Fixtures.Approvals.clear_finalization_provenance()

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#run-approval", "Approved")
    ledger = lv |> element("#run-approval") |> render()
    assert output_count(ledger, ~s(data-icon="action.approve")) == 0
    refute ledger =~ "Maya Owner"
    refute ledger =~ "Emergency release."
  end

  test "a viewer reads a completed review by its exact Member's retained local name",
       %{conn: conn} do
    {_conn, user, account} = register_and_log_in(conn)
    run = gated_run(account, user)
    {:ok, request} = Approvals.create_request(run, "needs one")
    jordan = reviewer(account, "Jordan Approver")
    {:ok, _} = Approvals.approve_request(request, jordan, "looks fine")

    viewer = Fixtures.Users.create_user(full_name: "Vic Viewer")

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    conn = log_in_user(conn, viewer)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#run-approval", "Approved")
    assert has_element?(lv, "#run-approval", "Jordan Approver")
    assert has_element?(lv, "#run-approval", "“looks fine”")

    # The label is the membership's fact, never a guess from a global profile.
    account.id
    |> Fixtures.Memberships.fetch_membership(jordan.actor.id)
    |> Fixtures.Memberships.mark_membership_as_deleted()

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute has_element?(lv, "#run-approval", "Former member")
    assert has_element?(lv, "#run-approval", "Jordan Approver")
    assert has_element?(lv, "#run-approval", "“looks fine”")
  end

  test "request details render optional evidence and expected outcome only when present",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    with_chain =
      run_with(account, %{
        reason: "restart the stuck worker",
        evidence: "run 0f9c showed the queue depth climbing for 20m",
        expected: "queue depth drops to zero within a minute"
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{with_chain.id}")

    assert html =~ "Evidence"
    assert html =~ "run 0f9c showed the queue depth climbing for 20m"
    assert html =~ "Expected outcome"
    assert html =~ "queue depth drops to zero within a minute"

    # Several facts share the cluster, so each earns its key.
    assert html =~ "Reason"

    # A reason-only run (operator dispatch carries no chain) renders neither row.
    # Reuse the runner — a second one would collide on the per-account name.
    reason_only = run_with(account, %{runner_id: with_chain.runner_id, reason: "manual restart"})
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{reason_only.id}")

    assert html =~ "manual restart"
    refute html =~ "Evidence"
    refute html =~ "Expected"

    # ...and with the reason ALONE under it, the section header "Request details" already
    # names the fact, so the REASON key would say it twice.
    assert html =~ "Request details"
    refute html =~ "Reason"
  end

  test "a denied run surfaces the denial + reason, not a bare cancellation", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    run =
      run_with(account, %{
        status: :pending_approval,
        requires_approval: true,
        requested_by_id: user.id
      })

    {:ok, request} = Emisar.Approvals.create_request(run, "deploy")

    {:ok, _} =
      Emisar.Approvals.deny_request(
        request,
        owner_subject(user, account),
        "not during the change freeze"
      )

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The run lands :cancelled, but the requester must see WHY — the denial
    # reason the approver typed (stored on the run as "approval denied: …") —
    # not a bare grey badge.
    assert html =~ "Cancelled"
    assert html =~ "approval denied: not during the change freeze"
    assert has_element?(lv, ~s(#run-cancelled [data-icon="state.cancelled"].text-amber-300))
    assert has_element?(lv, ~s(#run-cancelled [class~="bg-amber-300/40"]))
    refute has_element?(lv, "#run-cancelled .text-rose-400")

    # …and the review records who refused it and the note they logged.
    assert has_element?(lv, "#run-approval", "Denied")
    assert has_element?(lv, "#run-approval", "Test User")
    assert has_element?(lv, "#run-approval", "denied")
    assert has_element?(lv, "#run-approval", "“not during the change freeze”")
    assert has_element?(lv, ~s(#run-approval [data-icon="action.deny"]))
  end

  test "the held-run approval CTA uses the shared arrow, not a literal glyph", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    run =
      run_with(account, %{
        status: :pending_approval,
        requires_approval: true,
        requested_by_id: user.id
      })

    {:ok, _request} = Emisar.Approvals.create_request(run, "deploy")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Waiting for approval"
    assert html =~ "View approval"
    # <.cta_arrow/> — a decorative icon span, not a "→" screen readers announce.
    assert html =~ "action.next"
    refute html =~ "View approval →"
  end

  test "existing approval expiry reasons display as a sentence", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: :pending})

    {:ok, run} =
      Runs.cancel_run(run, owner_subject(user, account), "approval expired without decision")

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#run-cancelled", "Approval expired.")
    assert Repo.reload!(run).reason_text == "approval expired without decision"
  end

  test "user-written cancellation reasons keep their original case", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: :pending})
    reason = "iOS rollout paused by SRE"
    {:ok, run} = Runs.cancel_run(run, owner_subject(user, account), reason)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#run-cancelled", reason)
  end

  test "omits the policy summary when no decision was recorded", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "Requires approval"
  end

  test "an MCP run leads with the accountable human, key as via context", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    owner = Fixtures.Users.create_user(full_name: "Jordan Vale")

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: account.id,
        name: "Claude Code",
        created_by_id: owner.id
      )

    run = run_with(account, %{source: "mcp", api_key_id: key.id})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The accountable human (the key's owner) leads; the operator-named key
    # trails as "via" context.
    assert html =~ "Jordan Vale"
    assert html =~ "via Claude Code"
  end

  test "the channel is the operator-named key + the client version, not the client name",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, name: "prod-mcp")

    run =
      run_with(account, %{
        source: "mcp",
        api_key_id: key.id,
        client_info: %{"name" => "Claude Code", "version" => "1.2.3"}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The operator-named key IS the channel ("via prod-mcp"); the snapshotted
    # client version rides along — but the self-reported client NAME is not the
    # attribution channel.
    assert html =~ "via prod-mcp"
    assert html =~ "1.2.3"
    refute html =~ "Claude Code"
  end

  test "renders self-reported client metadata, labeled as not verified posture", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    run =
      run_with(account, %{
        source: "mcp",
        mcp_client_metadata: %{"asset_tag" => "LT-4417", "device_id" => "d-99"}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Client metadata"
    assert html =~ "asset_tag"
    assert html =~ "LT-4417"
    assert html =~ "device_id"
    # Explicitly self-reported, never presented as verified device posture.
    assert html =~ "not verified by emisar"
  end

  test "hides the client-metadata block for a run with none", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{source: "mcp"})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "Client metadata"
  end

  test "marks an executed command that the runner truncated", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0,
        "executed_command" => "printf [REDACTED]",
        "executed_command_truncated" => true
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Executed command"
    assert html =~ "Truncated · redacted"
  end

  test "keeps the complete executed-command annotation quiet", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0,
        "executed_command" => "uptime -p"
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Redacted"
    refute html =~ "Truncated · redacted"
  end

  test "warns when the runner could not persist its terminal audit event", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0,
        "local_audit_failed" => true
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "state.not_dispatched"
    assert html =~ "Runner audit record incomplete"
    assert rendered_text(html) =~ "Check the runner's audit storage."
  end

  test "does not show a runner audit warning for a healthy terminal result", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "Runner audit record incomplete"
    refute html =~ "Check the runner's audit storage."
  end

  # Metadata keys/values are attacker-influenced (a hostile MCP client controls
  # them), so they must render ESCAPED — never via raw/1 (IL-16).
  test "escapes attacker-influenced client metadata (no stored XSS)", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    run =
      run_with(account, %{
        source: "mcp",
        mcp_client_metadata: %{"asset_tag" => "<script>alert(1)</script>"}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
  end

  test "renders output as a single pre with chunks as inline spans (no double spacing)",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    # Progress arrives while the run is live; append rejects terminal runs.
    run = run_with(account, %{status: "running"})

    {:ok, _} =
      Runs.append_event(run, %{
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "first-line\n"}
      })

    # A non-output lifecycle event between chunks must not add a blank line.
    {:ok, _} =
      Runs.append_event(run, %{seq: 2, kind: "transition", payload: %{"to" => "running"}})

    {:ok, _} =
      Runs.append_event(run, %{
        seq: 3,
        kind: "progress",
        stream: "stderr",
        payload: %{"chunk" => "boom-error\n"}
      })

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # Terminal is one <pre>; each chunk is an inline <span> so chunks
    # concatenate and only their own newlines break lines. Stderr is
    # colored right on its span. Block wrappers / template indentation
    # here would double the spacing (the reported bug).
    assert html =~ ~r/<pre[^>]*id="run-output"/
    assert html =~ ~r/<span[^>]*>first-line/
    assert html =~ "boom-error"
    assert html =~ ~r/<span[^>]*text-rose-300[^>]*>[^<]*boom-error/
    refute html =~ ~r/<div[^>]*whitespace-pre-wrap/
    assert has_element?(lv, ~s(#run-output-copy-raw[data-copy="#run-output"]))
    refute has_element?(lv, ~s([role="group"][aria-label="Output view"]))
    refute has_element?(lv, "#run-output-copy-json")
    refute has_element?(lv, "#run-output-json-view")
  end

  # (IL-16) — runner output is attacker-influenced; a chunk
  # carrying HTML must render ESCAPED via the `event_chunk` span interpolation,
  # never `raw/1`. Asserting the literal `<script>` is absent and the escaped
  # entity is present proves no stored XSS.
  test "attacker-influenced output is HTML-escaped (no stored XSS)", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    # Progress arrives while the run is live; append rejects terminal runs.
    run = run_with(account, %{status: "running"})

    {:ok, _} =
      Runs.append_event(run, %{
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "<script>alert('xss')</script>\n"}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The raw tag never reaches the DOM…
    refute html =~ "<script>alert('xss')</script>"
    # …it's escaped (the renderer interpolates, it doesn't `raw/1`).
    assert html =~ "&lt;script&gt;"
  end

  test "typed output offers a client-side text and formatted JSON view", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    schema = %{
      "type" => "object",
      "required" => ["healthy", "message"],
      "properties" => %{
        "healthy" => %{"type" => "boolean"},
        "message" => %{"type" => "string"}
      },
      "additionalProperties" => false
    }

    run =
      run_with(account, %{
        status: "running",
        structured_output_expected: true,
        output_schema_snapshot: schema
      })

    {:ok, _} =
      Runs.append_event(run, %{
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => ~s|{"healthy":true,"message":"<script>alert(1)</script>"}\n|}
      })

    {:ok, finished} =
      Fixtures.Runs.finish(run, %{
        "status" => "success",
        "exit_code" => 0,
        "structured_output" => %{
          "healthy" => true,
          "message" => "<script>alert(1)</script>"
        }
      })

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{finished.id}")

    assert has_element?(lv, "#run-output-raw-toggle", "Text")
    assert has_element?(lv, "#run-output-json-toggle", "JSON")

    assert has_element?(lv, ~s([role="group"][aria-label="Output view"]))
    assert has_element?(lv, "#run-output-raw-toggle[aria-pressed=true]")
    assert has_element?(lv, "#run-output-json-toggle[aria-pressed=false]")
    assert has_element?(lv, "#run-output-raw-legend", "stderr highlighted")
    assert has_element?(lv, ~s(#run-output-copy-raw[data-copy="#run-output"]))
    assert has_element?(lv, ~s(#run-output-copy-json[data-copy="#run-output-json-view"].hidden))
    assert has_element?(lv, "#run-output-json-view.hidden")
    assert html =~ ~r/run-output-json-toggle.*run-output-copy-raw/s
    refute html =~ "<script>alert(1)</script>"

    document = LazyHTML.from_fragment(html)

    assert document |> LazyHTML.query_by_id("run-output") |> LazyHTML.text() =~
             ~s|{"healthy":true,"message":"<script>alert(1)</script>"}|

    assert document |> LazyHTML.query_by_id("run-output-json-view") |> LazyHTML.text() ==
             Jason.encode!(finished.structured_output, pretty: true)

    [json_click] =
      document
      |> LazyHTML.query_by_id("run-output-json-toggle")
      |> LazyHTML.attribute("phx-click")

    assert json_click =~ "run-output-raw-view"
    assert json_click =~ "run-output-json-view"
    assert json_click =~ "run-output-raw-legend"
    assert json_click =~ "run-output-copy-raw"
    assert json_click =~ "run-output-copy-json"
    assert json_click =~ "set_attr"
    refute json_click =~ ~s("push")
  end

  # the output panel renders a BOUNDED, streamed slice
  # (`phx-update="stream"`, IL-18), never an unbounded assign of every event.
  # Mount loads the most-recent @event_window (500) progress chunks in seq order
  # (`Runs.list_recent_events_for_run/3`) — the same window the live stream
  # converges to via `stream_insert(limit: -500)` — so with 501 chunks the
  # newest 500 render and the oldest falls outside the window.
  test "the output panel renders a bounded, streamed event slice (not unbounded)", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "success"})

    now = DateTime.utc_now()

    rows =
      for seq <- 1..501 do
        %{
          id: Repo.generate_id(),
          run_id: run.id,
          account_id: account.id,
          seq: seq,
          kind: :progress,
          stream: "stdout",
          payload: %{"chunk" => "chunk-#{seq}\n"},
          inserted_at: now
        }
      end

    {501, _} = Repo.insert_all(RunEvent, rows)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The output is a streamed <pre> (bounded), not a plain assign of all rows.
    assert has_element?(lv, "pre#run-output[phx-update=\"stream\"]")

    # The most-recent 500 render (seq 2..501); the oldest is outside the window.
    assert html =~ "chunk-2\n"
    assert html =~ "chunk-501\n"
    refute html =~ "chunk-1\n"
  end

  test "a terminal run pages its earlier trimmed output back in on demand", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "success"})
    now = DateTime.utc_now()

    rows =
      for seq <- 1..501 do
        %{
          id: Repo.generate_id(),
          run_id: run.id,
          account_id: account.id,
          seq: seq,
          kind: :progress,
          stream: "stdout",
          payload: %{"chunk" => "chunk-#{seq}\n"},
          inserted_at: now
        }
      end

    {501, _} = Repo.insert_all(RunEvent, rows)
    Fixtures.Runs.charge_progress_budget(run, events: 501)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The window trims the oldest chunk and offers to page it back in.
    assert html =~ "chunk-501\n"
    refute html =~ "chunk-1\n"
    assert html =~ "Load earlier output"

    # Clicking pages the trimmed head (chunk-1) into the viewer.
    html = lv |> element("button", "Load earlier output") |> render_click()
    assert html =~ "chunk-1\n"
  end

  test "load earlier pages back through multiple windows in order", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "success"})
    now = DateTime.utc_now()

    rows =
      for seq <- 1..1200 do
        %{
          id: Repo.generate_id(),
          run_id: run.id,
          account_id: account.id,
          seq: seq,
          kind: :progress,
          stream: "stdout",
          payload: %{"chunk" => "chunk-#{seq}\n"},
          inserted_at: now
        }
      end

    {1200, _} = Repo.insert_all(RunEvent, rows)
    Fixtures.Runs.charge_progress_budget(run, events: 1200)

    # The window shows the newest 500 (seq 701..1200).
    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")
    assert html =~ "chunk-701\n"
    refute html =~ "chunk-201\n"

    html = lv |> element("button", "Load earlier output") |> render_click()
    assert html =~ "chunk-201\n"
    refute html =~ "chunk-1\n"

    html = lv |> element("button", "Load earlier output") |> render_click()
    assert html =~ "chunk-1\n"

    # Chronological across all three windows, and nothing loaded twice.
    assert output_index(html, "chunk-1\n") < output_index(html, "chunk-701\n")
    assert output_index(html, "chunk-701\n") < output_index(html, "chunk-1200\n")
    assert output_count(html, "chunk-701\n") == 1
    assert output_count(html, "chunk-201\n") == 1
  end

  test "a running run shows the trim note, not a load-earlier control", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running"})

    {:ok, _} =
      Runs.append_event(run, %{
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "hi\n"}
      })

    Fixtures.Runs.charge_progress_budget(run, events: 600)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "earlier output hidden"
    refute html =~ "Load earlier output"
  end

  # A live-appending stream never evicts on its own, so a chatty run would grow
  # the viewer's DOM one node per chunk without bound. stream_insert's :limit
  # caps the client at the most-recent 500 events: the newest chunk renders, one
  # well past the 500-event window (evicted as newer chunks arrive) does not.
  test "the live event stream is client-bounded (a chatty run can't grow the DOM without bound)",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running"})

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    for seq <- 1..600 do
      event = %RunEvent{
        id: Repo.generate_id(),
        run_id: run.id,
        account_id: account.id,
        seq: seq,
        kind: :progress,
        stream: "stdout",
        payload: %{"chunk" => "chunk-#{seq}\n"}
      }

      send(lv.pid, {:run_event, event})
    end

    html = render(lv)

    # The last 500 (seq 101..600) are retained; seq 50 was evicted.
    assert html =~ "chunk-600\n"
    refute html =~ "chunk-50\n"
  end

  test "an unknown run id bounces to the runs index", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    dest = ~p"/app/#{account}/runs"

    assert {:error, {:live_redirect, %{to: ^dest, flash: flash}}} =
             live(conn, ~p"/app/#{account}/runs/#{Ecto.UUID.generate()}")

    assert flash["error"] == "Run not found."
  end

  test "a cross-account run reads as not-found", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    foreign_account = Fixtures.Accounts.create_account()
    foreign_run = run_with(foreign_account, %{})

    dest = ~p"/app/#{account}/runs"

    assert {:error, {:live_redirect, %{to: ^dest}}} =
             live(conn, ~p"/app/#{account}/runs/#{foreign_run.id}")
  end

  test "cancel sends the cancellation and confirms", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    html = render_click(lv, "cancel", %{})
    assert html =~ "Cancellation requested. Waiting for the runner to stop."
    assert html =~ "Cancellation requested"
    assert Repo.reload!(run).status == :cancelling
  end

  test "scope loss keeps run output and disables cancellation, including an already-open confirmation",
       %{
         conn: conn
       } do
    {conn, user, account} = register_and_log_in(conn)
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    membership = Fixtures.Memberships.force_role(membership, "admin")
    run = run_with(account, %{status: "running"})

    assert {:ok, _event} =
             Runs.append_event(run, %{
               seq: 1,
               kind: "progress",
               stream: "stdout",
               payload: %{"chunk" => "Output remains readable"}
             })

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")
    assert has_element?(lv, "#cancel-run-confirm:not([disabled])")
    output_state = :sys.get_state(lv.pid).socket.assigns.output_state

    Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.none())
    send(lv.pid, {:list_changed, :team, "membership.runner_access_changed", membership.id})
    assert render(lv) =~ "Cancelling requires action access"
    assert render(lv) =~ "Output remains readable"
    assert has_element?(lv, "#cancel-run-confirm[disabled]")
    assert :sys.get_state(lv.pid).socket.assigns.output_state == output_state
    assert :sys.get_state(lv.pid).socket.assigns.run.id == run.id
    render_click(lv, "cancel", %{})
    assert Repo.reload!(run).status == :running

    Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.all())
    send(lv.pid, {:list_changed, :team, "membership.runner_access_changed", membership.id})
    render(lv)
    assert has_element?(lv, "#cancel-run-confirm:not([disabled])")
  end

  test "an approval hold can be cancelled before it reaches the runner", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: :pending_approval, requested_by_id: user.id})
    {:ok, request} = Approvals.create_request(run, "please review")

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#cancel-run", "Cancel run")
    assert html =~ "Cancel this run?"
    refute html =~ "Withdraw request"
    refute html =~ "Changes already made won't be undone."

    html = render_click(lv, "cancel", %{})

    assert html =~ "Run cancelled."

    assert %Emisar.Runs.ActionRun{status: :cancelled, reason_text: "operator cancelled"} =
             Repo.reload!(run)

    assert %Emisar.Approvals.Request{status: :cancelled} = Repo.reload!(request)

    # Settle the post-commit run/approval broadcasts before the sandbox owner exits.
    render(lv)
  end

  test "a stale held-run page reports a current in-flight cancellation truthfully", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: :pending_approval, requested_by_id: user.id})
    {:ok, request} = Approvals.create_request(run, "please review")

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    Fixtures.Approvals.approve_request(request, user.id)
    Fixtures.Runs.put_status(run, :sent)

    html = render_click(lv, "cancel", %{})

    assert html =~ "Cancellation requested. Waiting for the runner to stop."

    assert %Emisar.Runs.ActionRun{status: :cancelling, reason_text: "operator cancelled"} =
             Repo.reload!(run)

    assert %Emisar.Approvals.Request{status: :approved} = Repo.reload!(request)
    render(lv)
  end

  # when cancel_run returns a non-:ok (here the run row
  # vanished between render and the cancel click), the handler gives a recovery
  # message instead of crashing.
  test "a cancel that fails asks the operator to refresh its status", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "pending"})

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The run is deleted out from under the page; cancel's locked re-read then
    # finds no row → {:error, :not_found} → the failure flash.
    Repo.delete!(run)

    html = render_click(lv, "cancel", %{})
    assert html =~ "Couldn&#39;t cancel the run. Refresh the page to check its status."
  end

  test "a viewer cannot cancel", %{conn: conn} do
    {_owner_conn, _owner, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    {:ok, lv, _html} =
      build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/runs/#{run.id}")

    refute has_element?(lv, "#cancel-run")

    html = render_click(lv, "cancel", %{})
    assert html =~ "You don&#39;t have permission to do that."
    assert Repo.reload!(run).status == :sent
  end

  test "a run_event broadcast streams into the live terminal", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running"})

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")
    refute html =~ "late-chunk"

    {:ok, event} =
      Runs.append_event(run, %{
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "late-chunk\n"}
      })

    send(lv.pid, {:run_event, event})
    assert render(lv) =~ "late-chunk"
  end

  test "an errored run that produced no output hides the empty terminal", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "error",
        "error" => "runner disconnected, result never arrived"
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "runner disconnected, result never arrived"
    refute html =~ "Output"
  end

  test "an errored run that DID produce output keeps the panel", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running"})

    {:ok, _} =
      Runs.append_event(run, %{
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "partial-line\n"}
      })

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "error",
        "error" => "boom"
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Output"
    assert html =~ "partial-line"
  end

  test "a run_updated broadcast refreshes the status chip", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    {:ok, updated} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0
      })

    send(lv.pid, {:run_updated, updated})

    assert render(lv) =~ "success"
  end

  test "a refused run surfaces the reason and hides the (never-produced) output panel", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "signature_invalid",
        "reason" => "bad_signature",
        "error" => "refused: signature does not match the dispatched action"
      })

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The distinct terminal state + the human refusal reason both show…
    assert html =~ "refused"
    assert html =~ "refused: signature does not match the dispatched action"
    # …titled and toned as the same rose refusal the status badge and audit use.
    assert has_element?(lv, "#run-failure-cause", "Refused")
    assert html =~ "bg-rose-400/40"
    refute html =~ "bg-amber-300/40"
    # …and there's no empty terminal panel (a refused run produced no output).
    refute html =~ "Output"
  end

  test "a failed run's cause panel is titled by its status, never 'Error'", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "failed",
        "exit_code" => 1,
        "error" => "process exited with code 1"
      })

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#run-failure-cause", "Failed")
    assert html =~ "process exited with code 1"
    assert html =~ "bg-rose-400/40"
    refute has_element?(lv, "#run-failure-cause", "Error")
  end

  test "an error run's cause panel keeps the 'Error' title (the system-side status)", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "error",
        "error" => "runner disconnected, result never arrived"
      })

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert has_element?(lv, "#run-failure-cause", "Error")
    assert html =~ "bg-rose-400/40"
  end

  test "the cancel button renders for an in-flight run (status compared as an atom)", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # Regression: the button's `status in [...]` guard compared the Ecto.Enum
    # atom against strings, so it never rendered.
    assert html =~ "Cancel run"
  end

  test "a terminal run has no cancellation control", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "success"})

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute has_element?(lv, "#cancel-run")
  end

  test "a stale cancellation reports an already finished run", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running"})

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    Fixtures.Runs.finish_without_runbook_callback(run, :success, %{})

    assert render_click(lv, "cancel", %{}) =~ "This run has already finished."
    assert Repo.reload!(run).status == :success
  end

  test "an in-flight run whose runner is offline shows the disconnected banner", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running", runner_connected?: false})

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Runner offline"

    send(lv.pid, %{
      event: "presence_diff",
      payload: %{joins: %{run.runner_id => %{metas: [%{}]}}, leaves: %{}}
    })

    refute render(lv) =~ "Runner offline"
  end

  test "a queued run whose runner is offline explains why it's stuck", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "pending", runner_connected?: false})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Queued — runner offline"
    # The in-flight banner's copy would be wrong for a run that hasn't dispatched.
    refute html =~ "output may be incomplete"
  end

  test "an in-flight run on a connected runner shows no disconnect banner", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
    run = run_with(account, %{status: "running", runner_id: runner.id})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "Runner offline"
  end

  test "shows a streaming pill while in flight, gone once terminal", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running"})

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")
    assert html =~ "Streaming"

    {:ok, finished} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0
      })

    send(lv.pid, {:run_updated, finished})
    refute render(lv) =~ "Streaming"
  end

  test "the pre-connect render says it is loading, never that no output was captured", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{})

    {:ok, finished} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0
      })

    Repo.insert!(%RunEvent{
      id: Repo.generate_id(),
      account_id: account.id,
      run_id: finished.id,
      seq: 1,
      kind: :progress,
      stream: "stdout",
      payload: %{"chunk" => "up 3 days"}
    })

    # The dead render defers the output read behind connected?/1 (IL-18), so it
    # has no answer yet — "No text output was recorded." would be a claim about a
    # run that in fact produced output.
    dead = html_response(get(conn, ~p"/app/#{account}/runs/#{finished.id}"), 200)

    refute dead =~ "No text output was recorded."
    assert dead =~ "Loading…"

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{finished.id}")

    assert html =~ "up 3 days"
    refute html =~ "No text output was recorded."
  end

  test "a terminal run that really captured nothing still says so", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{})

    {:ok, finished} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{finished.id}")

    assert html =~ "No text output was recorded."
  end

  defp rendered_text(html) do
    html |> LazyHTML.from_document() |> LazyHTML.text() |> String.replace(~r/\s+/, " ")
  end
end
