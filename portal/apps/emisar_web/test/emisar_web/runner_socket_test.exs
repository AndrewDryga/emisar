defmodule EmisarWeb.RunnerSocketTest do
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Fixtures, Repo, Runners, Runs}
  alias Emisar.Runners.Presence
  alias Emisar.Runs.ActionRun
  alias EmisarWeb.RunnerSocket

  describe "POST /runner/register (bearer-authed)" do
    setup do
      {:ok, user} =
        Emisar.Users.register_user(%{
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
        Emisar.Users.register_user(%{
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
      subject = Emisar.Fixtures.subject_for(user, account, role: :owner)

      %{account: account, runner: runner, token: token, subject: subject}
    end

    test "a connected runner reads online and receives dispatched actions",
         %{account: account, runner: runner, token: token, subject: subject} do
      # Bring the socket up through the production init path: the test
      # process *becomes* the runner socket — tracked in presence AND
      # subscribed to its cloud→runner delivery topic.
      refute Runners.online?(account.id, runner.id)
      assert {:ok, _state} = RunnerSocket.init(%{token: token, runner: runner})
      assert Runners.online?(account.id, runner.id)

      # Dispatch, and assert the run_action envelope actually reaches the
      # socket process — the "messages weren't delivered" symptom.
      {:ok, :running, run} =
        Runs.dispatch_run(dispatch_attrs(account, runner), subject)

      assert_receive {:cloud_to_runner, %{"type" => "run_action", "request_id" => req_id}}, 1_000
      assert req_id == run.request_id

      # The dispatch-timeout sweep must leave a *connected* runner's run
      # alone, even past the grace window — this is what regressed.
      backdate_to_stale!(run)
      assert :ok = Emisar.Workers.RunDispatchTimeout.perform(%Oban.Job{args: %{}})
      assert Repo.get!(ActionRun, run.id).status == "sent"
    end

    test "a run is timed out only after its runner drops off presence",
         %{account: account, runner: runner, token: token, subject: subject} do
      assert {:ok, _state} = RunnerSocket.init(%{token: token, runner: runner})

      {:ok, :running, run} =
        Runs.dispatch_run(dispatch_attrs(account, runner), subject)

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

  # Drives the real `handle_in/2` text seam and `handle_envelope/3` behind
  # it — the same path production hits when a runner sends a JSON frame.
  # Frames that don't carry a valid type/protocol are answered with an
  # error envelope; the socket NEVER crashes or disconnects on bad input.
  describe "handle_in/2 — malformed + unknown frames" do
    setup [:connected_socket]

    test "malformed JSON is answered with bad_envelope, socket stays up", %{state: state} do
      assert {:push, frame, ^state} = RunnerSocket.handle_in({"{not json", text()}, state)

      assert decode(frame) == %{
               "type" => "error",
               "code" => "bad_envelope",
               "message" => "malformed JSON",
               "protocol_version" => 1
             }
    end

    test "valid JSON with no type field is answered with bad_envelope", %{state: state} do
      raw = Jason.encode!(%{"request_id" => "req_x", "status" => "success"})
      assert {:push, frame, ^state} = RunnerSocket.handle_in({raw, text()}, state)
      assert %{"code" => "bad_envelope", "message" => "missing type field"} = decode(frame)
    end

    test "unknown type is logged-and-ignored, socket stays up", %{state: state} do
      raw = Jason.encode!(%{"type" => "from_the_future", "data" => 1})
      assert {:ok, ^state} = RunnerSocket.handle_in({raw, text()}, state)
    end

    test "mismatched protocol_version is rejected without dispatching", %{state: state} do
      raw = Jason.encode!(%{"type" => "heartbeat", "protocol_version" => 99})
      assert {:push, frame, ^state} = RunnerSocket.handle_in({raw, text()}, state)
      assert %{"code" => "protocol_version_mismatch"} = decode(frame)
    end

    test "binary / ping / pong opcodes are accepted and ignored", %{state: state} do
      for opcode <- [:binary, :ping, :pong] do
        assert {:ok, ^state} = RunnerSocket.handle_in({<<0, 1, 2>>, [opcode: opcode]}, state)
      end
    end

    test "an unknown frame doesn't poison the next valid frame", %{state: state} do
      junk = Jason.encode!(%{"type" => "from_the_future"})
      assert {:ok, state} = RunnerSocket.handle_in({junk, text()}, state)

      # A real heartbeat right after still works (presence updates, no crash).
      hb = Jason.encode!(%{"type" => "heartbeat", "action_load" => 3})
      assert {:ok, _state} = RunnerSocket.handle_in({hb, text()}, state)
    end
  end

  describe "handle_in/2 — action_result dedup ring" do
    setup [:connected_socket, :dispatched_run]

    test "first result finalizes the run; a duplicate is acked WITHOUT re-finalizing",
         %{state: state, run: run} do
      frame_in = result_frame(run.request_id, "success", exit_code: 0)

      # First result: run transitions to a terminal success.
      assert {:push, ack, state} = RunnerSocket.handle_in({frame_in, text()}, state)
      assert %{"type" => "ack_result", "request_id" => req} = decode(ack)
      assert req == run.request_id
      finalized = Repo.get!(ActionRun, run.id)
      assert finalized.status == "success"
      assert finalized.exit_code == 0

      # A SECOND copy of the same request_id is short-circuited by the dedup
      # ring: still acked, but `finalize_from_result` does NOT run again, so
      # the differing exit_code in this duplicate is ignored.
      dup = result_frame(run.request_id, "error", exit_code: 137)
      assert {:push, ack2, ^state} = RunnerSocket.handle_in({dup, text()}, state)
      assert %{"type" => "ack_result"} = decode(ack2)

      unchanged = Repo.get!(ActionRun, run.id)
      assert unchanged.status == "success"
      assert unchanged.exit_code == 0
    end

    test "a result for an unknown request_id is acked and remembered", %{state: state} do
      frame_in = result_frame("req_does_not_exist", "success", [])
      assert {:push, ack, state} = RunnerSocket.handle_in({frame_in, text()}, state)
      assert %{"type" => "ack_result", "request_id" => "req_does_not_exist"} = decode(ack)

      # Remembered: a retry of the same unknown id is deduped (still acked,
      # never re-attempts the unknown-request lookup/log).
      assert {:push, _ack, ^state} = RunnerSocket.handle_in({frame_in, text()}, state)
    end
  end

  describe "handle_in/2 — terminal-state idempotency (H1)" do
    setup [:connected_socket, :dispatched_run]

    test "a late result for an ALREADY-terminal run can't overwrite it (transition guard)",
         %{state: state, runner: runner, run: run} do
      # Finalize the run to success out-of-band, mimicking an operator cancel
      # or dispatch-timeout that already drove the run terminal. Crucially the
      # socket's dedup ring is still EMPTY, so the next frame is NOT deduped —
      # it exercises the `Runs.transition/3` terminal guard, not the ring.
      {:ok, _} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "success",
          "exit_code" => 0
        })

      assert Repo.get!(ActionRun, run.id).status == "success"

      late = result_frame(run.request_id, "error", exit_code: 1)
      assert {:push, ack, _state} = RunnerSocket.handle_in({late, text()}, state)
      assert %{"type" => "ack_result"} = decode(ack)

      # H1: terminal status + result fields are unchanged; no overwrite.
      final = Repo.get!(ActionRun, run.id)
      assert final.status == "success"
      assert final.exit_code == 0
    end

    test "the run-detail timeline doesn't gain a second terminal event from the late result",
         %{state: state, runner: runner, run: run, subject: subject} do
      {:ok, _} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "success"
        })

      late = result_frame(run.request_id, "error", [])
      assert {:push, _ack, _state} = RunnerSocket.handle_in({late, text()}, state)

      # Only the single (idempotent) terminal transition is reflected; the
      # late duplicate didn't append a second terminal audit event.
      assert count_terminal_audit_events(run, subject) == 1
    end
  end

  describe "handle_in/2 — heartbeat" do
    setup [:connected_socket]

    test "heartbeat refreshes presence last_heartbeat + action_load", %{
      state: state,
      runner: runner
    } do
      raw = Jason.encode!(%{"type" => "heartbeat", "action_load" => 9})
      assert {:ok, _state} = RunnerSocket.handle_in({raw, text()}, state)

      assert %{metas: [meta | _]} =
               Runners.connection_metas(runner.account_id) |> Map.fetch!(runner.id)

      assert meta.action_load == 9
      assert is_integer(meta.last_heartbeat_at)
    end
  end

  describe "handle_info/2 — heartbeat timeout" do
    setup [:connected_socket]

    test "missing-heartbeat timeout stops the socket normally", %{state: state} do
      assert {:stop, :normal, ^state} = RunnerSocket.handle_info(:heartbeat_timeout, state)
    end
  end

  # -- Test seam setup + helpers --------------------------------------

  # Brings the socket up through the real production init path: this test
  # process *becomes* the runner socket (tracked in presence + subscribed
  # to its cloud→runner topic), exactly like the end-to-end tests above.
  defp connected_socket(_ctx) do
    {:ok, user} =
      Emisar.Users.register_user(%{
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

    {:ok, state} = RunnerSocket.init(%{token: token, runner: runner})
    subject = Fixtures.subject_for(user, account, role: :owner)

    %{account: account, user: user, runner: runner, state: state, subject: subject}
  end

  # Dispatches a real run to the connected runner and drains the resulting
  # run_action envelope off this process's mailbox so later assert_receive
  # calls aren't confused by it. Leaves the run in "sent".
  defp dispatched_run(%{account: account, runner: runner, subject: subject}) do
    {:ok, :running, run} = Runs.dispatch_run(dispatch_attrs(account, runner), subject)
    assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 1_000
    %{run: run}
  end

  defp text, do: [opcode: :text]

  defp decode({:text, json}), do: Jason.decode!(json)

  defp result_frame(request_id, status, extra) do
    %{"type" => "action_result", "request_id" => request_id, "status" => status}
    |> Map.merge(Map.new(extra, fn {k, v} -> {to_string(k), v} end))
    |> Jason.encode!()
  end

  defp count_terminal_audit_events(run, subject) do
    {:ok, events, _meta} = Emisar.Audit.list_events(subject, page: [limit: 200])

    Enum.count(events, fn e ->
      e.subject_id == run.id and
        e.event_type in ~w(action_run.success action_run.error action_run.failed)
    end)
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
