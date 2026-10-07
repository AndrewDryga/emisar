defmodule Emisar.Catalog.ConsoleAvailabilityTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Catalog, Fixtures, Repo, Runners}
  alias Emisar.Catalog.{PackVersion, RunnerAction}

  @hash "sha256:7d808108fe995fbb94f0c44396a2df00f6bae257b1cccef204193063660d59c6"
  @denied ~w(tfc.apply_run tfc.discard_run tfc.cancel_run tfc.retry_run tfc.force_unlock_workspace)

  setup do
    {_owner, account, subject} = Fixtures.Subjects.owner_subject()
    runner = Fixtures.Runners.create_runner(account_id: account.id, name: "admin-a")
    %{account: account, subject: subject, runner: runner}
  end

  defp advertise(runner, opts \\ []) do
    manifest = Catalog.PackBaseline.manifest("hcp-terraform", "0.8.9", @hash)
    denied = Keyword.get(opts, :denied, @denied)

    actions =
      Enum.map(manifest["actions"], fn {id, descriptor} ->
        descriptor
        |> Map.put("id", id)
        |> Map.put("pack_id", "hcp-terraform")
        |> Map.put("args", descriptor["args_schema"]["args"])
        |> Map.put("admission_allowed", id not in denied)
        |> Map.put("primary_executable_available", true)
      end)

    {:ok, _} =
      Catalog.observe_state(runner, %{
        "hostname" => runner.hostname,
        "group" => runner.group,
        "version" => "0.9.0",
        "labels" => %{},
        "packs" => %{"hcp-terraform" => %{"version" => "0.8.9", "hash" => @hash}},
        "actions" => actions
      })
  end

  defp contents(subject) do
    {:ok, [version], _} = Catalog.list_pack_versions(subject)
    {:ok, by_id} = Catalog.list_console_pack_actions([version.id], subject)
    {version, Map.new(by_id[version.id], &{&1.action_id, &1})}
  end

  describe "list_console_pack_actions/2" do
    test "all fifteen trusted HCP actions remain visible with independent local admission", %{
      runner: runner,
      subject: subject
    } do
      advertise(runner)
      {version, actions} = contents(subject)
      assert map_size(actions) == 15

      for id <- @denied do
        assert actions[id].availability.status == :unavailable
        assert actions[id].availability.reason =~ "Local admission"
        assert [%{id: id, status: :admission_denied}] = actions[id].availability.runners
        assert id == runner.id
      end

      assert actions["tfc.plan_summary"].availability.status == :available
      assert {:ok, projection} = Catalog.list_console_packs(%{name: "tfc.apply_run"}, subject)
      assert MapSet.member?(projection.matched_action_ids[version.id], "tfc.apply_run")

      assert projection.version_facts[version.id].reporting.runners == [
               %{id: runner.id, name: "admin-a", group: "default"}
             ]
    end

    test "a missing sibling advertisement is integrity mismatch, not admission denial", %{
      runner: runner,
      subject: subject
    } do
      advertise(runner)

      Repo.delete_all(
        from a in RunnerAction,
          where: a.runner_id == ^runner.id and a.action_id == "tfc.apply_run"
      )

      {version, actions} = contents(subject)
      assert map_size(actions) == 15
      assert actions["tfc.apply_run"].availability.reason =~ "complete trusted manifest"
      assert actions["tfc.plan_summary"].availability.status == :unavailable
      assert {:ok, filtered} = Catalog.list_console_packs(%{name: "tfc.apply_run"}, subject)
      assert MapSet.member?(filtered.matched_action_ids[version.id], "tfc.apply_run")
    end

    test "a second admitted runner enables an action without hiding the first denial", %{
      runner: runner,
      subject: subject,
      account: account
    } do
      advertise(runner)
      second = Fixtures.Runners.create_runner(account_id: account.id, name: "admin-b")
      advertise(second, denied: [])
      {_version, actions} = contents(subject)
      availability = actions["tfc.apply_run"].availability
      assert availability.status == :available

      assert Enum.map(availability.runners, &{&1.name, &1.status}) == [
               {"admin-a", :admission_denied},
               {"admin-b", :available}
             ]
    end

    test "readiness distinguishes missing executable, disabled and disconnected reporters", %{
      runner: runner,
      subject: subject,
      account: account
    } do
      advertise(runner, denied: [])

      Repo.update_all(
        from(a in RunnerAction,
          where: a.runner_id == ^runner.id and a.action_id == "tfc.plan_summary"
        ),
        set: [primary_executable_available: false]
      )

      {_version, actions} = contents(subject)
      assert actions["tfc.plan_summary"].availability.reason =~ "Primary executable"
      assert {:ok, _} = Runners.disable_runner(runner, subject)
      {_version, disabled} = contents(subject)
      assert disabled["tfc.plan_summary"].availability.reason =~ "disabled"
      assert {:ok, _} = Runners.enable_runner(Repo.reload!(runner), subject)
      Runners.Presence.untrack(self(), Runners.Presence.topic(account.id), runner.id)
      {_version, offline} = contents(subject)
      assert offline["tfc.plan_summary"].availability.reason =~ "connected"
      assert {:ok, projection} = Catalog.list_console_packs(%{}, subject)
      assert hd(Map.values(projection.version_facts)).reporting.runners != []
    end

    test "unknown admission is qualified without changing rolling-compatible authority", %{
      runner: runner,
      subject: subject
    } do
      advertise(runner, denied: [])

      Repo.update_all(from(a in RunnerAction, where: a.runner_id == ^runner.id),
        set: [admission_allowed: nil]
      )

      {_version, actions} = contents(subject)
      assert actions["tfc.plan_summary"].availability.status == :available
      assert actions["tfc.plan_summary"].availability.reason =~ "Admission not reported"
    end

    test "inventory stays visible outside execution scope and without fleet permission", %{
      runner: runner,
      subject: subject
    } do
      advertise(runner, denied: [])

      subject =
        subject.actor
        |> Fixtures.Memberships.force_role("admin")
        |> Fixtures.Subjects.subject_for()

      {:ok, none} = Accounts.RunnerAccess.new(:restricted, ["elsewhere"], [], :all, [])
      Fixtures.Memberships.force_runner_access(subject.actor, none)
      {_version, actions} = contents(subject)
      assert actions["tfc.plan_summary"].availability.reason =~ "execution access"
      assert {:ok, projection} = Catalog.list_console_packs(%{}, subject)
      assert hd(Map.values(projection.version_facts)).reporting.runners != []

      no_fleet = %{
        subject
        | permissions:
            MapSet.delete(subject.permissions, Runners.Authorizer.view_runners_permission())
      }

      assert {:ok, projection} = Catalog.list_console_packs(%{}, no_fleet)

      assert hd(Map.values(projection.version_facts)).reporting == %{
               coverage: :unavailable,
               runners: [],
               other_hash_runners: []
             }

      {_version, actions} = contents(no_fleet)
      assert actions["tfc.plan_summary"].availability.status == :unknown
    end

    test "batch reads are bounded, account isolated and partial absence is unknown", %{
      runner: runner,
      subject: subject,
      account: account
    } do
      advertise(runner)
      {version, _} = contents(subject)
      foreign = Fixtures.Accounts.create_account()

      foreign_version =
        Repo.insert!(%PackVersion{
          account_id: foreign.id,
          pack_id: "secret",
          version: "1.0",
          hash: @hash,
          first_seen_at: DateTime.utc_now(),
          last_seen_at: DateTime.utc_now()
        })

      assert {:ok, %{}} = Catalog.list_console_pack_actions([foreign_version.id], subject)

      assert Catalog.list_console_pack_actions([version.id], %{
               subject
               | permissions: MapSet.new()
             }) == {:error, :unauthorized}

      for n <- 1..101 do
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "aaa-#{n}",
          connected?: false
        )
      end

      {_version, actions} = contents(subject)
      assert actions["tfc.plan_summary"].availability.status == :unknown
      assert actions["tfc.plan_summary"].availability.coverage == :partial
      assert {:ok, projection} = Catalog.list_console_packs(%{}, subject)
      assert hd(Map.values(projection.version_facts)).reporting.coverage == :partial
    end

    test "multiple opened versions share the same bounded evidence queries", %{
      runner: runner,
      subject: subject,
      account: account
    } do
      advertise(runner)
      {version, _} = contents(subject)

      other =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: "another-pack",
          version: "1.0",
          trusted_manifest: version.trusted_manifest
        )

      test_pid = self()
      handler = make_ref()

      :telemetry.attach(
        handler,
        [:emisar, :repo, :query],
        fn _, _, _, _ ->
          if self() == test_pid, do: send(test_pid, :pack_query)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      assert {:ok, _} = Catalog.list_console_pack_actions([version.id], subject)
      one = query_count()
      assert {:ok, results} = Catalog.list_console_pack_actions([version.id, other.id], subject)
      assert Map.keys(results) |> Enum.sort() == Enum.sort([version.id, other.id])
      assert query_count() == one
    end

    test "an incomplete trusted manifest is not an empty or advertised fallback", %{
      runner: runner,
      subject: subject
    } do
      advertise(runner)
      {version, _} = contents(subject)
      version |> Ecto.Changeset.change(trusted_manifest: nil) |> Repo.update!()
      assert {:ok, %{}} = Catalog.list_console_pack_actions([], subject)
      assert {:ok, results} = Catalog.list_console_pack_actions([version.id], subject)
      assert results[version.id] == :incomplete_manifest
    end

    test "retirement and missing dispatch authority remain definite under partial fleet evidence",
         %{runner: runner, subject: subject, account: account} do
      advertise(runner)
      {version, _} = contents(subject)

      for n <- 1..101 do
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "aaa-#{n}",
          connected?: false
        )
      end

      {retired_id, _} = Catalog.PackBaseline.retired_below() |> Enum.sort() |> List.first()

      retired =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: retired_id,
          version: "0.0.0",
          trusted_manifest: version.trusted_manifest
        )

      assert {:ok, results} = Catalog.list_console_pack_actions([retired.id], subject)

      assert Enum.all?(
               results[retired.id],
               &(&1.availability.status == :unavailable and &1.availability.reason =~ "retired")
             )

      no_dispatch = %{
        subject
        | permissions:
            MapSet.delete(subject.permissions, Emisar.Runs.Authorizer.dispatch_run_permission())
      }

      assert {:ok, results} = Catalog.list_console_pack_actions([version.id], no_dispatch)

      assert Enum.all?(
               results[version.id],
               &(&1.availability.status == :unavailable and
                   &1.availability.reason =~ "execution access")
             )
    end
  end

  defp query_count(count \\ 0) do
    receive do
      :pack_query -> query_count(count + 1)
    after
      0 -> count
    end
  end
end
