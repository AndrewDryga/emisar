defmodule EmisarWeb.MCP.ToolSchema do
  @moduledoc """
  Projects one trusted pack action's arguments into JSON Schema 2020-12.

  The schema helps an agent form a call; portal and runner validation remain
  authoritative. Emisar-specific argument types are widened to their JSON
  primitives while retaining declared constraints.
  """

  @doc "Builds the action-only JSON Schema exposed by `get_action`."
  @spec action_args_schema(map()) :: map()
  def action_args_schema(action) do
    args = action_args(action)
    properties = Map.new(args, &{&1["name"], arg_property(&1)})
    required = args |> Enum.filter(& &1["required"]) |> Enum.map(& &1["name"])

    schema_object(properties, required, false)
    |> Map.put("x-emisar-maxEncodedBytes", 32_768)
  end

  defp schema_object(properties, required, additional_properties?) do
    %{
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      type: "object",
      properties: properties,
      required: required,
      additionalProperties: additional_properties?
    }
  end

  defp action_args(%{args_schema: %{"args" => args}}) when is_list(args) do
    Enum.filter(args, &valid_arg?/1)
  end

  defp action_args(%{"args_schema" => %{"args" => args}}) when is_list(args) do
    Enum.filter(args, &valid_arg?/1)
  end

  defp action_args(_), do: []

  defp valid_arg?(%{"name" => name}) when is_binary(name) and name != "", do: true

  defp valid_arg?(_), do: false

  defp arg_property(arg) do
    arg["type"]
    |> base_type()
    |> put_if_present(:description, description(arg["description"]))
    |> put_if_present(:default, arg["default"])
    |> apply_validation(arg["type"], validation_map(arg["validation"]))
  end

  defp base_type("string"), do: %{type: "string"}
  defp base_type("integer"), do: %{type: "integer"}
  defp base_type("number"), do: %{type: "number"}
  defp base_type("boolean"), do: %{type: "boolean"}
  defp base_type("duration"), do: %{type: "string", format: "duration"}
  defp base_type("path"), do: %{type: "string", format: "path"}
  defp base_type("string_array"), do: %{type: "array", items: %{type: "string"}}
  defp base_type("integer_array"), do: %{type: "array", items: %{type: "integer"}}
  defp base_type(_), do: %{}

  defp apply_validation(map, type, %{} = validation)
       when type in ["string_array", "integer_array"] do
    item =
      map.items
      |> apply_scalar_validation(validation)
      |> apply_string_byte_limit(type, validation)

    map
    |> Map.put(:items, item)
    |> put_if_present(:maxItems, validation_count(validation["max_items"]))
    |> apply_path_constraints(type, validation)
  end

  defp apply_validation(map, type, %{} = validation) do
    map
    |> apply_scalar_validation(validation)
    |> apply_string_byte_limit(type, validation)
    |> apply_duration_bounds(type, validation)
    |> apply_path_constraints(type, validation)
  end

  defp apply_scalar_validation(map, validation) do
    map
    |> put_if_present(:enum, enum_values(validation))
    |> put_if_present(:pattern, validation_string(validation["pattern"]))
    |> put_if_present(:minimum, validation_number(validation["min"]))
    |> put_if_present(:maximum, validation_number(validation["max"]))
  end

  defp apply_string_byte_limit(map, type, validation)
       when type in ["string", "path", "string_array"] do
    Map.put(map, "x-emisar-maxUtf8Bytes", validation["max_length"] || 32_768)
  end

  defp apply_string_byte_limit(map, _type, _validation), do: map

  defp apply_duration_bounds(map, "duration", validation) do
    map
    |> put_if_present("x-emisar-minDuration", validation_string(validation["min_duration"]))
    |> put_if_present("x-emisar-maxDuration", validation_string(validation["max_duration"]))
  end

  defp apply_duration_bounds(map, _type, _validation), do: map

  defp apply_path_constraints(map, type, validation) when type in ["path", "string_array"] do
    constraints =
      ~w(allowed_paths denied_paths allowed_prefixes denied_prefixes)
      |> Map.new(&{&1, validation_list(validation[&1])})
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
      |> Map.new()

    put_if_present(map, "x-emisar-pathConstraints", constraints)
  end

  defp apply_path_constraints(map, _type, _validation), do: map

  defp enum_values(validation) do
    case {validation_list(validation["enum"]), validation_list(validation["allowed"])} do
      {nil, allowed} -> allowed
      {enum, nil} -> enum
      {enum, allowed} -> Enum.filter(enum, &(&1 in allowed))
    end
  end

  defp validation_map(%{} = validation), do: validation
  defp validation_map(_), do: %{}

  defp description(value) when is_binary(value), do: value
  defp description(_), do: nil

  defp validation_list(value) when is_list(value), do: value
  defp validation_list(_), do: nil

  defp validation_string(value) when is_binary(value), do: value
  defp validation_string(_), do: nil

  defp validation_number(value) when is_number(value), do: value
  defp validation_number(_), do: nil

  defp validation_count(value) when is_integer(value) and value >= 0, do: value
  defp validation_count(_), do: nil

  # Single replacement for the 4 prior `maybe_put_*` variants. Empty
  # string / empty list count as "no value", matching Emisar's
  # args_schema convention of omitting empty fields rather than
  # serialising them.
  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, _key, []), do: map
  defp put_if_present(map, _key, value) when value == %{}, do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
