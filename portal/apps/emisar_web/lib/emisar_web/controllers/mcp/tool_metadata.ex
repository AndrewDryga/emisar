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
