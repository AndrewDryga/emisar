defmodule EmisarWeb.MCP.SchemaRegistry.Compiler do
  @moduledoc false

  @descriptor_fields ~w(annotations description inputSchema outputSchema title)

  @spec compile!(Path.t(), [String.t()]) :: [map()]
  # The production caller passes the compile-known @schema_path derived from
  # __DIR__; no request input reaches this file read.
  # sobelow_skip ["Traversal.FileModule"]
  def compile!(path, expected_names) do
    registry = path |> File.read!() |> Jason.decode!()

    unless registry["schema_version"] == 1 do
      raise ArgumentError,
            "MCP schema registry #{path} has unsupported schema_version #{inspect(registry["schema_version"])}"
    end

    tools = Map.fetch!(registry, "tools")
    actual_names = tools |> Map.keys() |> Enum.sort()

    unless actual_names == Enum.sort(expected_names) and
             map_size(tools) == length(expected_names) do
      raise ArgumentError,
            "MCP schema registry tool set mismatch: expected #{inspect(expected_names)}, got #{inspect(actual_names)}"
    end

    Enum.map(expected_names, fn name ->
      descriptor = Map.fetch!(tools, name)
      fields = descriptor |> Map.keys() |> Enum.sort()

      unless fields == @descriptor_fields do
        raise ArgumentError,
              "MCP schema registry descriptor #{inspect(name)} has fields #{inspect(fields)}; expected #{inspect(@descriptor_fields)}"
      end

      descriptor
      |> resolve!(registry)
      |> Map.put("name", name)
    end)
  end

  @spec resolve!(term(), map()) :: term()
  def resolve!(value, registry), do: resolve(value, registry, [])

  defp resolve(%{"$ref" => ref} = value, registry, stack) when is_binary(ref) do
    if ref in stack do
      chain = [ref | stack] |> Enum.reverse() |> Enum.join(" -> ")
      raise ArgumentError, "cyclic MCP schema reference: #{chain}"
    end

    target = registry |> resolve_pointer!(ref) |> resolve(registry, [ref | stack])
    siblings = value |> Map.delete("$ref") |> resolve(registry, stack)

    merge_reference(target, siblings, ref)
  end

  defp resolve(%{"$ref" => ref}, _registry, _stack) do
    raise ArgumentError, "MCP schema reference must be a string: #{inspect(ref)}"
  end

  defp resolve(%{} = value, registry, stack) do
    Map.new(value, fn {key, child} -> {key, resolve(child, registry, stack)} end)
  end

  defp resolve(value, registry, stack) when is_list(value) do
    Enum.map(value, &resolve(&1, registry, stack))
  end

  defp resolve(value, _registry, _stack), do: value

  defp merge_reference(target, siblings, _ref) when map_size(siblings) == 0, do: target

  defp merge_reference(target, siblings, _ref) when is_map(target) do
    if Map.keys(target) |> Enum.any?(&Map.has_key?(siblings, &1)) do
      %{"allOf" => [target, siblings]}
    else
      Map.merge(target, siblings)
    end
  end

  defp merge_reference(_target, _siblings, ref) do
    raise ArgumentError,
          "MCP schema reference #{inspect(ref)} has siblings but targets a non-object"
  end

  defp resolve_pointer!(registry, "#"), do: registry

  defp resolve_pointer!(registry, "#/" <> pointer = ref) do
    pointer
    |> String.split("/", trim: false)
    |> Enum.map(&decode_pointer_token!(&1, ref))
    |> Enum.reduce(registry, fn token, value -> fetch_pointer_token!(value, token, ref) end)
  end

  defp resolve_pointer!(_registry, ref) do
    raise ArgumentError, "MCP schema reference must be internal: #{inspect(ref)}"
  end

  defp decode_pointer_token!(token, ref) do
    if Regex.match?(~r/~(?:[^01]|$)/, token) do
      raise ArgumentError, "invalid JSON pointer escape in MCP schema reference #{inspect(ref)}"
    end

    token
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  defp fetch_pointer_token!(%{} = value, token, ref) do
    case Map.fetch(value, token) do
      {:ok, child} -> child
      :error -> raise ArgumentError, "unresolved MCP schema reference #{inspect(ref)}"
    end
  end

  defp fetch_pointer_token!(value, token, ref) when is_list(value) do
    with {index, ""} when index >= 0 <- Integer.parse(token),
         {:ok, child} <- Enum.fetch(value, index) do
      child
    else
      _ -> raise ArgumentError, "unresolved MCP schema reference #{inspect(ref)}"
    end
  end

  defp fetch_pointer_token!(_value, _token, ref) do
    raise ArgumentError, "unresolved MCP schema reference #{inspect(ref)}"
  end
end

defmodule EmisarWeb.MCP.SchemaRegistry do
  @moduledoc """
  The fixed MCP tool catalog compiled from the normative schema registry.

  Internal JSON Schema references are resolved at compile time so every tool
  descriptor is self-contained on the wire.
  """

  alias EmisarWeb.MCP.SchemaRegistry.Compiler

  @tool_names ~w(
    list_packs
    list_runners
    find_actions
    get_action
    run_action
    get_operation
    wait_for_run
    recent_runs
    list_runbooks
    get_runbook
    execute_runbook
    create_runbook_draft
  )

  @schema_path Path.expand("../../../../../../../docs/mcp-api-schemas.json", __DIR__)
  @external_resource @schema_path
  @contracts Compiler.compile!(@schema_path, @tool_names)
  @tools Enum.map(@contracts, &Map.delete(&1, "outputSchema"))

  @spec tools() :: [map()]
  def tools, do: @tools

  @doc "Returns the complete internal descriptors, including response schemas."
  @spec contracts() :: [map()]
  def contracts, do: @contracts

  @spec tool_names() :: [String.t()]
  def tool_names, do: @tool_names
end
