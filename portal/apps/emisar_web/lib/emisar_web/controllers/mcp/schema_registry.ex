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
      |> Map.update!("inputSchema", &bundle!(&1, registry))
      |> Map.update!("outputSchema", &bundle!(&1, registry))
      |> Map.put("name", name)
    end)
  end

  @doc "Bundles one schema with only the registry definitions it transitively references."
  @spec bundle!(map(), map()) :: map()
  def bundle!(schema, registry) when is_map(schema) do
    case collect_definitions(schema, registry, %{}, []) do
      definitions when map_size(definitions) == 0 ->
        schema

      definitions ->
        schema
        |> Map.put("$schema", Map.fetch!(registry, "$schema"))
        |> Map.put("$defs", definitions)
    end
  end

  @doc "Expands one bundled schema for internal compile-time introspection."
  @spec expand!(term(), map()) :: term()
  def expand!(value, registry), do: expand(value, registry, [])

  @doc "Collects one expanded object schema's root properties, following allOf."
  @spec root_properties(map()) :: %{optional(String.t()) => term()}
  def root_properties(schema) when is_map(schema) do
    direct = Map.get(schema, "properties", %{})

    schema
    |> Map.get("allOf", [])
    |> Enum.reduce(direct, &Map.merge(&2, root_properties(&1)))
  end

  defp expand(%{"$ref" => ref} = value, registry, stack) when is_binary(ref) do
    if ref in stack do
      chain = [ref | stack] |> Enum.reverse() |> Enum.join(" -> ")
      raise ArgumentError, "cyclic MCP schema reference: #{chain}"
    end

    name = definition_name!(ref)
    target = registry |> fetch_definition!(name, ref) |> expand(registry, [ref | stack])
    siblings = value |> Map.delete("$ref") |> expand(registry, stack)

    merge_reference(target, siblings, ref)
  end

  defp expand(%{"$ref" => ref}, _registry, _stack), do: definition_name!(ref)

  defp expand(%{} = value, registry, stack) do
    value
    |> Map.delete("$defs")
    |> Map.delete("$schema")
    |> Map.new(fn {key, child} -> {key, expand(child, registry, stack)} end)
  end

  defp expand(value, registry, stack) when is_list(value) do
    Enum.map(value, &expand(&1, registry, stack))
  end

  defp expand(value, _registry, _stack), do: value

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

  defp collect_definitions(%{"$ref" => ref} = value, registry, definitions, stack) do
    name = definition_name!(ref)

    cond do
      ref in stack ->
        chain = [ref | stack] |> Enum.reverse() |> Enum.join(" -> ")
        raise ArgumentError, "cyclic MCP schema reference: #{chain}"

      Map.has_key?(definitions, name) ->
        collect_definitions(Map.delete(value, "$ref"), registry, definitions, stack)

      true ->
        definition = fetch_definition!(registry, name, ref)
        definitions = Map.put(definitions, name, definition)

        definitions =
          collect_definitions(definition, registry, definitions, [ref | stack])

        collect_definitions(Map.delete(value, "$ref"), registry, definitions, stack)
    end
  end

  defp collect_definitions(%{} = value, registry, definitions, stack) do
    Enum.reduce(value, definitions, fn {_key, child}, collected ->
      collect_definitions(child, registry, collected, stack)
    end)
  end

  defp collect_definitions(value, registry, definitions, stack) when is_list(value) do
    Enum.reduce(value, definitions, &collect_definitions(&1, registry, &2, stack))
  end

  defp collect_definitions(_value, _registry, definitions, _stack), do: definitions

  defp definition_name!("#/$defs/" <> encoded = ref) do
    if String.contains?(encoded, "/") do
      raise ArgumentError, "MCP schema reference must name one definition: #{inspect(ref)}"
    end

    decode_pointer_token!(encoded, ref)
  end

  defp definition_name!(ref) when is_binary(ref) do
    raise ArgumentError, "MCP schema reference must be an internal definition: #{inspect(ref)}"
  end

  defp definition_name!(ref) do
    raise ArgumentError, "MCP schema reference must be a string: #{inspect(ref)}"
  end

  defp fetch_definition!(registry, name, ref) do
    case get_in(registry, ["$defs", name]) do
      nil -> raise ArgumentError, "unresolved MCP schema reference #{inspect(ref)}"
      definition -> definition
    end
  end

  defp decode_pointer_token!(token, ref) do
    if Regex.match?(~r/~(?:[^01]|$)/, token) do
      raise ArgumentError, "invalid JSON pointer escape in MCP schema reference #{inspect(ref)}"
    end

    token
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end
end

defmodule EmisarWeb.MCP.SchemaRegistry do
  @moduledoc """
  The fixed MCP tool catalog compiled from the normative schema registry.

  Every tool schema carries only the local definitions it transitively uses, so
  descriptors stay complete and self-contained without recursively duplicating
  shared schemas.
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
  @schema_version @schema_path |> File.read!() |> Jason.decode!() |> Map.fetch!("schema_version")
  @contracts Compiler.compile!(@schema_path, @tool_names)
  @tools Enum.map(@contracts, &Map.delete(&1, "outputSchema"))

  @doc "Returns the lean wire descriptors served by tools/list."
  @spec tools() :: [map()]
  def tools, do: @tools

  @doc "Returns the complete internal descriptors, including response schemas."
  @spec contracts() :: [map()]
  def contracts, do: @contracts

  @spec tool_names() :: [String.t()]
  def tool_names, do: @tool_names

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version
end
