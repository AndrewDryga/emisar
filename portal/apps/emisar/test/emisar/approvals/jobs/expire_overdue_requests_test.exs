defmodule Emisar.Approvals.Jobs.ExpireOverdueRequestsTest do
  @moduledoc """
  The 5-minute sweep that auto-rejects approval requests past their
  `expires_at` and cancels the gated run, so an LLM can't hold a
  high-risk action open waiting for an operator who never decides.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Approvals
  alias Emisar.Approvals.Jobs.ExpireOverdueRequests
  alias Emisar.Approvals.Request
  alias Emisar.Fixtures
  alias Emisar.Repo
  alias Emisar.Runs

  defp overdue_request do
    account = Fixtures.Accounts.create_account()
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{},
        reason: "expiry sweep test"
      })

    {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")

    yesterday = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)
    {:ok, request} = request |> Ecto.Changeset.change(expires_at: yesterday) |> Repo.update()
    {request, run}
  end

  test "execute/1 expires the overdue request and cancels its run" do
    {request, run} = overdue_request()

    assert :ok = ExpireOverdueRequests.execute([])

    assert %Request{status: :expired} = Repo.reload!(request)
    assert Repo.reload!(run).status == :cancelled
  end

  test "execute/1 leaves a still-fresh pending request alone" do
    account = Fixtures.Accounts.create_account()
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{},
        reason: "still fresh"
      })

    {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")

    assert :ok = ExpireOverdueRequests.execute([])

    assert %Request{status: :pending} = Repo.reload!(request)
  end
end

defmodule Emisar.Approvals.Jobs.ExpireOverdueRequestsLogTest do
  @moduledoc """
  The swept-count log line. `async: false` because it raises the global Logger
  level to `:info` (the test env defaults to `:warning`) to observe an info log.
  """
  use Emisar.DataCase, async: false
  import ExUnit.CaptureLog
  alias Emisar.Approvals
  alias Emisar.Approvals.Jobs.ExpireOverdueRequests
  alias Emisar.Fixtures
  alias Emisar.Repo
  alias Emisar.Runs

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp overdue_request do
    account = Fixtures.Accounts.create_account()
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{},
        reason: "expiry sweep test"
      })

    {:ok, request} = Approvals.create_request(run, Fixtures.Users.create_user().id, "x")
    yesterday = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)
    {:ok, _} = request |> Ecto.Changeset.change(expires_at: yesterday) |> Repo.update()
    :ok
  end

  # the swept-count line is logged ONLY when at least one
  # request expired (the `if expired > 0` guard). A zero-result sweep (every
  # cron tick when the queue is empty) stays silent, so the log isn't drowned
  # in "swept 0" noise; a sweep that expires a row logs the count.
  test "execute/1 logs the swept count only when something expired" do
    # Nothing overdue → silent sweep.
    silent = capture_log(fn -> assert :ok = ExpireOverdueRequests.execute([]) end)
    refute silent =~ "approval_expiry.swept"

    :ok = overdue_request()

    # One overdue request → the count is logged.
    noisy = capture_log(fn -> assert :ok = ExpireOverdueRequests.execute([]) end)
    assert noisy =~ "approval_expiry.swept"
  end
end
