defmodule Emisar.CatalogTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Catalog
  alias Emisar.Catalog.{RunnerAction, PackVersion}

  defp state_payload(opts) do
    %{
      "hostname" => Keyword.get(opts, :hostname, "host-1"),
      "version" => Keyword.get(opts, :version, "0.1.0"),
      "labels" => Keyword.get(opts, :labels, %{"env" => "test"}),
      "packs" => Keyword.get(opts, :packs, %{}),
      "actions" => Keyword.get(opts, :actions, [])
    }
  end

  defp action(id, opts \\ []) do
    %{
      "id" => id,
      "pack_id" => Keyword.get(opts, :pack_id, "demo"),
      "title" => Keyword.get(opts, :title, id),
      "kind" => Keyword.get(opts, :kind, "exec"),
      "risk" => Keyword.get(opts, :risk, "low"),
      "description" => Keyword.get(opts, :description, "test"),
      "args" => Keyword.get(opts, :args, [])
    }
  end

  describe "observe_state/2 — packs" do
    test "upserts pack_versions" do
      runner = runner_fixture()

      payload =
        state_payload(packs: %{"linux-core" => %{"version" => "1.0", "hash" => "abc"}})

      assert {:ok, _agent} = Catalog.observe_state(runner, payload)

      assert [%PackVersion{pack_id: "linux-core", version: "1.0", hash: "abc"}] =
               Catalog.list_pack_versions(runner.account_id)

      # Idempotent — same payload should not duplicate.
      assert {:ok, _agent} = Catalog.observe_state(runner, payload)
      assert length(Catalog.list_pack_versions(runner.account_id)) == 1
    end
  end

  describe "observe_state/2 — actions" do
    test "upserts runner_actions" do
      runner = runner_fixture()

      payload =
        state_payload(actions: [action("linux.uptime"), action("linux.df", risk: "medium")])

      assert {:ok, _agent} = Catalog.observe_state(runner, payload)

      actions = Catalog.list_actions_for_agent(runner.id)
      assert length(actions) == 2
      assert Enum.any?(actions, &(&1.action_id == "linux.uptime" and &1.risk == "low"))
      assert Enum.any?(actions, &(&1.action_id == "linux.df" and &1.risk == "medium"))
    end

    test "prunes actions no longer advertised" do
      runner = runner_fixture()

      _ =
        Catalog.observe_state(runner, state_payload(actions: [action("a"), action("b"), action("c")]))

      assert length(Catalog.list_actions_for_agent(runner.id)) == 3

      _ = Catalog.observe_state(runner, state_payload(actions: [action("a")]))

      assert [%RunnerAction{action_id: "a"}] = Catalog.list_actions_for_agent(runner.id)
    end

    test "updates the runner row's hostname/labels/version" do
      runner = runner_fixture()

      _ =
        Catalog.observe_state(
          runner,
          state_payload(hostname: "new-host", version: "0.2.0", labels: %{"env" => "prod"})
        )

      reloaded = Repo.reload!(runner)
      assert reloaded.hostname == "new-host"
      assert reloaded.runner_version == "0.2.0"
      assert reloaded.labels == %{"env" => "prod"}
    end
  end

  describe "observe_state/2 — runner_id variant" do
    test "looks up the runner by id" do
      runner = runner_fixture()

      assert {:ok, _agent} = Catalog.observe_state(runner.id, state_payload(actions: [action("a")]))
      assert [%RunnerAction{action_id: "a"}] = Catalog.list_actions_for_agent(runner.id)
    end

    test "returns {:error, :unknown_agent} for an unknown id" do
      assert {:error, :unknown_agent} = Catalog.observe_state(Ecto.UUID.generate(), %{})
    end
  end
end
