defmodule EmisarWeb.RunnerSocketTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Catalog, Fixtures, Repo, Runners, Runs}
  alias Emisar.RequestContext
  alias Emisar.Runners.{Presence, Runner}
  alias Emisar.Runs.ActionRun
  alias EmisarWeb.RunnerSocket

  describe "POST /runner/register (bearer-authed)" do
    setup do
      {:ok, user} =
        Emisar.Users.register_user(%{
          email: "owner-#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(
          %{name: "OwnerCo", slug: Emisar.Accounts.suggest_unique_slug("OwnerCo")},
          user
        )

      # Team plan (via a subscription) so the registration tests below aren't
      # capped at free's 3-runner limit; plan lives on the subscription now.
      Fixtures.Accounts.create_subscription(account, "team")

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      {:ok, raw_key, _key} = Runners.create_enrollment_key(%{description: "test"}, subject)
      %{account: account, user: user, raw_key: raw_key}
    end

    test "exchanges and safely retries a single-use enrollment key", %{
      conn: conn,
      raw_key: raw_key
    } do
      external_id = Ecto.UUID.generate()

      first =
        conn
        |> put_req_header("authorization", "Bearer " <> raw_key)
        |> post(~p"/runner/register", %{
          "external_id" => external_id,
          "hostname" => "ip-10-0-0-1",
          "group" => "default",
          "version" => "0.2.0"
        })

      first_body = json_response(first, 201)
      assert %{"token" => "rnrtok-" <> first_token} = first_body
      assert map_size(first_body) == 1

      retry =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw_key)
        |> post(~p"/runner/register", %{
          "external_id" => external_id,
          "hostname" => "ip-10-0-0-1",
          "group" => "default",
          "version" => "0.2.0"
        })

      assert %{"token" => "rnrtok-" <> retry_token} = json_response(retry, 201)
      refute first_token == retry_token

      different_identity =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw_key)
        |> post(~p"/runner/register", %{"external_id" => Ecto.UUID.generate()})

      assert json_response(different_identity, 401) == %{"error" => "enrollment_key_invalid"}
    end

    test "rejects missing bearer", %{conn: conn} do
      conn = post(conn, ~p"/runner/register", %{})
      assert json_response(conn, 401) == %{"error" => "missing_bearer"}
    end

    test "rejects bogus auth key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer emkey-auth-NOTREAL")
        |> post(~p"/runner/register", %{"external_id" => "bogus-key-runner"})

      assert json_response(conn, 401) == %{"error" => "enrollment_key_invalid"}
    end

    test "rejects malformed fields without consuming the enrollment key", %{
      conn: conn,
      raw_key: raw_key
    } do
      for params <- [
            %{"external_id" => "malformed-hostname", "hostname" => %{"nested" => "value"}},
            %{"external_id" => "malformed-group", "group" => %{"nested" => "value"}},
            %{"external_id" => "malformed-version", "version" => %{"nested" => "value"}},
            %{"external_id" => "malformed-labels", "labels" => "not-a-map"}
          ] do
        response = register(build_conn(), raw_key, params)

        assert json_response(response, 400) == %{"error" => "register_failed"}
      end

      response = register(conn, raw_key, %{"external_id" => "valid-after-malformed"})
      assert %{"token" => "rnrtok-" <> _} = json_response(response, 201)
    end

    test "rejects invalid external IDs without consuming the enrollment key", %{
      conn: conn,
      raw_key: raw_key
    } do
      for external_id <- [nil, "", "  ", %{"nested" => "value"}, String.duplicate("x", 256)] do
        params = if is_nil(external_id), do: %{}, else: %{"external_id" => external_id}
        response = register(build_conn(), raw_key, params)
        assert json_response(response, 400) == %{"error" => "invalid_external_id"}
      end

      response = register(conn, raw_key, %{"external_id" => "valid-after-invalid"})
      assert %{"token" => "rnrtok-" <> _} = json_response(response, 201)
    end
  end

  describe "POST /runner/register — limits and name conflicts" do
    setup do
      {:ok, user} =
        Emisar.Users.register_user(%{
          email: "owner-#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(
          %{name: "OwnerCo", slug: Emisar.Accounts.suggest_unique_slug("OwnerCo")},
          user
        )

      # Team plan (via a subscription) so the registration tests below aren't
      # capped at free's 3-runner limit; plan lives on the subscription now.
      Fixtures.Accounts.create_subscription(account, "team")

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      # Reusable: these tests register several runners off one bootstrap key.
      {:ok, raw_key, _key} =
        Runners.create_enrollment_key(%{description: "test", reusable: true}, subject)

      %{account: account, raw_key: raw_key}
    end

    defp register(conn, raw_key, params) do
      conn
      |> put_req_header("authorization", "Bearer " <> raw_key)
      |> post(~p"/runner/register", params)
    end

    test "the free plan caps runners at its limit → 402", %{conn: conn} do
      {:ok, user} =
        Emisar.Users.register_user(%{
          email: "owner-#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(
          %{name: "FreeCo", slug: Emisar.Accounts.suggest_unique_slug("FreeCo")},
          user
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, raw_key, _key} =
        Runners.create_enrollment_key(%{description: "test", reusable: true}, subject)

      for n <- 1..3 do
        response =
          register(build_conn(), raw_key, %{"external_id" => "free-#{n}", "hostname" => "h#{n}"})

        assert %{"token" => "rnrtok-" <> _} = json_response(response, 201)
      end

      over = register(conn, raw_key, %{"external_id" => "free-4", "hostname" => "h4"})

      assert json_response(over, 402) == %{
               "error" => "runner_limit_exceeded",
               "plan" => "free",
               "limit" => 3
             }
    end

    test "a CONNECTED holder of the same name → 409; re-register of the same external_id is idempotent",
         %{conn: conn, raw_key: raw_key, account: account} do
      first =
        register(conn, raw_key, %{"external_id" => "squat-a", "hostname" => "shared-name"})

      assert %{"token" => "rnrtok-" <> _} = json_response(first, 201)

      # Same external_id → same runner back, no conflict (idempotent boot).
      again =
        register(build_conn(), raw_key, %{"external_id" => "squat-a", "hostname" => "shared-name"})

      assert %{"token" => "rnrtok-" <> _} = json_response(again, 201)

      # Bring the holder online — only an ACTIVE holder defends its name.
      runner =
        Runner.Query.all()
        |> Runner.Query.by_account_id(account.id)
        |> Runner.Query.by_external_id("squat-a")
        |> Repo.one!()

      Runners.connect_runner(runner)
      assert Runners.online?(account.id, runner.id)

      conflict =
        register(build_conn(), raw_key, %{"external_id" => "squat-b", "hostname" => "shared-name"})

      assert %{"error" => "runner_name_taken", "name" => "shared-name"} =
               json_response(conflict, 409)
    end
  end

  describe "GET /runner/socket/websocket — bearer gate" do
    test "missing bearer → 401", %{conn: conn} do
      conn = get(conn, "/runner/socket/websocket")
      assert json_response(conn, 401) == %{"error" => "missing_bearer"}
    end

    test "an invalid runner token → 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer rnrtok-FORGED")
        |> get("/runner/socket/websocket")

      assert json_response(conn, 401) == %{"error" => "token_invalid"}
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
          email: "owner-#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(
          %{name: "OwnerCo", slug: Emisar.Accounts.suggest_unique_slug("OwnerCo")},
          user
        )

      # Team plan (via a subscription) so the registration tests below aren't
      # capped at free's 3-runner limit; plan lives on the subscription now.
      Fixtures.Accounts.create_subscription(account, "team")

      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      _ = Fixtures.Catalog.create_action(runner: runner)
      _ = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
      {_raw, token} = Runners.mint_runner_token(runner)
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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

      assert_receive {:cloud_to_runner, _generation,
                      %{"type" => "run_action", "request_id" => req_id}},
                     1_000

      assert req_id == run.request_id

      # The dispatch-timeout sweep must leave a *connected* runner's run
      # alone, even past the grace window — this is what regressed.
      backdate_to_stale!(run)
      assert :ok = Emisar.Runs.Jobs.DispatchTimeout.execute([])
      assert Repo.get!(ActionRun, run.id).status == :sent
    end

    test "a sent run fails closed after its runner disconnects",
         %{account: account, runner: runner, token: token, subject: subject} do
      assert {:ok, state} = RunnerSocket.init(%{token: token, runner: runner})

      {:ok, :running, run} =
        Runs.dispatch_run(dispatch_attrs(account, runner), subject)

      assert_receive {:cloud_to_runner, _generation, _}, 1_000

      # Socket drops — terminate releases the durable lease and Presence
      # clears when the connection process dies.
      assert :ok = RunnerSocket.terminate(:remote, state)
      :ok = Presence.untrack(self(), Presence.topic(account.id), runner.id)
      refute Runners.online?(account.id, runner.id)

      backdate_to_stale!(run)
      assert :ok = Emisar.Runs.Jobs.DispatchTimeout.execute([])

      timed_out = Repo.get!(ActionRun, run.id)
      assert timed_out.status == :error
      assert timed_out.error_message =~ "disconnected after accepting this dispatch"
      assert timed_out.error_message =~ "outcome is unknown"
      assert timed_out.error_message =~ "did not execute it again"
    end

    test "a reconnect resumes an unresolved dispatch without re-executing it",
         %{account: account, runner: runner, token: token, subject: subject} do
      assert {:ok, first_state} = RunnerSocket.init(%{token: token, runner: runner})

      {:ok, :running, run} =
        Runs.dispatch_run(dispatch_attrs(account, runner), subject)

      assert_receive {:cloud_to_runner, _generation,
                      %{"type" => "run_action", "request_id" => request_id} = original_action},
                     1_000

      assert request_id == run.request_id
      assert :ok = RunnerSocket.terminate(:remote, first_state)
      :ok = Presence.untrack(self(), Presence.topic(account.id), runner.id)

      assert {:ok, second_state} = RunnerSocket.init(%{token: token, runner: runner})

      runner_state = runner_frame(%{"type" => "runner_state", "packs" => %{}, "actions" => []})
      assert {:ok, refreshed_state} = RunnerSocket.handle_in({runner_state, text()}, second_state)
      assert_receive :resume_runs
      assert {:ok, ^refreshed_state} = RunnerSocket.handle_info(:resume_runs, refreshed_state)

      assert_receive {:cloud_to_runner, successor_generation,
                      %{"type" => "run_action"} = recovered_action},
                     1_000

      assert successor_generation == refreshed_state.connection_generation
      assert recovered_action == original_action

      started = runner_frame(%{"type" => "action_started", "request_id" => run.request_id})
      assert {:ok, ^refreshed_state} = RunnerSocket.handle_in({started, text()}, refreshed_state)
      assert Repo.get!(ActionRun, run.id).status == :running

      progress =
        runner_frame(%{
          "type" => "action_progress",
          "request_id" => run.request_id,
          "seq" => 1,
          "stream" => "stdout",
          "chunk" => "resumed\n"
        })

      assert {:ok, ^refreshed_state} = RunnerSocket.handle_in({progress, text()}, refreshed_state)

      result = result_frame(run.request_id, "success", exit_code: 0)

      assert {:push, ack, _remembered_state} =
               RunnerSocket.handle_in({result, text()}, refreshed_state)

      assert %{"type" => "ack_result", "request_id" => ^request_id} = decode(ack)

      reloaded = Repo.get!(ActionRun, run.id)
      assert reloaded.status == :success
      assert reloaded.progress_event_count == 1
    end

    test "a first connection dispatches work that was queued while offline",
         %{account: account, runner: runner, token: token, subject: subject} do
      {:ok, :running, run} =
        Runs.dispatch_run(dispatch_attrs(account, runner), subject)

      assert Repo.get!(ActionRun, run.id).status == :pending
      assert {:ok, state} = RunnerSocket.init(%{token: token, runner: runner})

      refute_receive :resume_runs

      raw = runner_frame(%{"type" => "runner_state", "packs" => %{}, "actions" => []})
      assert {:ok, refreshed_state} = RunnerSocket.handle_in({raw, text()}, state)
      assert_receive :resume_runs

      assert {:ok, ^refreshed_state} =
               RunnerSocket.handle_info(:resume_runs, refreshed_state)

      assert_receive {:cloud_to_runner, _generation,
                      %{"type" => "run_action", "request_id" => request_id}},
                     1_000

      assert request_id == run.request_id
      assert Repo.get!(ActionRun, run.id).status == :sent
    end

    test "a duplicate live runner identity is closed with an actionable reason",
         %{runner: runner, token: token} do
      assert {:ok, _state} = RunnerSocket.init(%{token: token, runner: runner})

      assert {:stop, :normal, {1013, message}, %{rejected?: true} = rejected_state} =
               RunnerSocket.init(%{token: token, runner: runner})

      assert message =~ "cloned data directory"

      # Bandit may already have buffered the runner's first frame when init
      # rejects the upgrade. The close must win without invoking callbacks
      # that expect a fully connected state.
      assert {:stop, :normal, ^rejected_state} =
               RunnerSocket.handle_in({"{}", text()}, rejected_state)

      assert {:stop, :normal, ^rejected_state} =
               RunnerSocket.handle_info(:buffered_after_rejection, rejected_state)
    end
  end

  # Drives the real `handle_in/2` text seam and `handle_envelope/3` behind
  # it — the same path production hits when a runner sends a JSON frame.
  # Malformed envelopes are answered without crashing. Known message types
  # with an incompatible version close before their payload is handled.
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

    test "mismatched protocol_version closes before dispatching", %{state: state} do
      raw = Jason.encode!(%{"type" => "heartbeat", "protocol_version" => 99})

      assert {:stop, :normal, {1002, "Unsupported runner protocol_version."}, ^state} =
               RunnerSocket.handle_in({raw, text()}, state)
    end

    test "missing protocol_version closes a known message", %{state: state} do
      raw = Jason.encode!(%{"type" => "heartbeat"})

      assert {:stop, :normal, {1002, "Unsupported runner protocol_version."}, ^state} =
               RunnerSocket.handle_in({raw, text()}, state)
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
      hb = runner_frame(%{"type" => "heartbeat", "action_load" => 3})
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
      assert %{"type" => "ack_result", "request_id" => acked_request_id} = decode(ack)
      assert acked_request_id == run.request_id
      finalized = Repo.get!(ActionRun, run.id)
      assert finalized.status == :success
      assert finalized.exit_code == 0

      # A SECOND copy of the same request_id is short-circuited by the dedup
      # ring: still acked, but `finalize_from_result` does NOT run again, so
      # the differing exit_code in this duplicate is ignored.
      dup = result_frame(run.request_id, "error", exit_code: 137)
      assert {:push, ack2, ^state} = RunnerSocket.handle_in({dup, text()}, state)
      assert %{"type" => "ack_result"} = decode(ack2)

      unchanged = Repo.get!(ActionRun, run.id)
      assert unchanged.status == :success
      assert unchanged.exit_code == 0
    end

    test "a result for an unknown request_id is acked and remembered", %{state: state} do
      request_id = "req_0000000000000000000000"
      frame_in = result_frame(request_id, "success", [])
      assert {:push, ack, state} = RunnerSocket.handle_in({frame_in, text()}, state)
      assert %{"type" => "ack_result", "request_id" => ^request_id} = decode(ack)

      # Remembered: a retry of the same unknown id is deduped (still acked,
      # never re-attempts the unknown-request lookup/log).
      assert {:push, _ack, ^state} = RunnerSocket.handle_in({frame_in, text()}, state)
    end

    test "noncanonical correlated IDs close without retention or reflection", %{state: state} do
      request_id = "req_" <> String.duplicate("x", 100_000)

      for msg <- [
            %{"type" => "action_result", "request_id" => request_id, "status" => "success"},
            %{
              "type" => "action_progress",
              "request_id" => request_id,
              "seq" => 1,
              "stream" => "stdout",
              "chunk" => "x"
            },
            %{"type" => "error", "request_id" => request_id, "code" => "x", "message" => "x"}
          ] do
        assert {:stop, :normal, {1002, _reason}, ^state} =
                 RunnerSocket.handle_in({runner_frame(msg), text()}, state)
      end
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

      assert Repo.get!(ActionRun, run.id).status == :success

      late = result_frame(run.request_id, "error", exit_code: 1)
      assert {:push, ack, _state} = RunnerSocket.handle_in({late, text()}, state)
      assert %{"type" => "ack_result"} = decode(ack)

      # H1: terminal status + result fields are unchanged; no overwrite.
      final = Repo.get!(ActionRun, run.id)
      assert final.status == :success
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
      raw = runner_frame(%{"type" => "heartbeat", "action_load" => 9})
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

  describe "handle_info/2 — delivery, drain, catch-all" do
    setup [:connected_socket]

    test "cloud_to_runner is pushed with the protocol version stamped", %{state: state} do
      msg = %{"type" => "run_action", "request_id" => "req_push"}

      assert {:push, frame, ^state} =
               RunnerSocket.handle_info(
                 {:cloud_to_runner, state.connection_generation, msg},
                 state
               )

      assert decode(frame) == %{
               "type" => "run_action",
               "request_id" => "req_push",
               "protocol_version" => 1
             }
    end

    test "cloud_to_runner for another connection generation is dropped", %{state: state} do
      msg = %{"type" => "run_action", "request_id" => "req_wrong_generation"}

      assert {:ok, ^state} =
               RunnerSocket.handle_info(
                 {:cloud_to_runner, state.connection_generation + 1, msg},
                 state
               )
    end

    test "drain pushes a shutdown envelope first, then stops", %{state: state} do
      assert {:push, frame, ^state} = RunnerSocket.handle_info(:runner_socket_drain, state)

      assert %{"type" => "shutdown", "reason" => "cloud_shutdown"} = decode(frame)

      # The stop is deferred behind the frame (this process IS the socket).
      assert_receive :stop_after_drain
      assert {:stop, :normal, ^state} = RunnerSocket.handle_info(:stop_after_drain, state)
    end

    test "an unexpected message is logged and ignored", %{state: state} do
      assert {:ok, ^state} = RunnerSocket.handle_info({:stray, make_ref()}, state)
    end
  end

  describe "terminate/2" do
    setup [:connected_socket]

    test "stamps the disconnect on the runner row", %{state: state, runner: runner} do
      assert :ok = RunnerSocket.terminate(:remote, state)

      reloaded = Repo.reload!(runner)
      assert reloaded.last_disconnected_at
    end
  end

  describe "handle_in/2 — runner_state, action_progress, error envelopes" do
    setup [:connected_socket]

    test "runner_state refreshes the runner row from the payload", %{
      state: state,
      runner: runner
    } do
      raw =
        runner_frame(%{
          "type" => "runner_state",
          "hostname" => "renamed-host",
          "version" => "0.9.9",
          "labels" => %{"env" => "prod"},
          "packs" => %{},
          "actions" => []
        })

      assert {:ok, _state} = RunnerSocket.handle_in({raw, text()}, state)

      reloaded = Repo.reload!(runner)
      assert reloaded.hostname == "renamed-host"
      assert reloaded.runner_version == "0.9.9"
    end

    test "a socket whose runner row vanished is fenced before state mutation", %{state: state} do
      gone = %{state | runner_id: Ecto.UUID.generate()}
      raw = runner_frame(%{"type" => "runner_state", "packs" => %{}, "actions" => []})

      assert {:stop, :normal, {1008, "Runner connection ownership was superseded."}, ^gone} =
               RunnerSocket.handle_in({raw, text()}, gone)
    end

    test "runner_state rechecks lease ownership inside its mutations", %{
      state: state,
      runner: runner
    } do
      Runner
      |> Repo.get!(state.runner_id)
      |> Ecto.Changeset.change(connection_lease_id: Ecto.UUID.generate())
      |> Repo.update!()

      assert {:error, :connection_superseded} =
               Catalog.observe_state_from_connection(
                 state.runner_id,
                 %{"hostname" => "must-not-land", "packs" => %{}, "actions" => []},
                 state.connection_generation,
                 state.connection_lease_id
               )

      assert Repo.reload!(runner).hostname != "must-not-land"
    end

    test "a superseded socket is fenced before an outbound dispatch is written", %{state: state} do
      Runner
      |> Repo.get!(state.runner_id)
      |> Ecto.Changeset.change(connection_lease_id: Ecto.UUID.generate())
      |> Repo.update!()

      msg = %{"type" => "run_action", "request_id" => "req_stale"}

      assert {:stop, :normal, {1008, "Runner connection ownership was superseded."}, ^state} =
               RunnerSocket.handle_info(
                 {:cloud_to_runner, state.connection_generation, msg},
                 state
               )
    end

    test "error envelope is audited without dropping the socket", %{state: state} do
      request_id = Emisar.Crypto.run_request_id()

      raw =
        runner_frame(%{
          "type" => "error",
          "code" => "exec_failed",
          "message" => "binary not found",
          "request_id" => request_id
        })

      assert {:ok, ^state} = RunnerSocket.handle_in({raw, text()}, state)
    end
  end

  describe "handle_in/2 — action_started" do
    setup [:connected_socket, :dispatched_run]

    test "marks a quiet accepted run as running and tolerates a duplicate", %{
      state: state,
      run: run
    } do
      raw = runner_frame(%{"type" => "action_started", "request_id" => run.request_id})

      assert {:ok, ^state} = RunnerSocket.handle_in({raw, text()}, state)

      started = Repo.get!(ActionRun, run.id)
      assert started.status == :running
      assert %DateTime{} = started.started_at

      assert {:ok, ^state} = RunnerSocket.handle_in({raw, text()}, state)
      assert Repo.get!(ActionRun, run.id).started_at == started.started_at
    end

    test "requires a canonical request id", %{state: state} do
      raw = runner_frame(%{"type" => "action_started"})

      assert {:stop, :normal, {1002, "Invalid action_started request_id."}, ^state} =
               RunnerSocket.handle_in({raw, text()}, state)
    end
  end

  describe "handle_in/2 — action_progress" do
    setup [:connected_socket, :dispatched_run]

    test "appends a progress event to the run", %{state: state, run: run} do
      raw =
        runner_frame(%{
          "type" => "action_progress",
          "request_id" => run.request_id,
          "seq" => 1,
          "stream" => "stdout",
          "chunk" => "hello world\n"
        })

      assert {:ok, ^state} = RunnerSocket.handle_in({raw, text()}, state)

      events =
        Emisar.Runs.RunEvent.Query.all()
        |> Emisar.Runs.RunEvent.Query.by_run_id(run.id)
        |> Repo.all()

      progress = Enum.find(events, &(&1.kind == :progress))
      assert progress.payload["chunk"] == "hello world\n"
      assert progress.payload["stream"] == "stdout"
    end

    test "progress and results recheck lease ownership in their transactions", %{
      state: state,
      run: run
    } do
      Runner
      |> Repo.get!(state.runner_id)
      |> Ecto.Changeset.change(connection_lease_id: Ecto.UUID.generate())
      |> Repo.update!()

      assert {:error, :connection_superseded} =
               Runs.mark_started_from_connection(
                 state.account_id,
                 state.runner_id,
                 state.connection_generation,
                 state.connection_lease_id,
                 run.request_id
               )

      assert {:error, :connection_superseded} =
               Runs.append_event_from_connection(
                 run.id,
                 %{kind: "progress", seq: 1, payload: %{"chunk" => "must-not-land"}},
                 state.account_id,
                 state.runner_id,
                 state.connection_generation,
                 state.connection_lease_id
               )

      assert {:error, :connection_superseded} =
               Runs.finalize_from_connection(
                 state.account_id,
                 state.runner_id,
                 state.connection_generation,
                 state.connection_lease_id,
                 %{"request_id" => run.request_id, "status" => "success"}
               )

      reloaded = Repo.get!(ActionRun, run.id)
      assert reloaded.status == :sent
      assert reloaded.progress_event_count == 0
    end

    test "progress for an unknown request_id is swallowed", %{state: state} do
      request_id = Emisar.Crypto.run_request_id()

      raw =
        runner_frame(%{
          "type" => "action_progress",
          "request_id" => request_id,
          "seq" => 1,
          "stream" => "stdout",
          "chunk" => "x"
        })

      assert {:ok, ^state} = RunnerSocket.handle_in({raw, text()}, state)
    end

    test "progress with a nil request_id closes as a protocol error", %{state: state} do
      raw = runner_frame(%{"type" => "action_progress", "seq" => 1, "chunk" => "x"})

      assert {:stop, :normal, {1002, "Invalid action_progress request_id."}, ^state} =
               RunnerSocket.handle_in({raw, text()}, state)
    end

    # the historical fix: `chunk`/`stream` are persisted
    # NESTED under `payload` (what `action_run_events` stores), never top-level
    # where Ecto silently dropped them. Guards against that regression.
    test "the chunk/stream land under payload, not as top-level event fields", %{
      state: state,
      run: run
    } do
      raw =
        runner_frame(%{
          "type" => "action_progress",
          "request_id" => run.request_id,
          "seq" => 7,
          "stream" => "stderr",
          "chunk" => "boom\n"
        })

      assert {:ok, ^state} = RunnerSocket.handle_in({raw, text()}, state)

      progress =
        Emisar.Runs.RunEvent.Query.all()
        |> Emisar.Runs.RunEvent.Query.by_run_id(run.id)
        |> Repo.all()
        |> Enum.find(&(&1.kind == :progress))

      assert progress.payload == %{"chunk" => "boom\n", "stream" => "stderr"}
      # The seq/stream the schema persists at top level are populated; the
      # chunk is ONLY inside payload.
      assert progress.seq == 7
      refute Map.has_key?(progress.payload, "seq")
    end
  end

  # The runner socket is the hostile-input boundary: a runner is authenticated
  # but UNTRUSTED. These prove a runner can only ever touch its OWN account's
  # runs/state — even another runner in the SAME account is out of reach —
  # which is the security contract `*_for_runner` scoping exists to keep.
  describe "handle_in/2 — cross-runner scoping (same-account, untrusted runner)" do
    setup [:connected_socket, :dispatched_run]

    # (same-account branch) — runner B, sharing A's account,
    # cannot append a progress chunk to A's run: `fetch_run_id` scopes by the
    # authenticated socket's runner_id, so B's frame finds no run and is dropped.
    test "runner B can't write progress against runner A's run", %{
      account: account,
      run: run
    } do
      runner_b = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {_raw, token_b} = Runners.mint_runner_token(runner_b)
      {:ok, state_b} = RunnerSocket.init(%{token: token_b, runner: runner_b})

      raw =
        runner_frame(%{
          "type" => "action_progress",
          "request_id" => run.request_id,
          "seq" => 1,
          "stream" => "stdout",
          "chunk" => "stolen\n"
        })

      assert {:ok, ^state_b} = RunnerSocket.handle_in({raw, text()}, state_b)

      # A's run gained no progress event from B's frame.
      events =
        Emisar.Runs.RunEvent.Query.all()
        |> Emisar.Runs.RunEvent.Query.by_run_id(run.id)
        |> Repo.all()

      refute Enum.any?(events, &(&1.kind == :progress))
    end

    # (same-account branch) — runner B can't
    # finalize A's run: `finalize_from_result` is runner-scoped, so to B the
    # request_id is unknown → acked + remembered (terminal), and A's run stays
    # un-finalized (still :sent).
    test "runner B finalizing runner A's run is treated as unknown (acked, A untouched)", %{
      account: account,
      run: run
    } do
      runner_b = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {_raw, token_b} = Runners.mint_runner_token(runner_b)
      {:ok, state_b} = RunnerSocket.init(%{token: token_b, runner: runner_b})

      frame_in = result_frame(run.request_id, "success", exit_code: 0)
      assert {:push, ack, state_b2} = RunnerSocket.handle_in({frame_in, text()}, state_b)
      assert %{"type" => "ack_result", "request_id" => acked} = decode(ack)
      assert acked == run.request_id

      # A's run was NOT finalized by B — still sent, no exit_code.
      a_run = Repo.get!(ActionRun, run.id)
      assert a_run.status == :sent
      assert is_nil(a_run.exit_code)

      # And B remembered it: a retry of the same (to B, unknown) id is deduped.
      assert {:push, _ack, ^state_b2} = RunnerSocket.handle_in({frame_in, text()}, state_b2)
    end
  end

  describe "handle_in/2 — action_result, unknown/foreign request_id" do
    setup [:connected_socket]

    # a result for a request_id with no matching run is
    # genuinely terminal: acked AND remembered so a retry never re-runs the
    # unknown-request lookup/log. (The same-account scoping variant is above.)
    test "an unknown request_id is acked and remembered (no reprocess on retry)", %{state: state} do
      request_id = "req_1111111111111111111111"
      frame_in = result_frame(request_id, "success", exit_code: 0)

      assert {:push, ack, state} = RunnerSocket.handle_in({frame_in, text()}, state)
      assert %{"type" => "ack_result", "request_id" => ^request_id} = decode(ack)

      assert {:push, _ack, ^state} = RunnerSocket.handle_in({frame_in, text()}, state)
    end
  end

  describe "handle_in/2 — runner_state ingress (catalog observe)" do
    setup [:connected_socket]

    # a valid runner_state advertising packs +
    # actions syncs the catalog (the runner's catalog rows appear) and is scoped
    # to THIS socket's runner by construction (the handler passes
    # `state.runner_id`, never a runner id from the wire), so a runner can only
    # ever observe its own catalog.
    test "a valid runner_state advertises packs/actions into THIS runner's catalog", %{
      state: state,
      runner: runner
    } do
      raw =
        runner_frame(%{
          "type" => "runner_state",
          "packs" => %{"linux" => %{"version" => "1.0.0", "hash" => "sha256:deadbeef"}},
          "actions" => [
            %{"id" => "linux.df", "pack_id" => "linux", "risk" => "low", "kind" => "exec"}
          ]
        })

      assert {:ok, _state} = RunnerSocket.handle_in({raw, text()}, state)

      # The advertised action was observed against this runner (and only this
      # runner — the handler never reads a runner id from the payload).
      observed =
        Emisar.Catalog.RunnerAction.Query.all()
        |> Emisar.Catalog.RunnerAction.Query.by_runner_id(runner.id)
        |> Repo.all()

      assert Enum.any?(observed, &(&1.action_id == "linux.df"))
    end

    # (IL-14) — advertised pack/action names are runner input
    # and must never be turned into atoms (atom table never GCs → DoS). A
    # never-before-seen, otherwise-valid name is accepted and persisted as a
    # STRING; it does not exist as an atom afterward.
    test "an advertised action name is never coerced to an atom (IL-14)", %{state: state} do
      novel = "linux.nonexistent_action_#{System.unique_integer([:positive])}"

      raw =
        runner_frame(%{
          "type" => "runner_state",
          "packs" => %{"linux" => %{"version" => "1.0.0", "hash" => "sha256:abc"}},
          "actions" => [
            %{"id" => novel, "pack_id" => "linux", "risk" => "low", "kind" => "exec"}
          ]
        })

      assert {:ok, _state} = RunnerSocket.handle_in({raw, text()}, state)

      # The name round-tripped as data — it must NOT have minted a new atom.
      assert_raise ArgumentError, fn -> String.to_existing_atom(novel) end
    end

    # runner_state is a REFRESH path, not the connect path:
    # `connect_runner` already fired at init, so the runner is online before any
    # runner_state arrives, and stays online across one.
    test "runner_state is a refresh — the runner is already online before it arrives", %{
      account: account,
      state: state,
      runner: runner
    } do
      assert Runners.online?(account.id, runner.id)

      raw = runner_frame(%{"type" => "runner_state", "packs" => %{}, "actions" => []})
      assert {:ok, _state} = RunnerSocket.handle_in({raw, text()}, state)

      assert Runners.online?(account.id, runner.id)
    end
  end

  describe "handle_in/2 — heartbeat resilience + scoping" do
    setup [:connected_socket]

    # a garbage (here: nil) action_load is carried into
    # ephemeral presence metadata as-is (ENG-003 trusts the runner-declared
    # load); the handler never crashes on it. A nil keeps the prior value.
    test "a heartbeat with a missing action_load is carried as-is, no crash", %{
      state: state,
      runner: runner
    } do
      # Seed a known load first…
      first = runner_frame(%{"type" => "heartbeat", "action_load" => 5})
      assert {:ok, state} = RunnerSocket.handle_in({first, text()}, state)

      # …then a heartbeat with NO action_load field — the `|| meta.action_load`
      # fallback keeps the prior value; nothing raises.
      bare = runner_frame(%{"type" => "heartbeat"})
      assert {:ok, _state} = RunnerSocket.handle_in({bare, text()}, state)

      assert %{metas: [meta | _]} =
               Runners.connection_metas(runner.account_id) |> Map.fetch!(runner.id)

      assert meta.action_load == 5
    end

    # heartbeat is scoped to the authenticated socket's
    # OWN account/runner: it updates only this runner's presence meta, never
    # another runner sharing the account. The handler reads
    # `state.account_id`/`state.runner_id` only.
    test "a heartbeat updates only THIS runner's presence, not a same-account peer", %{
      account: account,
      state: state,
      runner: runner
    } do
      peer = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)

      raw = runner_frame(%{"type" => "heartbeat", "action_load" => 11})
      assert {:ok, _state} = RunnerSocket.handle_in({raw, text()}, state)

      metas = Runners.connection_metas(account.id)
      assert %{metas: [mine | _]} = Map.fetch!(metas, runner.id)
      assert mine.action_load == 11

      # The peer's meta is untouched by this runner's heartbeat.
      assert %{metas: [peer_meta | _]} = Map.fetch!(metas, peer.id)
      refute peer_meta.action_load == 11
    end
  end

  describe "handle_in/2 — error envelope audit" do
    setup [:connected_socket]

    # an `error` envelope writes a
    # runner.error audit row AND that row carries the runner's CONNECT
    # request_context (the IP/UA captured at socket init), which is the only
    # place that connect metadata is allowed to surface.
    test "an error envelope records a runner.error audit row stamped with the connect IP/UA",
         %{account: account, state: state, user: user} do
      # Avoid re-running the socket connect path in this already-connected test
      # process; connect would double-track this runner in Presence. The error
      # envelope only needs the request context carried on state.
      context =
        RequestContext.new(%{ip_address: "203.0.113.7", user_agent: "emisar-runner/9.9.9"})

      state = %{state | request_context: context}
      request_id = Emisar.Crypto.run_request_id()

      raw =
        runner_frame(%{
          "type" => "error",
          "code" => "exec_failed",
          "message" => "binary not found",
          "request_id" => request_id
        })

      assert {:ok, ^state} = RunnerSocket.handle_in({raw, text()}, state)

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      {:ok, events, _meta} = Emisar.Audit.list_events(subject, target_id: state.runner_id)

      row = Enum.find(events, &(&1.event_type == "runner.error"))
      assert row, "expected a runner.error audit row"
      assert row.payload["code"] == "exec_failed"
      assert row.payload["message"] == "binary not found"
      assert row.payload["request_id"] == request_id
      # The connect IP/UA rides the runner's own lifecycle event.
      assert row.ip_address == "203.0.113.7"
      assert row.user_agent == "emisar-runner/9.9.9"
    end

    # an error envelope missing code/message still records
    # the row; the absent fields are carried into the payload as nil rather than
    # dropping the audit.
    test "an error envelope missing code/message still records a row (nils carried)", %{
      account: account,
      runner: runner,
      user: user,
      state: state
    } do
      request_id = Emisar.Crypto.run_request_id()
      raw = runner_frame(%{"type" => "error", "request_id" => request_id})
      assert {:ok, ^state} = RunnerSocket.handle_in({raw, text()}, state)

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      {:ok, events, _meta} = Emisar.Audit.list_events(subject, target_id: runner.id)

      row =
        Enum.find(events, fn e ->
          e.event_type == "runner.error" and e.payload["request_id"] == request_id
        end)

      assert row, "expected a runner.error audit row even with missing fields"
      assert row.payload["code"] == nil
      assert row.payload["message"] == nil
    end
  end

  # Egress: the protocol version is stamped at the SOCKET boundary, not in the
  # domain layer — the context builds a version-free envelope and the socket
  # adds `protocol_version: 1` on every frame it pushes. These pin that seam so
  # a runner always sees a version-tagged frame regardless of type.
  describe "handle_in/2 + handle_info/2 — protocol_version stamped at egress" do
    setup [:connected_socket, :dispatched_run]

    # the cloud→runner envelope as the CONTEXT builds it
    # carries no protocol_version; the socket adds it on push. Same delivery
    # path a dispatched run_action takes.
    test "a context-built cloud_to_runner envelope gains protocol_version only at egress", %{
      state: state
    } do
      # As built by the context (Runs.deliver_run_action) — no protocol_version.
      context_msg = %{"type" => "run_action", "request_id" => "req_egress"}
      refute Map.has_key?(context_msg, "protocol_version")

      assert {:push, frame, ^state} =
               RunnerSocket.handle_info(
                 {:cloud_to_runner, state.connection_generation, context_msg},
                 state
               )

      pushed = decode(frame)
      assert pushed["protocol_version"] == 1
      assert pushed["type"] == "run_action"
      assert pushed["request_id"] == "req_egress"
    end

    # all three socket-pushed frame types stamp
    # protocol_version: 1 at egress: ack_result (on a result), error (on a bad
    # envelope), and shutdown (on drain).
    test "ack_result, error, and shutdown frames all carry protocol_version: 1", %{
      state: state,
      run: run
    } do
      # ack_result — finalize a real run.
      result = result_frame(run.request_id, "success", exit_code: 0)
      assert {:push, ack, _state} = RunnerSocket.handle_in({result, text()}, state)
      assert %{"type" => "ack_result", "protocol_version" => 1} = decode(ack)

      # error — a malformed envelope.
      assert {:push, err, ^state} = RunnerSocket.handle_in({"{bad", text()}, state)
      assert %{"type" => "error", "protocol_version" => 1} = decode(err)

      # shutdown — a drain broadcast.
      assert {:push, shut, ^state} = RunnerSocket.handle_info(:runner_socket_drain, state)
      assert %{"type" => "shutdown", "protocol_version" => 1} = decode(shut)
      assert_receive :stop_after_drain
    end
  end

  describe "normalize_ip/1" do
    test "strips the unknown sentinel, passes real strings, rejects junk" do
      assert RunnerSocket.normalize_ip("unknown") == nil
      assert RunnerSocket.normalize_ip("203.0.113.9") == "203.0.113.9"
      assert RunnerSocket.normalize_ip({203, 0, 113, 9}) == nil
    end

    test "strips the ::ffff: IPv4-mapped wrapper, matching the browser paths" do
      assert RunnerSocket.normalize_ip("::ffff:192.0.2.5") == "192.0.2.5"
    end
  end

  # -- Test seam setup + helpers --------------------------------------

  # Brings the socket up through the real production init path: this test
  # process *becomes* the runner socket (tracked in presence + subscribed
  # to its cloud→runner topic), exactly like the end-to-end tests above.
  defp connected_socket(_ctx) do
    {:ok, user} =
      Emisar.Users.register_user(%{
        email: "owner-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, account} =
      Emisar.Accounts.create_account_with_owner(
        %{name: "OwnerCo", slug: Emisar.Accounts.suggest_unique_slug("OwnerCo")},
        user
      )

    # Team plan (via a subscription) so registration isn't capped at free's
    # 3-runner limit; plan lives on the subscription now.
    Fixtures.Accounts.create_subscription(account, "team")

    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    _ = Fixtures.Catalog.create_action(runner: runner)
    _ = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
    {_raw, token} = Runners.mint_runner_token(runner)

    {:ok, state} = RunnerSocket.init(%{token: token, runner: runner})
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

    %{account: account, user: user, runner: runner, state: state, subject: subject}
  end

  # Dispatches a real run to the connected runner and drains the resulting
  # run_action envelope off this process's mailbox so later assert_receive
  # calls aren't confused by it. Leaves the run in "sent".
  defp dispatched_run(%{account: account, runner: runner, subject: subject}) do
    {:ok, :running, run} = Runs.dispatch_run(dispatch_attrs(account, runner), subject)
    assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 1_000
    %{run: run}
  end

  defp text, do: [opcode: :text]

  defp decode({:text, json}), do: Jason.decode!(json)

  defp result_frame(request_id, status, extra) do
    %{"type" => "action_result", "request_id" => request_id, "status" => status}
    |> Map.merge(Map.new(extra, fn {k, v} -> {to_string(k), v} end))
    |> runner_frame()
  end

  defp runner_frame(message),
    do: message |> Map.put("protocol_version", 1) |> Jason.encode!()

  defp count_terminal_audit_events(run, subject) do
    {:ok, events, _meta} = Emisar.Audit.list_events(subject, page: [limit: 200])

    Enum.count(events, fn e ->
      e.payload["run_id"] == run.id and
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
    |> Ecto.Changeset.change(queued_at: stale, status: :sent)
    |> Repo.update!()
  end
end
