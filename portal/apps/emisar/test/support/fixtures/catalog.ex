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
      pack_version: attrs[:pack_version],
      title: attrs[:title] || "Uptime",
      kind: attrs[:kind] || "exec",
      risk: attrs[:risk] || "low",
      description: attrs[:description] || "Reports uptime + load.",
      side_effects: attrs[:side_effects] || ["reads /proc"],
      args_schema: attrs[:args_schema] || %{"args" => []},
      examples: attrs[:examples] || [],
      first_seen_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now()
    }

    {:ok, action} =
      Catalog.RunnerAction.Changeset.upsert(params)
      |> Repo.insert()

    action
  end

  @doc """
  Inserts a TRUSTED pack version row directly — the shape a version trusted
  under an older release has after a newer release raises the pack's
  retirement watermark: trusted, retired, and NO override stamp.
  `Catalog.trust_pack_version/2` cannot build this state (trusting an
  already-retired version stamps the override), so retirement UI paths
  arrange it here. Defaults to `pack_id: "acme-tools"`, `version: "9.9"`.
  """
  def create_trusted_pack_version(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || raise ":account_id is required"
    now = DateTime.utc_now()

    params = %{
      account_id: account_id,
      pack_id: attrs[:pack_id] || "acme-tools",
      version: attrs[:version] || "9.9",
      hash: attrs[:hash] || "sha256:trusted-fixture",
      trust_state: :trusted,
      first_seen_at: now,
      last_seen_at: now
    }

    {:ok, pack_version} =
      Catalog.PackVersion.Changeset.insert(params)
      |> Repo.insert()

    pack_version
  end
end
