defmodule Emisar.Catalog do
  @moduledoc """
  Pack and action observation. Every time an runner advertises
  `agent_state`, we upsert pack versions and per-runner action rows so
  the UI and MCP tool list can answer "what can this runner do?"
  without re-reading the runner's column.
  """

  import Ecto.Query
  alias Emisar.Repo
  alias Emisar.Runners.Runner
  alias Emisar.Catalog.{RunnerAction, PackVersion}

  @doc """
  Observe the full `agent_state` payload: upsert pack_versions and
  the runner's actions, prune actions that disappeared from the
  latest advertisement. Also applies hostname/labels/version to the
  runner row in the same transaction.
  """
  def observe_state(%Runner{} = runner, %{} = payload) do
    Repo.transaction(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      packs = payload["packs"] || %{}
      actions = payload["actions"] || []

      {:ok, runner} = Emisar.Runners.apply_state(runner, payload)

      Enum.each(packs, &observe_pack(runner.account_id, &1, now))

      seen_ids =
        actions
        |> Enum.map(&observe_action(runner, &1, now))
        |> Enum.reject(&is_nil/1)

      prune_missing_actions(runner.id, seen_ids)
      runner
    end)
  end

  def observe_state(runner_id, payload) when is_binary(runner_id) do
    case Repo.get(Runner, runner_id) do
      nil -> {:error, :unknown_agent}
      %Runner{} = runner -> observe_state(runner, payload)
    end
  end

  defp observe_pack(account_id, {pack_id, info}, now) do
    version = info["version"] || "unknown"
    hash = info["hash"]

    attrs = %{
      account_id: account_id,
      pack_id: pack_id,
      version: version,
      hash: hash,
      first_seen_at: now,
      last_seen_at: now
    }

    %PackVersion{}
    |> PackVersion.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [last_seen_at: now]],
      conflict_target: [:account_id, :pack_id, :version, :hash]
    )
  end

  defp observe_action(%Runner{} = runner, descriptor, now) do
    attrs = %{
      account_id: runner.account_id,
      runner_id: runner.id,
      action_id: descriptor["id"],
      pack_id: descriptor["pack_id"],
      title: descriptor["title"] || descriptor["id"],
      kind: descriptor["kind"] || "exec",
      risk: descriptor["risk"] || "low",
      description: descriptor["description"],
      side_effects: descriptor["side_effects"] || [],
      args_schema: %{"args" => descriptor["args"] || []},
      limits: descriptor["limits"] || %{},
      output: descriptor["output"] || %{},
      examples: descriptor["examples"] || [],
      first_seen_at: now,
      last_seen_at: now
    }

    case Repo.get_by(RunnerAction, runner_id: runner.id, action_id: descriptor["id"]) do
      nil ->
        case %RunnerAction{} |> RunnerAction.changeset(attrs) |> Repo.insert() do
          {:ok, %RunnerAction{action_id: id}} -> id
          {:error, _} -> nil
        end

      %RunnerAction{} = existing ->
        existing
        |> RunnerAction.changeset(Map.delete(attrs, :first_seen_at))
        |> Repo.update()
        |> case do
          {:ok, %RunnerAction{action_id: id}} -> id
          _ -> nil
        end
    end
  end

  defp prune_missing_actions(_runner_id, []), do: :ok

  defp prune_missing_actions(runner_id, seen_action_ids) do
    Repo.delete_all(
      from a in RunnerAction,
        where: a.runner_id == ^runner_id and a.action_id not in ^seen_action_ids
    )
  end

  def list_actions_for_agent(runner_id) do
    from(a in RunnerAction, where: a.runner_id == ^runner_id, order_by: a.action_id)
    |> Repo.all()
  end

  def list_actions_for_account(account_id, opts \\ []) do
    query =
      from a in RunnerAction,
        where: a.account_id == ^account_id,
        order_by: [a.action_id, a.last_seen_at]

    query =
      if risk = opts[:risk] do
        where(query, [a], a.risk == ^risk)
      else
        query
      end

    Repo.all(query)
  end

  def get_action(account_id, runner_id, action_id) do
    Repo.get_by(RunnerAction, account_id: account_id, runner_id: runner_id, action_id: action_id)
  end

  def list_pack_versions(account_id) do
    from(p in PackVersion,
      where: p.account_id == ^account_id,
      order_by: [p.pack_id, p.version]
    )
    |> Repo.all()
  end
end
