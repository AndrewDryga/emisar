defmodule Emisar.Catalog.ActionSetDiff do
  @moduledoc """
  Pure diff of a pack version's advertised action set against the
  `trusted_manifest` snapshotted when an operator last trusted that hash.

  `Catalog.trust_pack_version/2` stores the manifest — a
  versioned, complete descriptor manifest at trust time. When the same
  `(pack_id, version)` later re-advertises a NEW hash and flips to `:pending`,
  `changes/2` shows actions added, removed, or changed across every
  execution/model-facing field. Risk escalation remains explicit because it
  is the operator UI's headline danger.

  Both inputs are already account-authorized by the caller (the page loads the
  `%PackVersion{}` and its `%RunnerAction{}` rows through Subject-gated reads),
  so this stays a pure transform — no Repo, no Subject.
  """
  alias Emisar.Catalog.{RunnerAction, TrustedManifest}

  @risk_rank %{"low" => 0, "medium" => 1, "high" => 2, "critical" => 3}

  @type entry :: %{action_id: String.t(), risk: String.t(), kind: String.t()}
  @type changed :: %{
          action_id: String.t(),
          old_risk: String.t(),
          new_risk: String.t(),
          old_kind: String.t(),
          new_kind: String.t(),
          changed_fields: [String.t()],
          risk_escalated?: boolean()
        }
  @type t :: %{added: [entry], removed: [entry], changed: [changed]}

  @doc """
  A complete versioned manifest built from already-fetched `%RunnerAction{}`
  rows. Trust mutations use `TrustedManifest.from_runner_actions/1` directly
  so malformed or conflicting duplicate descriptors abort the transaction;
  this convenience function returns an empty complete manifest on invalid
  input for the read-only operator diff fallback.
  """
  @spec manifest_from_actions([RunnerAction.t()]) :: %{optional(String.t()) => map()}
  def manifest_from_actions(actions) when is_list(actions) do
    case TrustedManifest.from_runner_actions(actions) do
      {:ok, manifest} -> manifest
      {:error, :invalid_manifest} -> %{"schema_version" => 1, "actions" => %{}}
    end
  end

  @doc """
  Diff the currently-advertised `%RunnerAction{}` rows against a stored complete
  manifest. A nil, sparse, malformed, or conflicting manifest yields an empty
  diff so the UI falls back to listing the advertised actions.

  Returns `%{added: [...], removed: [...], changed: [...]}`, each list sorted by
  `action_id`. `changed` carries old+new risk/kind and a `risk_escalated?` flag
  (e.g. low→critical) — the headline danger.
  """
  @spec changes([RunnerAction.t()], map() | nil) :: t()
  def changes(advertised, manifest) when is_list(advertised) and is_map(manifest) do
    with {:ok, trusted_actions} <- TrustedManifest.actions(manifest),
         {:ok, advertised_manifest} <- TrustedManifest.from_runner_actions(advertised),
         {:ok, advertised_actions} <- TrustedManifest.actions(advertised_manifest) do
      diff(trusted_actions, advertised_actions)
    else
      _ -> empty_diff()
    end
  end

  def changes(_advertised, _manifest), do: empty_diff()

  defp diff(trusted_actions, advertised_actions) do
    added =
      for {action_id, descriptor} <- advertised_actions,
          not Map.has_key?(trusted_actions, action_id),
          do: entry(action_id, descriptor)

    removed =
      for {action_id, descriptor} <- trusted_actions,
          not Map.has_key?(advertised_actions, action_id),
          do: entry(action_id, descriptor)

    changed =
      for {action_id, new} <- advertised_actions,
          old = Map.get(trusted_actions, action_id),
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

  defp changed(action_id, old, new) do
    %{
      action_id: action_id,
      old_risk: old["risk"],
      new_risk: new["risk"],
      old_kind: old["kind"],
      new_kind: new["kind"],
      changed_fields: Enum.filter(TrustedManifest.descriptor_fields(), &(old[&1] != new[&1])),
      risk_escalated?: risk_rank(new["risk"]) > risk_rank(old["risk"])
    }
  end

  defp empty_diff, do: %{added: [], removed: [], changed: []}

  defp risk_rank(risk), do: Map.get(@risk_rank, risk, 0)
end
