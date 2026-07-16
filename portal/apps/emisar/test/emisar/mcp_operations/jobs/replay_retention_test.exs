defmodule Emisar.MCPOperations.Jobs.ReplayRetentionTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{ApiKeys, Audit, Auth, Fixtures, MCPOperations, Repo, Runs}
  alias Emisar.MCPOperations.Jobs.ReplayRetention
  alias Emisar.MCPOperations.Operation

  @fingerprint String.duplicate("a", 64)
  @pack_ref "linux-core@1.0.0/sha256:" <> String.duplicate("b", 64)

  setup do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    owner_subject = Auth.Subject.for_user(user, account, membership)
    {:ok, _raw, key} = ApiKeys.create_key(%{name: "MCP"}, owner_subject)
    key_subject = Auth.Subject.for_api_key(key, account)

    %{account: account, key: key, key_subject: key_subject}
  end

  test "runs daily because operation identities have day-level retention precision" do
    assert %{
             id: ReplayRetention,
             start: {_executor, :start_link, [{ReplayRetention, interval, _config}]}
           } = ReplayRetention.child_spec([])

    assert interval == :timer.hours(24)
  end

  test "prunes old operations and nilifies child run references", %{
    account: account,
    key: key,
    key_subject: key_subject
  } do
    operation_id = MCPOperations.operation_id("old", key_subject)
    operation = reserve!(operation_id, key_subject)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "retention test",
        source: "mcp",
        api_key_id: key.id,
        operation_id: operation.operation_id,
        pack_ref: @pack_ref,
        runner_ref: "runner-1",
        mcp_operation_record_id: operation.id
      })

    old = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second)

    assert {1, _} = backdate_operation(operation.operation_id, old)

    assert :ok = ReplayRetention.execute([])
    assert :ok = ReplayRetention.execute([])

    refute Repo.reload(operation)
    assert Repo.reload!(run).mcp_operation_record_id == nil
  end

  test "prunes operations past the replay window and keeps recent ones", %{
    key_subject: key_subject
  } do
    old_id = MCPOperations.operation_id("old", key_subject)
    fresh_id = MCPOperations.operation_id("fresh", key_subject)
    old_operation = reserve!(old_id, key_subject)
    fresh_operation = reserve!(fresh_id, key_subject)

    old = DateTime.utc_now() |> DateTime.add(-(24 * 3_600 + 60), :second)
    fresh = DateTime.utc_now() |> DateTime.add(-3_600, :second)

    assert {1, _} = backdate_operation(old_id, old)
    assert {1, _} = backdate_operation(fresh_id, fresh)

    assert :ok = ReplayRetention.execute([])

    refute Repo.reload(old_operation)
    assert Repo.reload(fresh_operation)
  end

  test "does not create housekeeping markers for an inactive account", %{account: account} do
    old = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second)

    {:ok, _marker} =
      Audit.log(account.id, "audit.retention_swept",
        actor_kind: "system",
        target_kind: "audit_log",
        occurred_at: old,
        payload: %{count: 1}
      )

    Fixtures.Accounts.mark_account_as_deleted(account)

    assert :ok = ReplayRetention.execute([])
    assert :ok = ReplayRetention.execute([])

    markers =
      Audit.Event.Query.all()
      |> Audit.Event.Query.by_account_id(account.id)
      |> Audit.Event.Query.by_event_type("audit.retention_swept")
      |> Repo.all()

    assert length(markers) == 1
  end

  defp reserve!(operation_id, subject) do
    attrs = %{
      operation_id: operation_id,
      tool: :run_action,
      fingerprint: @fingerprint,
      action_id: "linux.uptime",
      pack_ref: @pack_ref
    }

    {:ok, multi} = MCPOperations.reserve_in_multi(Multi.new(), attrs, subject)
    {:ok, %{mcp_operation: %{operation: operation}}} = Repo.commit_multi(multi)
    operation
  end

  defp backdate_operation(operation_id, timestamp) do
    Operation.Query.all()
    |> Operation.Query.by_operation_id(operation_id)
    |> Repo.update_all(set: [inserted_at: timestamp])
  end
end
