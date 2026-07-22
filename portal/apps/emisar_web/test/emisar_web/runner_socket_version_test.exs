defmodule EmisarWeb.RunnerSocketVersionTest do
  # async: false — these tests flip the global Emisar.Compat enforcement flag,
  # which is VM-wide; an async file could see it mid-flip. Kept out of the main
  # runner_socket_test so that suite stays async.
  use EmisarWeb.ConnCase, async: false
  alias Emisar.{Audit, Fixtures, Runners}
  alias EmisarWeb.RunnerSocket

  # test.exs policy: < 0.0.1 unsupported, [0.0.1, 0.1.0) outdated, >= 0.1.0 supported.
  describe "handle_in/2 — runner version enforcement" do
    setup [:connected_socket]

    test "enforce on: a below-minimum version is dropped with a shutdown envelope + audit row",
         %{state: state, runner: runner, subject: subject} do
      enforce_runner_versions(true)

      assert {:push, frame, ^state} =
               RunnerSocket.handle_in({runner_state_frame("0.0.0"), text()}, state)

      assert %{
               "type" => "shutdown",
               "reason" => "runner_version_unsupported",
               "message" => message
             } =
               Jason.decode!(elem(frame, 1))

      assert message =~ "0.0.0"
      assert message =~ ">= 0.0.1"

      # It schedules its own stop so WebSock flushes the shutdown frame first.
      assert_receive :stop_after_drain

      {:ok, events, _meta} = Audit.list_events(subject, target_id: runner.id)
      row = Enum.find(events, &(&1.event_type == "runner.version_rejected"))
      assert row, "expected a runner.version_rejected audit row"
      assert row.payload["runner_version"] == "0.0.0"
      assert row.payload["minimum"] == ">= 0.0.1"
    end

    test "warn-only (enforcement off): a below-minimum version stays connected", %{state: state} do
      # Baseline test config already has runner_enforce: false.
      assert {:ok, _state} = RunnerSocket.handle_in({runner_state_frame("0.0.0"), text()}, state)
      refute_received :stop_after_drain
    end

    test "enforce on: a current version is untouched", %{state: state} do
      enforce_runner_versions(true)
      assert {:ok, _state} = RunnerSocket.handle_in({runner_state_frame("1.0.0"), text()}, state)
      refute_received :stop_after_drain
    end

    test "enforce on: a runner whose version is unparseable is never blocked (:unknown)", %{
      state: state
    } do
      enforce_runner_versions(true)
      # A git-sha / "dev" build reports a non-semver version → :unknown, which
      # enforcement must never drop (only :unsupported is blocked).
      assert {:ok, _state} =
               RunnerSocket.handle_in({runner_state_frame("dev-abc123"), text()}, state)

      refute_received :stop_after_drain
    end
  end

  defp enforce_runner_versions(enforce?) do
    previous = Emisar.Config.get_env(:emisar, Emisar.Compat)

    Emisar.Config.put_override(
      :emisar,
      Emisar.Compat,
      Keyword.put(previous, :runner_enforce, enforce?)
    )
  end

  defp runner_state_frame(version) do
    Jason.encode!(%{
      "type" => "runner_state",
      "protocol_version" => 1,
      "version" => version,
      "packs" => %{},
      "actions" => []
    })
  end

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

    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    {_raw, token} = Runners.mint_runner_token(runner)
    {:ok, state} = RunnerSocket.init(%{token: token, runner: runner})
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

    %{account: account, user: user, runner: runner, state: state, subject: subject}
  end

  defp text, do: [opcode: :text]
end
