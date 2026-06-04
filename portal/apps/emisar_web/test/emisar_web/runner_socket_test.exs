defmodule EmisarWeb.RunnerSocketTest do
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Fixtures, Repo, Runners, Runs}
  alias Emisar.Auth.Subject
  alias Emisar.Runners.Presence
  alias Emisar.Runs.ActionRun
  alias EmisarWeb.RunnerSocket

  describe "POST /runner/register (bearer-authed)" do
    setup do
      {:ok, user} =
        Emisar.Accounts.register_user(%{
          email: "owner-#{System.unique_integer([:positive])}@example.com",
          password: "very-long-password-1234"
        })

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(
          %{name: "OwnerCo", slug: Emisar.Accounts.suggest_unique_slug("OwnerCo"), plan: "team"},
          user
        )

      subject = Emisar.Fixtures.subject_for(user, account, role: :owner)
      {:ok, raw_key, _key} = Runners.create_auth_key(%{description: "test"}, subject)
      %{account: account, user: user, raw_key: raw_key}
    end

    test "exchanges auth key for runner token", %{conn: conn, raw_key: raw_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw_key)
        |> post(~p"/runner/register", %{
          "hostname" => "ip-10-0-0-1",
          "group" => "default",
          "version" => "0.2.0"
        })

      assert %{"runner_id" => _, "token" => "rnrtok-" <> _, "account_id" => _} =
               json_response(conn, 201)
    end

    test "rejects missing bearer", %{conn: conn} do
      conn = post(conn, ~p"/runner/register", %{})
      assert json_response(conn, 401) == %{"error" => "missing_bearer"}
    end

    test "rejects bogus auth key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer emkey-auth-NOTREAL")
        |> post(~p"/runner/register", %{})

      assert json_response(conn, 401) == %{"error" => "auth_key_invalid"}
    end
  end

  describe "GET /healthz" do
    test "returns ok", %{conn: conn} do
      assert json_response(get(conn, ~p"/healthz"), 200) == %{"status" => "ok"}
    end
  end

  # End-to-end through the *real* RunnerSocket.init path — the same code
  # production runs. A runner that connects is tracked in presence, reads
  # "online", and actually receives dispatched actions over PubSub.
  # Regression guard for the incident where connected runners were treated
  # as disconnected and dispatches never reached them.
  describe "runner socket dispatch (end-to-end)" do
    setup do
      {:ok, user} =
        Emisar.Accounts.register_user(%{
          email: "owner-#{System.unique_integer([:positive])}@example.com",
          password: "very-long-password-1234"
        })

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(
          %{name: "OwnerCo", slug: Emisar.Accounts.suggest_unique_slug("OwnerCo"), plan: "team"},
          user
        )

      runner = Fixtures.runner_fixture(account_id: account.id, connected?: false)
      _ = Fixtures.action_fixture(runner: runner)
      _ = Fixtures.policy_fixture(account_id: account.id, created_by_id: user.id)
      {_raw, token} = Runners.mint_runner_token(runner)

      %{account: account, runner: runner, token: token}
    end

    test "a connected runner reads online and receives dispatched actions",
         %{account: account, runner: runner, token: token} do
      # Bring the socket up through the production init path: the test
      # process *becomes* the runner socket — tracked in presence AND
      # subscribed to its cloud→runner delivery topic.
      refute Runners.online?(account.id, runner.id)
      assert {:ok, _state} = RunnerSocket.init(%{token: token, runner: runner})
      assert Runners.online?(account.id, runner.id)

      # Dispatch, and assert the run_action envelope actually reaches the
      # socket process — the "messages weren't delivered" symptom.
      {:ok, :running, run} =
        Runs.dispatch_run(dispatch_attrs(account, runner), Subject.system(account))

      assert_receive {:cloud_to_runner, %{"type" => "run_action", "request_id" => req_id}}, 1_000
      assert req_id == run.request_id

      # The dispatch-timeout sweep must leave a *connected* runner's run
      # alone, even past the grace window — this is what regressed.
      backdate_to_stale!(run)
      assert :ok = Emisar.Workers.RunDispatchTimeout.perform(%Oban.Job{args: %{}})
      assert Repo.get!(ActionRun, run.id).status == "sent"
    end

    test "a run is timed out only after its runner drops off presence",
         %{account: account, runner: runner, token: token} do
      assert {:ok, _state} = RunnerSocket.init(%{token: token, runner: runner})

      {:ok, :running, run} =
        Runs.dispatch_run(dispatch_attrs(account, runner), Subject.system(account))

      assert_receive {:cloud_to_runner, _}, 1_000

      # Socket drops — presence clears, exactly as it does when the
      # connection process dies (Phoenix.Presence auto-untracks).
      :ok = Presence.untrack(self(), Presence.topic(account.id), runner.id)
      refute Runners.online?(account.id, runner.id)

      backdate_to_stale!(run)
      assert :ok = Emisar.Workers.RunDispatchTimeout.perform(%Oban.Job{args: %{}})

      timed_out = Repo.get!(ActionRun, run.id)
      assert timed_out.status == "error"
      assert timed_out.error_message =~ "offline"
    end
  end

  defp dispatch_attrs(account, runner) do
    %{
      runner_id: runner.id,
      action_id: "linux.uptime",
      args: %{},
      reason: "mcp smoke test",
      source: "operator",
      account_id: account.id
    }
  end

  defp backdate_to_stale!(run) do
    stale = DateTime.utc_now() |> DateTime.add(-5 * 60, :second)

    ActionRun
    |> Repo.get!(run.id)
    |> Ecto.Changeset.change(queued_at: stale, status: "sent")
    |> Repo.update!()
  end
end
