defmodule EmisarWeb.MCPCancelRunTest do
  use EmisarWeb.ConnCase, async: true
  import EmisarWeb.MCPContractAssertions
  alias Emisar.{ApiKeys, Approvals, Audit, Repo, Runners}

  @pack_ref "linux-core@1.0.0/sha256:" <> String.duplicate("a", 64)

  setup %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "admin"
      )

    subject = Fixtures.Subjects.membership_subject(membership)
    _policy = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
    {:ok, raw, key} = ApiKeys.create_key(%{name: "cancel", kind: :mcp}, subject)
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, conn: authorize(conn, raw), account: account, user: user, key: key, runner: runner}
  end

  test "cancels the caller's own run while it waits for approval and closes the request", %{
    conn: conn,
    account: account,
    user: user,
    key: key,
    runner: runner
  } do
    run = own_run(account, runner, key, :pending_approval)
    {:ok, request} = Approvals.create_request(run, user.id, run.reason)

    result =
      call(conn, "cancel_run", %{
        "run_id" => run.id,
        "reason" => "The rollback already restored the service."
      })

    assert result["ok"] == true
    assert result["run"]["run_id"] == run.id
    assert result["run"]["status"] == "cancelled"
    assert result["run"]["review"]["status"] == "cancelled"
    refute Map.has_key?(result["run"], "approval")
    refute Map.has_key?(result["run"], "next")
    # Nothing ever ran, so nothing is missing: no output-gap flag.
    refute Map.has_key?(result["run"], "output_complete")
    assert Repo.reload!(request).status == :cancelled
    assert Repo.reload!(run).reason_text == "The rollback already restored the service."

    # The cancelled run reads back exactly as the tool returned it.
    waited = call(conn, "wait_for_run", %{"run_id" => run.id, "timeout" => "0"})
    assert waited["run"] == result["run"]

    requested = Enum.find(Repo.all(Audit.Event), &(&1.event_type == "run.cancel_requested"))
    assert requested.actor_kind == "api_key"
    assert requested.actor_id == key.id
    assert requested.payload["reason"] == "The rollback already restored the service."
  end

  test "a run already delivered to a runner is refused and left for the console", %{
    conn: conn,
    account: account,
    key: key,
    runner: runner
  } do
    run = own_run(account, runner, key, :running)

    result = call(conn, "cancel_run", %{"run_id" => run.id})

    assert result["ok"] == false
    assert result["error"]["code"] == "run_not_cancellable"
    assert result["error"]["retryable"] == false
    assert Repo.reload!(run) == run
    refute Enum.any?(Repo.all(Audit.Event), &(&1.event_type == "run.cancel_requested"))
  end

  test "another lineage's run and another account's run read as absent", %{
    conn: conn,
    account: account,
    runner: runner
  } do
    {_raw, other_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
    peer = own_run(account, runner, other_key, :pending_approval)
    foreign = Fixtures.Runs.create_run(status: :pending_approval)

    for run <- [peer, foreign] do
      result = call(conn, "cancel_run", %{"run_id" => run.id})
      assert result["error"]["code"] == "run_not_found"
      assert Repo.reload!(run) == run
    end
  end

  test "repeating the call returns the same cancelled run, and a long reason is rejected", %{
    conn: conn,
    account: account,
    key: key,
    runner: runner
  } do
    run = own_run(account, runner, key, :pending)

    first = call(conn, "cancel_run", %{"run_id" => run.id})
    assert first["run"]["status"] == "cancelled"
    assert Repo.reload!(run).reason_text == "cancelled by the requesting agent"

    assert call(conn, "cancel_run", %{"run_id" => run.id}) == first

    rejected =
      call(conn, "cancel_run", %{"run_id" => run.id, "reason" => String.duplicate("x", 256)})

    assert rejected["error"]["code"] == "invalid_args"
    assert Enum.count(Repo.all(Audit.Event), &(&1.event_type == "run.cancel_requested")) == 1
  end

  defp own_run(account, runner, key, status) do
    {:ok, runner_ref} = Runners.public_ref(runner)

    Fixtures.Runs.create_run(
      account_id: account.id,
      runner_id: runner.id,
      status: status,
      requires_approval: status == :pending_approval,
      source: :mcp,
      api_key_id: key.id,
      action_id: "linux.disk_usage",
      pack_ref: @pack_ref,
      operation_id: "op_724NN9NMDZ1T76NARWCKM5A0D6",
      runner_ref: runner_ref,
      reason: "Check whether /srv filled before the reload storm."
    )
  end

  defp call(conn, name, arguments) do
    result =
      conn
      |> rpc("tools/call", %{"name" => name, "arguments" => arguments})
      |> json_response(200)
      |> get_in(["result", "structuredContent"])

    assert_valid_tool_result(name, result)
  end

  defp rpc(conn, method, params) do
    body = %{jsonrpc: "2.0", id: 1, method: method, params: params}

    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/mcp/rpc", Jason.encode!(body))
  end

  defp authorize(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)
end
