defmodule EmisarWeb.MCP.ToolMetadata do
  @moduledoc false

  @oauth2_mcp [%{type: "oauth2", scopes: ["mcp"]}]

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
end
