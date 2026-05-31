defmodule Emisar.Catalog do
  @moduledoc """
  Pack and action observation. Every time a runner advertises
  `runner_state`, we upsert pack versions and per-runner action rows
  so the UI and MCP tool list can answer "what can this runner do?"
  without re-reading the runner's column.
  """

  alias Emisar.{Auth, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runners.Runner
  alias Emisar.Catalog.{Authorizer, PackVersion, RunnerAction}

  @doc """
  Observe the full `runner_state` payload: upsert pack_versions and
  the runner's actions, prune actions that disappeared from the
  latest advertisement. Also applies hostname/labels/version to the
  runner row in the same transaction.

  Internal — called by the runner socket process which is itself
  authenticated by the runner token. Not exposed to LV/MCP.
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
    case Emisar.Runners.peek_runner_by_id(runner_id) do
      {:ok, %Runner{} = runner} -> observe_state(runner, payload)
      {:error, :not_found} -> {:error, :unknown_runner}
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

    PackVersion.Changeset.upsert(attrs)
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

    existing =
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_account_runner_and_action(
        runner.account_id,
        runner.id,
        descriptor["id"]
      )
      |> Repo.peek()

    case existing do
      nil ->
        case RunnerAction.Changeset.upsert(attrs) |> Repo.insert() do
          {:ok, %RunnerAction{action_id: id}} -> id
          {:error, _} -> nil
        end

      %RunnerAction{} = row ->
        row
        |> Ecto.Changeset.change(Map.delete(attrs, :first_seen_at))
        |> Repo.update()
        |> case do
          {:ok, %RunnerAction{action_id: id}} -> id
          _ -> nil
        end
    end
  end

  defp prune_missing_actions(_runner_id, []), do: :ok

  defp prune_missing_actions(runner_id, seen_action_ids) do
    RunnerAction.Query.all()
    |> RunnerAction.Query.by_runner_id(runner_id)
    |> RunnerAction.Query.except_action_ids(seen_action_ids)
    |> Repo.delete_all()
  end

  @doc """
  Actions advertised by a runner, scoped to the subject's account.
  Returns `{:ok, [runner_action], %Paginator.Metadata{}}`.
  """
  def list_actions_for_runner(runner_id, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_runner_id(runner_id)
      |> RunnerAction.Query.ordered_by_action()
      |> Authorizer.for_subject(subject)
      |> Repo.list(RunnerAction.Query, opts)
    end
  end

  def list_actions_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      {risk, opts} = Keyword.pop(opts, :risk)

      RunnerAction.Query.all()
      |> RunnerAction.Query.ordered_by_action_seen()
      |> apply_risk_filter(risk)
      |> Authorizer.for_subject(subject)
      |> Repo.list(RunnerAction.Query, opts)
    end
  end

  defp apply_risk_filter(query, nil), do: query
  defp apply_risk_filter(query, risk), do: RunnerAction.Query.by_risk(query, risk)

  @doc """
  Lookup a single catalog action row by (runner, action_id) scoped to
  the subject's account. Used by `Runs.dispatch_run` (Subject already in
  scope) and by `RunNewLive` (operator-driven dispatch form).
  """
  def fetch_action_by_id(action_id, runner_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      RunnerAction.Query.all()
      |> RunnerAction.Query.by_runner_id(runner_id)
      |> RunnerAction.Query.by_action_id(action_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(RunnerAction.Query)
    end
  end

  def list_pack_versions(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_catalog_permission()
           ) do
      PackVersion.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list(PackVersion.Query, opts)
    end
  end
end
