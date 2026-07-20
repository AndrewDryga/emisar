defmodule EmisarWeb.MCPContractAssertions do
  @moduledoc false

  import ExUnit.Assertions
  alias EmisarWeb.MCP.SchemaRegistry

  @schemas Map.new(SchemaRegistry.contracts(), fn contract ->
             {:ok, schema} = JSONSchex.compile(contract["outputSchema"], format_assertion: true)
             {contract["name"], schema}
           end)

  def assert_valid_tool_result(tool, result) when is_binary(tool) and is_map(result) do
    schema = Map.fetch!(@schemas, tool)

    case JSONSchex.validate(schema, result) do
      :ok ->
        result

      {:error, reason} ->
        flunk(
          "#{tool} returned a value outside its output schema:\n#{inspect(reason, pretty: true)}\n\n#{Jason.encode!(result, pretty: true)}"
        )
    end
  end
end
