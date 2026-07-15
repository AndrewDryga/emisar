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
    |> apply_validation(validation_map(arg["validation"]))
  end

  defp base_type("string"), do: %{type: "string"}
  defp base_type("integer"), do: %{type: "integer"}
  defp base_type("number"), do: %{type: "number"}
  defp base_type("boolean"), do: %{type: "boolean"}
  defp base_type("duration"), do: %{type: "string", pattern: "^[0-9]+(ns|us|ms|s|m|h)$"}
  defp base_type("string_array"), do: %{type: "array", items: %{type: "string"}}
  defp base_type("integer_array"), do: %{type: "array", items: %{type: "integer"}}
  # Unknown / missing — widen to string so the schema stays a valid
  # 2020-12 document. The runner catches misuse with its stricter spec.
  defp base_type(_), do: %{type: "string"}

  defp apply_validation(map, %{} = v) do
    map
    |> put_if_present(:enum, validation_list(v["enum"] || v["allowed"]))
    |> put_if_present(:pattern, validation_string(v["pattern"]))
    |> put_if_present(:minimum, validation_number(v["min"]))
    |> put_if_present(:maximum, validation_number(v["max"]))
    |> put_if_present(:minItems, validation_count(v["min_items"]))
    |> put_if_present(:maxItems, validation_count(v["max_items"]))
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
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
