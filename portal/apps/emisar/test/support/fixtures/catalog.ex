defmodule Emisar.Fixtures.Catalog do
  @moduledoc """
  Catalog action test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Catalog.create_action/1`.
  """

  alias Emisar.{Catalog, Repo}

  @doc """
  Inserts a catalog action row for a runner. Mirrors what
  `Catalog.observe_state` would do when a runner advertises this action.
  Defaults to `action_id: "linux.uptime"`, `risk: "low"`, `kind: "exec"`.
  """
  def create_action(attrs \\ %{}) do
    attrs = Map.new(attrs)
    runner = attrs[:runner] || raise ":runner is required"

    params = %{
      account_id: runner.account_id,
      runner_id: runner.id,
      action_id: attrs[:action_id] || "linux.uptime",
      pack_id: attrs[:pack_id] || "linux-core",
      title: attrs[:title] || "Uptime",
      kind: attrs[:kind] || "exec",
      risk: attrs[:risk] || "low",
      description: attrs[:description] || "Reports uptime + load.",
      side_effects: attrs[:side_effects] || ["reads /proc"],
      args_schema: attrs[:args_schema] || %{"args" => []},
      limits: attrs[:limits] || %{},
      output: attrs[:output] || %{},
      examples: attrs[:examples] || [],
      first_seen_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now()
    }

    {:ok, action} =
      Catalog.RunnerAction.Changeset.upsert(params)
      |> Repo.insert()

    action
  end
end
