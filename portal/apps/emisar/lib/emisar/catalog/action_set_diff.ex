defmodule Emisar.Catalog.ActionSetDiff do
  @moduledoc """
  Pure diff of a pack version's advertised action set against the
  `trusted_manifest` snapshotted when an operator last trusted that hash.

  `Catalog.trust_pack_version/2` stores the manifest — a
  `%{action_id => %{"risk" => risk, "kind" => kind}}` map (JSONB, so string
  keys/values) — at trust time. When the same `(pack_id, version)` later
  re-advertises a NEW hash and flips to `:pending`, the operator must Trust
  again, and `changes/2` shows WHAT moved: actions **added** (a re-advertised
  hash that silently adds a `critical` action is exactly the dangerous change
  to surface), **removed**, and **changed** (same action_id, escalated/altered
  risk or kind).

  Both inputs are already account-authorized by the caller (the page loads the
  `%PackVersion{}` and its `%RunnerAction{}` rows through Subject-gated reads),
  so this stays a pure transform — no Repo, no Subject.
  """
  alias Emisar.Catalog.RunnerAction

  @risk_rank %{"low" => 0, "medium" => 1, "high" => 2, "critical" => 3}

  @type entry :: %{action_id: String.t(), risk: String.t(), kind: String.t()}
  @type changed :: %{
          action_id: String.t(),
          old_risk: String.t(),
          new_risk: String.t(),
          old_kind: String.t(),
          new_kind: String.t(),
          risk_escalated?: boolean()
        }
  @type t :: %{added: [entry], removed: [entry], changed: [changed]}

  @doc """
  The `%{action_id => %{"risk" => risk, "kind" => kind}}` manifest for a pack
  version, built from its already-fetched, deduped `%RunnerAction{}` rows.
  String keys/values so it round-trips through the JSONB `trusted_manifest`
  column. Stored at trust time so a later drift can be diffed against it.
  """
  @spec manifest_from_actions([RunnerAction.t()]) :: %{optional(String.t()) => map()}
  def manifest_from_actions(actions) when is_list(actions) do
    Map.new(actions, fn %RunnerAction{action_id: action_id} = action ->
      {action_id, %{"risk" => to_string(action.risk), "kind" => to_string(action.kind)}}
    end)
  end

  @doc """
  Diff the currently-advertised `%RunnerAction{}` rows against a stored
  manifest. `nil` (or empty) manifest — a version trusted before this feature,
  or never trusted — yields an empty diff: the UI falls back to listing the
  advertised actions as it does today.

  Returns `%{added: [...], removed: [...], changed: [...]}`, each list sorted by
  `action_id`. `changed` carries old+new risk/kind and a `risk_escalated?` flag
  (e.g. low→critical) — the headline danger.
  """
  @spec changes([RunnerAction.t()], map() | nil) :: t()
  def changes(_advertised, manifest) when manifest in [nil, %{}],
    do: %{added: [], removed: [], changed: []}

  def changes(advertised, manifest) when is_list(advertised) and is_map(manifest) do
    advertised_manifest = manifest_from_actions(advertised)

    added =
      for {action_id, entry} <- advertised_manifest,
          not Map.has_key?(manifest, action_id),
          do: entry(action_id, entry)

    removed =
      for {action_id, entry} <- manifest,
          not Map.has_key?(advertised_manifest, action_id),
          do: entry(action_id, entry)

    changed =
      for {action_id, new} <- advertised_manifest,
          old = Map.get(manifest, action_id),
          not is_nil(old),
          old != new,
          do: changed(action_id, old, new)

    %{
      added: Enum.sort_by(added, & &1.action_id),
      removed: Enum.sort_by(removed, & &1.action_id),
      changed: Enum.sort_by(changed, & &1.action_id)
    }
  end

  defp entry(action_id, %{"risk" => risk, "kind" => kind}),
    do: %{action_id: action_id, risk: risk, kind: kind}

  defp changed(action_id, %{"risk" => old_risk, "kind" => old_kind}, %{
         "risk" => new_risk,
         "kind" => new_kind
       }) do
    %{
      action_id: action_id,
      old_risk: old_risk,
      new_risk: new_risk,
      old_kind: old_kind,
      new_kind: new_kind,
      risk_escalated?: risk_rank(new_risk) > risk_rank(old_risk)
    }
  end

  defp risk_rank(risk), do: Map.get(@risk_rank, risk, 0)
end
