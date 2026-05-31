defmodule Emisar.ApprovalsTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Approvals, Audit, Repo, Runs}
  alias Emisar.Approvals.{Grant, Request}
  alias Emisar.Runs.ActionRun

  defp run_fixture(opts \\ []) do
    account =
      Keyword.get(opts, :account) || account_fixture()

    runner = Keyword.get(opts, :runner) || runner_fixture(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{}
      })

    {account, run}
  end

  defp operator_subject(account) do
    operator = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "owner")
    subject_for(operator, account, role: :owner)
  end

  describe "create_request/3" do
    test "creates an approval request in :pending status" do
      {_account, run} = run_fixture()
      operator = user_fixture()

      assert {:ok, %Request{status: "pending", run_id: run_id}} =
               Approvals.create_request(run, operator.id, "high-risk action")

      assert run_id == run.id
    end
  end

  describe "approve_request/3" do
    test "transitions the run to :sent + writes an audit event" do
      {account, run} = run_fixture()
      subject = operator_subject(account)
      {:ok, req} = Approvals.create_request(run, subject.actor.id, "needs approve")

      assert {:ok, {%Request{status: "approved"}, %ActionRun{status: "sent"}}} =
               Approvals.approve_request(req, subject, "lgtm")

      assert Enum.any?(
               Audit.list_events(Emisar.Auth.Subject.system(account), page: [limit: 50]) |> elem(1),
               &(&1.event_type == "approval.approved")
             )
    end
  end

  describe "deny_request/3" do
    test "transitions the run to :cancelled + writes an audit event" do
      {account, run} = run_fixture()
      subject = operator_subject(account)
      {:ok, req} = Approvals.create_request(run, subject.actor.id, "needs approve")

      assert {:ok, {%Request{status: "denied"}, %ActionRun{status: "cancelled"}}} =
               Approvals.deny_request(req, subject, "not now")

      assert Enum.any?(
               Audit.list_events(Emisar.Auth.Subject.system(account), page: [limit: 50]) |> elem(1),
               &(&1.event_type == "approval.denied")
             )
    end
  end

  describe "list_pending_approval_requests/1" do
    test "only returns pending requests" do
      {account, run1} = run_fixture()
      {_, run2} = run_fixture(account: account)
      subject = operator_subject(account)

      {:ok, req_pending} = Approvals.create_request(run1, user_fixture().id, nil)
      {:ok, req_to_deny} = Approvals.create_request(run2, user_fixture().id, nil)
      {:ok, _} = Approvals.deny_request(req_to_deny, subject, "nope")

      {:ok, pending, _} = Approvals.list_pending_approval_requests(subject)
      ids = pending |> Enum.map(& &1.id)
      assert ids == [req_pending.id]
    end
  end

  # -- Grants ---------------------------------------------------------

  defp insert_grant(account, key, opts) do
    Grant.Changeset.create(
      Map.merge(
        %{
          account_id: account.id,
          api_key_id: key.id,
          action_id: "linux.uptime",
          granted_by_id: opts[:granted_by_id] || user_fixture().id,
          granted_at: DateTime.utc_now()
        },
        Map.new(opts)
      )
    )
    |> Repo.insert!()
  end

  describe "peek_matching_grant/4" do
    test "returns nil when no grant exists" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)

      assert Approvals.peek_matching_grant(key.id, "x.y", runner.id, "sha") == nil
    end

    test "wildcards: nil runner_id and nil args_sha256 match anything" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner_a = runner_fixture(account_id: account.id)
      runner_b = runner_fixture(account_id: account.id)

      _ = insert_grant(account, key, action_id: "linux.uptime", granted_by_id: user.id)

      assert %Grant{} = Approvals.peek_matching_grant(key.id, "linux.uptime", runner_a.id, "sha-a")
      assert %Grant{} = Approvals.peek_matching_grant(key.id, "linux.uptime", runner_b.id, "sha-b")
    end

    test "exact runner match: grant on runner_a doesn't match runner_b" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner_a = runner_fixture(account_id: account.id)
      runner_b = runner_fixture(account_id: account.id)

      _ = insert_grant(account, key, action_id: "x", runner_id: runner_a.id, granted_by_id: user.id)

      assert %Grant{} = Approvals.peek_matching_grant(key.id, "x", runner_a.id, "any")
      assert Approvals.peek_matching_grant(key.id, "x", runner_b.id, "any") == nil
    end

    test "expired grant is filtered out" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      _ =
        insert_grant(account, key,
          action_id: "x",
          runner_id: runner.id,
          granted_by_id: user.id,
          granted_at: past,
          expires_at: past
        )

      assert Approvals.peek_matching_grant(key.id, "x", runner.id, "sha") == nil
    end

    test "revoked grant is filtered out" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)

      g = insert_grant(account, key, action_id: "x", granted_by_id: user.id)
      {:ok, _} = Approvals.revoke_grant(g, subject)

      assert Approvals.peek_matching_grant(key.id, "x", nil, "sha") == nil
    end

    test "a different API key's grant doesn't leak" do
      account = account_fixture()
      user = user_fixture()
      {_, key_a} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      {_, key_b} = api_key_fixture(account_id: account.id, created_by_id: user.id)

      _ = insert_grant(account, key_a, action_id: "x", granted_by_id: user.id)

      assert %Grant{} = Approvals.peek_matching_grant(key_a.id, "x", nil, "sha")
      assert Approvals.peek_matching_grant(key_b.id, "x", nil, "sha") == nil
    end
  end

  describe "use_grant/1" do
    test "single-use grant is exhausted after one use" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      g = insert_grant(account, key, action_id: "x", max_uses: 1, granted_by_id: user.id)

      assert :ok = Approvals.use_grant(g)
      reloaded = Repo.reload!(g)
      assert reloaded.uses_count == 1
      assert reloaded.last_used_at != nil

      assert {:error, :exhausted} = Approvals.use_grant(reloaded)
    end

    test "unlimited grant keeps incrementing" do
      account = account_fixture()
      user = user_fixture()
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      g = insert_grant(account, key, action_id: "x", granted_by_id: user.id)

      assert :ok = Approvals.use_grant(g)
      assert :ok = Approvals.use_grant(Repo.reload!(g))
      assert :ok = Approvals.use_grant(Repo.reload!(g))

      assert Repo.reload!(g).uses_count == 3
    end
  end

  describe "approve_request/4 with grant duration" do
    test ":once duration creates no grant" do
      {account, run} = run_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)

      {:ok, _} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: run.runner_id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc"
        })

      {:ok, req} = Approvals.create_request(run, user.id, "x")
      {:ok, _} = Approvals.approve_request(req, subject, "ok", duration: :once)

      assert {:ok, [], _} = Approvals.list_grants_for_api_key(key.id)
    end

    test ":one_day creates a grant with expires_at ~24h from now" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123"
        })

      {:ok, req} = Approvals.create_request(run, user.id, "x")
      {:ok, _} = Approvals.approve_request(req, subject, nil, duration: :one_day, scope: :exact_args)

      {:ok, [g], _} = Approvals.list_grants_for_api_key(key.id)
      assert g.action_id == "linux.uptime"
      assert g.args_sha256 == "abc123"
      assert g.expires_at != nil
      assert DateTime.diff(g.expires_at, DateTime.utc_now(), :hour) in 23..24
    end

    test ":any_args scope drops args_sha256 so any args match" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "mcp",
          api_key_id: key.id,
          args: %{},
          args_sha256: "abc123"
        })

      {:ok, req} = Approvals.create_request(run, user.id, "x")
      {:ok, _} = Approvals.approve_request(req, subject, nil, duration: :indefinite, scope: :any_args)

      {:ok, [g], _} = Approvals.list_grants_for_api_key(key.id)
      assert g.args_sha256 == nil
      assert g.expires_at == nil
    end
  end

  describe "expire_overdue_requests/1" do
    test "transitions pending requests past expires_at to expired + cancels the run" do
      {account, run} = run_fixture()
      user = user_fixture()
      {:ok, req} = Approvals.create_request(run, user.id, "x")

      # Move the request's expiry into the past.
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)
      {1, _} =
        Request.Query.all()
        |> Request.Query.by_id(req.id)
        |> Repo.update_all(set: [expires_at: past])

      assert Approvals.expire_overdue_requests() == 1

      expired = Request.Query.all() |> Request.Query.by_id(req.id) |> Repo.fetch!(Request.Query)
      assert expired.status == "expired"
      assert expired.decided_at != nil
      assert expired.decision_reason =~ "expired"

      reloaded_run =
        Emisar.Runs.ActionRun.Query.all()
        |> Emisar.Runs.ActionRun.Query.by_id(run.id)
        |> Repo.fetch!(Emisar.Runs.ActionRun.Query)

      assert reloaded_run.status == "cancelled"

      assert Enum.any?(
               Emisar.Audit.list_events(Emisar.Auth.Subject.system(account), page: [limit: 50]) |> elem(1),
               &(&1.event_type == "approval.expired" and &1.subject_id == req.id)
             )
    end

    test "is idempotent — second sweep is a no-op" do
      {_account, run} = run_fixture()
      user = user_fixture()
      {:ok, req} = Approvals.create_request(run, user.id, "x")
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)

      Request.Query.all()
      |> Request.Query.by_id(req.id)
      |> Repo.update_all(set: [expires_at: past])

      assert Approvals.expire_overdue_requests() == 1
      assert Approvals.expire_overdue_requests() == 0
    end

    test "leaves pending requests within the window alone" do
      {_account, run} = run_fixture()
      user = user_fixture()
      {:ok, req} = Approvals.create_request(run, user.id, "x")
      # default 24h is in the future
      assert Approvals.expire_overdue_requests() == 0
      assert (Request.Query.all()
              |> Request.Query.by_id(req.id)
              |> Repo.fetch!(Request.Query)).status == "pending"
    end
  end

  describe "create_request/3 expiry default" do
    test "sets expires_at 24h from now by default" do
      {_account, run} = run_fixture()
      user = user_fixture()
      {:ok, req} = Approvals.create_request(run, user.id, "x")

      assert req.expires_at != nil
      assert DateTime.diff(req.expires_at, DateTime.utc_now(), :hour) in 23..24
    end
  end

  describe "Runs.dispatch_run fast-path with grant" do
    test "matching grant bypasses approval and runs immediately" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "high")

      _ =
        policy_fixture(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "require_approval",
              "critical" => "deny"
            },
            "overrides" => []
          }
        )

      Emisar.PubSub.subscribe_runner(runner.id)

      attrs = %{
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "first call",
        source: "mcp",
        api_key_id: key.id
      }

      assert {:ok, :pending_approval, run1} = Runs.dispatch_run(attrs, Emisar.Auth.Subject.system(account))
      req =
        Request.Query.all() |> Request.Query.by_run_id(run1.id) |> Repo.fetch!(Request.Query)

      {:ok, _} = Approvals.approve_request(req, subject, nil, duration: :one_day, scope: :any_args)
      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500

      assert {:ok, :running, run2} = Runs.dispatch_run(attrs, Emisar.Auth.Subject.system(account))
      assert run2.id != run1.id
      refute Request.Query.all() |> Request.Query.by_run_id(run2.id) |> Repo.peek()
      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500

      {:ok, [g], _} = Approvals.list_grants_for_api_key(key.id)
      assert g.uses_count == 1
    end

    test ":once approval doesn't create a reusable grant" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {_, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "high")

      _ =
        policy_fixture(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "require_approval",
              "critical" => "deny"
            },
            "overrides" => []
          }
        )

      Emisar.PubSub.subscribe_runner(runner.id)

      attrs = %{
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "x",
        source: "mcp",
        api_key_id: key.id
      }

      {:ok, :pending_approval, run1} = Runs.dispatch_run(attrs, Emisar.Auth.Subject.system(account))
      req =
        Request.Query.all() |> Request.Query.by_run_id(run1.id) |> Repo.fetch!(Request.Query)
      {:ok, _} = Approvals.approve_request(req, subject, nil, duration: :once)

      assert {:ok, :pending_approval, _run2} = Runs.dispatch_run(attrs, Emisar.Auth.Subject.system(account))
    end
  end
end
