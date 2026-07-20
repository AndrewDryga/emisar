defmodule Emisar.OutputSchema do
  @moduledoc """
  Bounded validation for opt-in action output contracts (JSON Schema Draft
  2020-12). Schemas arrive inside runner-advertised descriptors — a hostile
  boundary — so shape, size, keyword, and reference limits are enforced before
  any compile, and external schema resources are always denied.
  """

  @draft2020_uri "https://json-schema.org/draft/2020-12/schema"
  @meta_cache_key {__MODULE__, :draft2020_meta_schema}
  @max_schema_nodes 512
  @max_instance_nodes 1_024
  @max_depth 16

  @doc "Whether a decoded schema is a bounded, compilable object contract."
  def valid?(%{} = schema) do
    schema["type"] == "object" and
      Emisar.JSONValue.validate(schema, max_depth: @max_depth, max_nodes: @max_schema_nodes) ==
        :ok and
      safe_profile?(schema, true) and
      local_refs_resolve?(schema) and
      compilable?(schema)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  def valid?(_schema), do: false

  @doc "Validate a decoded, bounded result object against a trusted contract."
  def validate_instance(%{} = schema, %{} = value) do
    with true <- valid?(schema),
         :ok <-
           Emisar.JSONValue.validate(value, max_depth: @max_depth, max_nodes: @max_instance_nodes),
         {:ok, compiled} <- compile(schema),
         :ok <- JSONSchex.validate(compiled, value) do
      :ok
    else
      _other -> {:error, :schema_mismatch}
    end
  rescue
    _error -> {:error, :schema_mismatch}
  catch
    _kind, _reason -> {:error, :schema_mismatch}
  end

  def validate_instance(_schema, _value), do: {:error, :schema_mismatch}

  defp compilable?(schema) do
    valid_against_meta_schema?(schema) and match?({:ok, _compiled}, compile(schema))
  end

  defp compile(schema) do
    JSONSchex.compile(schema, loader: &deny_external_resource/1, format_assertion: true)
  end

  # Conservative keyword walk: identity, dynamic-scope, and content keywords are
  # rejected anywhere in the tree, refs may only target one root-level `$defs`
  # entry, and `multipleOf` must be a positive integer so validation never
  # depends on float divisibility semantics.
  defp safe_profile?(%{} = value, root?) do
    Enum.all?(value, fn
      {"$schema", @draft2020_uri} when root? ->
        true

      {"$schema", _value} ->
        false

      {"$ref", "#/$defs/" <> token} when token != "" ->
        Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, token)

      {"$ref", _value} ->
        false

      {"multipleOf", multiple_of} ->
        is_integer(multiple_of) and multiple_of > 0

      {key, _value}
      when key in [
             "$id",
             "$anchor",
             "$dynamicAnchor",
             "$dynamicRef",
             "$recursiveRef",
             "$vocabulary",
             "definitions",
             "contentEncoding",
             "contentMediaType",
             "contentSchema"
           ] ->
        false

      {_key, child} ->
        safe_profile?(child, false)
    end)
  end

  defp safe_profile?(value, _root?) when is_list(value),
    do: Enum.all?(value, &safe_profile?(&1, false))

  defp safe_profile?(_value, _root?), do: true

  defp valid_against_meta_schema?(schema) do
    match?(:ok, JSONSchex.validate(compiled_meta_schema(), schema))
  end

  defp compiled_meta_schema do
    case :persistent_term.get(@meta_cache_key, nil) do
      nil ->
        {:ok, raw_meta_schema} = JSONSchex.Draft202012.Schemas.fetch(@draft2020_uri)
        {:ok, compiled} = JSONSchex.compile(raw_meta_schema)
        :persistent_term.put(@meta_cache_key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  # `safe_profile?/2` restricts every ref to `#/$defs/<token>`, so resolution is
  # a `$defs` key lookup, and the cycle walk guards compile-time recursion on
  # runner-supplied schemas.
  defp local_refs_resolve?(schema) do
    defs = Map.get(schema, "$defs", %{})
    refs = schema |> local_ref_tokens([]) |> Enum.uniq()

    is_map(defs) and Enum.all?(refs, &Map.has_key?(defs, &1)) and acyclic_refs?(defs, refs)
  end

  defp acyclic_refs?(defs, refs) do
    graph = Map.new(refs, fn token -> {token, local_ref_tokens(Map.get(defs, token), [])} end)

    Enum.reduce_while(refs, {:ok, %{}}, fn token, {:ok, colors} ->
      case visit_ref(token, graph, colors) do
        {:ok, next_colors} -> {:cont, {:ok, next_colors}}
        :cycle -> {:halt, :cycle}
      end
    end) != :cycle
  end

  defp visit_ref(token, graph, colors) do
    case Map.get(colors, token) do
      :done ->
        {:ok, colors}

      :visiting ->
        :cycle

      nil ->
        colors = Map.put(colors, token, :visiting)

        Map.get(graph, token, [])
        |> Enum.reduce_while({:ok, colors}, fn child, {:ok, acc} ->
          case visit_ref(child, graph, acc) do
            {:ok, next} -> {:cont, {:ok, next}}
            :cycle -> {:halt, :cycle}
          end
        end)
        |> case do
          {:ok, visited} -> {:ok, Map.put(visited, token, :done)}
          :cycle -> :cycle
        end
    end
  end

  defp local_ref_tokens(%{} = value, tokens) do
    Enum.reduce(value, tokens, fn
      {"$ref", "#/$defs/" <> token}, acc -> [token | acc]
      {_key, child}, acc -> local_ref_tokens(child, acc)
    end)
  end

  defp local_ref_tokens(value, tokens) when is_list(value),
    do: Enum.reduce(value, tokens, &local_ref_tokens/2)

  defp local_ref_tokens(_value, tokens), do: tokens

  defp deny_external_resource(_uri), do: {:error, "external schema resources are disabled"}
end
