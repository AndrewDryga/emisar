defmodule EmisarWeb.MCP.ToolMetadata do
  @moduledoc false

  @oauth2_mcp [%{type: "oauth2", scopes: ["mcp"]}]
  @risk_rank %{low: 0, medium: 1, high: 2, critical: 3}

  def auth_required(%{} = tool) do
    meta =
      tool
      |> Map.get(:_meta, %{})
      |> Map.put(:securitySchemes, @oauth2_mcp)

    tool
    |> Map.put(:securitySchemes, @oauth2_mcp)
    |> Map.put(:_meta, meta)
  end

  def read_only_annotations do
    %{
      readOnlyHint: true,
      destructiveHint: false,
      openWorldHint: false,
      idempotentHint: true
    }
  end

  # Executing a published runbook fans out real infrastructure actions — open
  # world (it touches systems beyond the portal), risk-bearing (a step may
  # mutate/destroy), and never a safe replay (each call is a fresh execution).
  def execute_runbook_annotations do
    %{
      readOnlyHint: false,
      destructiveHint: true,
      openWorldHint: true,
      idempotentHint: false
    }
  end

  # Drafting a runbook writes only portal state (a draft row) and never runs
  # anything, so it isn't destructive or open-world — but it's a write, and a
  # second call creates a second draft, so it's neither read-only nor idempotent.
  def draft_runbook_annotations do
    %{
      readOnlyHint: false,
      destructiveHint: false,
      openWorldHint: false,
      idempotentHint: false
    }
  end

  def action_annotations(action) do
    read_only? = action.risk == :low and Enum.empty?(action.side_effects || [])

    %{
      readOnlyHint: read_only?,
      destructiveHint: action.risk in [:high, :critical],
      openWorldHint: true,
      idempotentHint: read_only?
    }
  end

  # Two runners can advertise the SAME action_id from different pack
  # versions with different risk or side effects. The one tool descriptor
  # must never understate danger: annotate the group at its worst case —
  # read-only only if EVERY variant is read-only, destructive if ANY
  # variant is high/critical. Describing the group off an arbitrary first
  # row would let a critical variant ride under a read-only hint.
  def group_annotations([_ | _] = actions) do
    side_effects = Enum.flat_map(actions, &(&1.side_effects || []))
    action_annotations(%{risk: worst_risk(actions), side_effects: side_effects})
  end

  # The highest risk any variant in the group advertises.
  def worst_risk([_ | _] = actions),
    do: Enum.max_by(actions, &Map.fetch!(@risk_rank, &1.risk)).risk

  # The MCP display `title` for the grouped tool — a stable, human-readable
  # name independent of runner ordering. Variants of one action_id normally
  # share a title; if they diverge we pick deterministically (sorted) so
  # tools/list stays byte-stable, falling back to the action_id.
  def group_title([%{action_id: action_id} | _] = actions) do
    titles =
      actions
      |> Enum.map(&Map.get(&1, :title))
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.sort()

    List.first(titles) || action_id
  end
end
