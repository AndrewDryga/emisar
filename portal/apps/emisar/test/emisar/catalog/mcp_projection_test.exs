defmodule Emisar.Catalog.MCPProjectionTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.{MCPProjection, PackBaseline, PackVersion, RunnerAction, TrustedManifest}
  alias Emisar.Runners.Runner

  @hash "sha256:" <> String.duplicate("a", 64)
  @other_hash "sha256:" <> String.duplicate("b", 64)

  test "projects only exact trusted complete non-retired pack refs" do
    {trusted, action, runner} = deployment("custom", "1.0.0", @hash)

    assert [%{pack_ref: "custom@1.0.0/#{@hash}", availability: "executable"}] =
             MCPProjection.build([trusted], [action], [runner]).packs

    hidden_cases = [
      {:pending, [%{trusted | trust_state: :pending}], action, runner},
      {:rejected, [%{trusted | trust_state: :rejected}], action, runner},
      {:missing, [], action, runner},
      {:incomplete_manifest, [%{trusted | trusted_manifest: nil}], action, runner},
      {:hash_mismatch, [trusted], %{action | pack_hash: @other_hash},
       runner_with_pack(runner, "custom", "1.0.0", @other_hash)}
    ]

    Enum.each(hidden_cases, fn {state, pack_versions, advertised_action, advertised_runner} ->
      snapshot =
        MCPProjection.build(pack_versions, [advertised_action], [advertised_runner])

      assert snapshot.packs == [], "expected #{state} pack to remain hidden"
      assert [%{issues: []}] = snapshot.runners
    end)
  end

  test "retirement hides a trusted ref until an operator override exists" do
    {pack_id, _watermark} =
      Enum.find(PackBaseline.retired_below(), fn {id, _watermark} ->
        PackBaseline.retired?(id, "0.0.0")
      end)

    {trusted, action, runner} = deployment(pack_id, "0.0.0", @hash)
    assert MCPProjection.build([trusted], [action], [runner]).packs == []

    overridden = %{trusted | retirement_overridden_at: DateTime.utc_now()}

    assert [%{pack_id: ^pack_id, availability: "executable"}] =
             MCPProjection.build([overridden], [action], [runner]).packs
  end

  test "a hidden version does not disclose itself through version skew" do
    {trusted, trusted_action, trusted_runner} = deployment("custom", "1.0.0", @hash)
    {pending, pending_action, pending_runner} = deployment("custom", "2.0.0", @other_hash)
    pending = %{pending | trust_state: :pending}

    snapshot =
      MCPProjection.build(
        [trusted, pending],
        [trusted_action, pending_action],
        [trusted_runner, pending_runner]
      )

    assert [%{pack_ref: "custom@1.0.0/#{@hash}", issues: issues}] = snapshot.packs
    refute Enum.any?(issues, &(&1.code == "version_skew"))
  end

  defp deployment(pack_id, version, hash) do
    runner_id = Ecto.UUID.generate()

    action = %RunnerAction{
      account_id: Ecto.UUID.generate(),
      runner_id: runner_id,
      action_id: "custom.read",
      pack_id: pack_id,
      pack_version: version,
      pack_hash: hash,
      title: "Read custom state",
      summary: "Reads custom state.",
      kind: :exec,
      risk: :low,
      description: "Reads custom state.",
      side_effects: [],
      args_schema: %{"args" => []},
      examples: [],
      search_terms: []
    }

    {:ok, manifest} = TrustedManifest.from_runner_actions([action])

    pack_version = %PackVersion{
      account_id: action.account_id,
      pack_id: pack_id,
      version: version,
      hash: hash,
      trust_state: :trusted,
      trusted_manifest: manifest
    }

    runner = %Runner{
      id: runner_id,
      account_id: action.account_id,
      name: "runner-#{String.slice(runner_id, 0, 8)}",
      external_id: Ecto.UUID.generate(),
      hostname: "fixture-host",
      group: "default",
      labels: %{},
      packs: %{},
      degraded_packs: [],
      online?: true,
      enforce_signatures: false
    }

    {pack_version, action, runner_with_pack(runner, pack_id, version, hash)}
  end

  defp runner_with_pack(runner, pack_id, version, hash) do
    %{runner | packs: %{pack_id => %{"version" => version, "hash" => hash}}}
  end
end
