defmodule Emisar.Analytics.EventsTest do
  # async: false — flips the global `:mixpanel_enabled` app env.
  use ExUnit.Case, async: false

  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.Analytics.Events
  alias Emisar.Approvals.Request
  alias Emisar.Auth.Subject
  alias Emisar.Billing.Subscription
  alias Emisar.Catalog.PackVersion
  alias Emisar.Policies.Policy
  alias Emisar.Runbooks.Runbook
  alias Emisar.Runners.Runner
  alias Emisar.Runs.ActionRun
  alias Emisar.Users.User

  setup do
    Application.put_env(:emisar, :mixpanel_enabled, true)
    Application.put_env(:emisar, :analytics_test_pid, self())

    on_exit(fn ->
      Application.put_env(:emisar, :mixpanel_enabled, false)
      Application.delete_env(:emisar, :analytics_test_pid)
    end)

    :ok
  end

  describe "action_dispatched/1" do
    test "operator run attributes to the requesting user" do
      run = %ActionRun{
        action_id: "linux_uptime",
        runner_id: "rnr-1",
        source: :operator,
        requires_approval: false,
        account_id: "acc-1",
        requested_by_id: "usr-9"
      }

      Events.action_dispatched(run)

      assert_receive {:mixpanel_track, [%{"event" => "action_dispatched", "properties" => props}]}
      assert props["distinct_id"] == "usr-9"
      assert props["action_id"] == "linux_uptime"
      assert props["runner_id"] == "rnr-1"
      assert props["source"] == "operator"
      assert props["requires_approval"] == false
      assert props["account_id"] == "acc-1"
    end

    test "agent (MCP) run with no user attributes to the account" do
      run = %ActionRun{action_id: "x", source: :mcp, account_id: "acc-2", requested_by_id: nil}

      Events.action_dispatched(run)

      assert_receive {:mixpanel_track, [%{"properties" => props}]}
      assert props["distinct_id"] == "account:acc-2"
      assert props["source"] == "mcp"
    end
  end

  test "run_finished/1 carries the terminal status, duration, and source" do
    run = %ActionRun{
      status: :success,
      duration_ms: 1234,
      source: :operator,
      account_id: "acc-1",
      requested_by_id: "usr-9"
    }

    Events.run_finished(run)

    assert_receive {:mixpanel_track, [%{"event" => "run_finished", "properties" => props}]}
    assert props["distinct_id"] == "usr-9"
    assert props["status"] == "success"
    assert props["duration_ms"] == 1234
    assert props["account_id"] == "acc-1"
  end

  test "runner_connected/1 attributes to the account with runner metadata" do
    runner = %Runner{id: "rnr-7", account_id: "acc-3", runner_version: "1.4.0"}

    Events.runner_connected(runner)

    assert_receive {:mixpanel_track, [%{"event" => "runner_connected", "properties" => props}]}
    assert props["distinct_id"] == "account:acc-3"
    assert props["runner_id"] == "rnr-7"
    assert props["runner_version"] == "1.4.0"
    assert props["account_id"] == "acc-3"
  end

  test "approval_decided/1 carries the decision and the approver" do
    request = %Request{status: :approved, decided_by_id: "usr-4", account_id: "acc-5"}

    Events.approval_decided(request)

    assert_receive {:mixpanel_track, [%{"event" => "approval_decided", "properties" => props}]}
    assert props["distinct_id"] == "account:acc-5"
    assert props["decision"] == "approved"
    assert props["approver_id"] == "usr-4"
    assert props["account_id"] == "acc-5"
  end

  describe "operator engagement events attribute to the acting user" do
    setup do
      {:ok, subject: %Subject{actor: %User{id: "usr-1"}, account: %Account{id: "acc-1"}}}
    end

    test "pack_trusted/2", %{subject: subject} do
      pack = %PackVersion{pack_id: "linux-core", version: "1.2.0", account_id: "acc-1"}
      Events.pack_trusted(pack, subject)

      assert_receive {:mixpanel_track, [%{"event" => "pack_trusted", "properties" => props}]}
      assert props["distinct_id"] == "usr-1"
      assert props["pack_id"] == "linux-core"
      assert props["version"] == "1.2.0"
      assert props["account_id"] == "acc-1"
    end

    test "policy_updated/2", %{subject: subject} do
      Events.policy_updated(%Policy{scope_type: :runner, account_id: "acc-1"}, subject)

      assert_receive {:mixpanel_track, [%{"event" => "policy_updated", "properties" => props}]}
      assert props["distinct_id"] == "usr-1"
      assert props["scope_type"] == "runner"
      assert props["account_id"] == "acc-1"
    end

    test "runbook_published/2", %{subject: subject} do
      Events.runbook_published(%Runbook{id: "rb-1", version: 3, account_id: "acc-1"}, subject)

      assert_receive {:mixpanel_track, [%{"event" => "runbook_published", "properties" => props}]}
      assert props["distinct_id"] == "usr-1"
      assert props["runbook_id"] == "rb-1"
      assert props["version"] == 3
    end

    test "member_invited/2", %{subject: subject} do
      Events.member_invited(%Membership{role: :operator, account_id: "acc-1"}, subject)

      assert_receive {:mixpanel_track, [%{"event" => "member_invited", "properties" => props}]}
      assert props["distinct_id"] == "usr-1"
      assert props["role"] == "operator"
      assert props["account_id"] == "acc-1"
    end
  end

  test "invitation_accepted/1 attributes to the joining member" do
    Events.invitation_accepted(%Membership{user_id: "usr-2", role: :viewer, account_id: "acc-1"})

    assert_receive {:mixpanel_track, [%{"event" => "invitation_accepted", "properties" => props}]}
    assert props["distinct_id"] == "usr-2"
    assert props["role"] == "viewer"
    assert props["account_id"] == "acc-1"
  end

  test "subscription_changed/1 attributes to the account with plan + status" do
    Events.subscription_changed(%Subscription{
      account_id: "acc-1",
      plan: "team",
      status: "active"
    })

    assert_receive {:mixpanel_track,
                    [%{"event" => "subscription_changed", "properties" => props}]}

    assert props["distinct_id"] == "account:acc-1"
    assert props["plan"] == "team"
    assert props["status"] == "active"
    assert props["account_id"] == "acc-1"
  end
end
