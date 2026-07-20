defmodule EmisarWeb.MCP.InputContract do
  @moduledoc """
  Compiles and enforces the fixed tools' published input schemas.

  JSONSchex owns standard Draft 2020-12 validation; byte budgets that schemas
  cannot express are enforced by the tool handlers. This module additionally
  normalizes integral JSON numbers at the top-level fields the schemas declare
  as `integer`, so handlers receive real integers from clients that send `50.0`.
  """

  alias EmisarWeb.MCP.{SchemaRegistry, ValidationError}
  alias EmisarWeb.MCP.SchemaRegistry.Compiler

  @contracts Map.new(SchemaRegistry.contracts(), fn descriptor ->
               schema = Map.fetch!(descriptor, "inputSchema")
               expanded = Compiler.expand!(schema, schema)

               compiled =
                 case JSONSchex.compile(schema, format_assertion: true) do
                   {:ok, compiled} -> compiled
                   {:error, error} -> raise "invalid MCP input schema: #{inspect(error)}"
                 end

               root_properties = Compiler.root_properties(expanded)

               integer_fields =
                 root_properties
                 |> Enum.filter(fn {_name, child} -> child["type"] == "integer" end)
                 |> Enum.map(fn {name, _child} -> name end)

               root_fields = root_properties |> Map.keys() |> MapSet.new()

               {Map.fetch!(descriptor, "name"),
                %{compiled: compiled, integer_fields: integer_fields, root_fields: root_fields}}
             end)

  @doc "Validate one decoded tools/call arguments value against its published contract."
  @spec validate(String.t(), term()) :: {:ok, map()} | {:error, [ValidationError.issue()]}
  def validate(tool, arguments) when is_binary(tool) do
    case Map.fetch(@contracts, tool) do
      {:ok, %{compiled: compiled, integer_fields: integer_fields}} ->
        with :ok <- validate_schema(compiled, arguments) do
          {:ok, normalize_integers(arguments, integer_fields)}
        end

      :error ->
        {:error, [ValidationError.issue([], :schema)]}
    end
  end

  def validate(_tool, _arguments), do: {:error, [ValidationError.issue([], :schema)]}

  @doc "The published root argument names of one fixed tool, for safe log paths."
  @spec known_root_fields(String.t()) :: MapSet.t()
  def known_root_fields(tool) do
    case Map.fetch(@contracts, tool) do
      {:ok, %{root_fields: root_fields}} -> root_fields
      :error -> MapSet.new()
    end
  end

  defp validate_schema(compiled, arguments) do
    case JSONSchex.validate(compiled, arguments) do
      :ok ->
        :ok

      {:error, errors} ->
        issues =
          errors
          |> prefer_concrete_errors()
          |> Enum.sort_by(&error_priority(&1.rule))
          |> Enum.flat_map(&error_issues/1)
          |> Enum.uniq()
          |> Enum.take(8)

        {:error, issues}
    end
  end

  # JSONSchex accepts integral floats for `"type": "integer"` (Draft 2020-12
  # numeric equality), so a schema-valid `50.0` still reaches the handlers.
  defp normalize_integers(arguments, integer_fields) when is_map(arguments) do
    Enum.reduce(integer_fields, arguments, fn field, normalized ->
      case normalized do
        %{^field => value} when is_float(value) -> Map.put(normalized, field, trunc(value))
        _other -> normalized
      end
    end)
  end

  defp normalize_integers(arguments, _integer_fields), do: arguments

  defp error_priority(rule) when rule in [:required, :type], do: 0
  defp error_priority(:boolean_schema), do: 1
  defp error_priority(rule) when rule in [:pattern, :format, :enum, :const], do: 2

  defp error_priority(rule)
       when rule in [:minimum, :maximum, :exclusiveMinimum, :exclusiveMaximum], do: 3

  defp error_priority(rule) when rule in [:minLength, :maxLength, :minItems, :maxItems], do: 4
  defp error_priority(:uniqueItems), do: 5
  defp error_priority(_rule), do: 9

  defp prefer_concrete_errors(errors) do
    concrete = Enum.reject(errors, &(&1.rule in [:allOf, :anyOf, :oneOf, :not]))
    if concrete == [], do: errors, else: concrete
  end

  defp error_issues(%{rule: :required, path: path, context: %{contrast: fields}})
       when is_list(fields) do
    path = safe_path(path)
    Enum.map(fields, &ValidationError.issue(path ++ [&1], :required))
  end

  defp error_issues(error),
    do: [ValidationError.issue(safe_path(error.path), issue_code(error.rule))]

  defp safe_path(path), do: path |> Enum.reverse() |> Enum.reject(&is_integer/1)

  defp issue_code(:required), do: :required
  defp issue_code(:boolean_schema), do: :unknown
  defp issue_code(:type), do: :type
  defp issue_code(rule) when rule in [:pattern, :format], do: :format
  defp issue_code(rule) when rule in [:minimum, :exclusiveMinimum], do: :min
  defp issue_code(rule) when rule in [:maximum, :exclusiveMaximum], do: :max
  defp issue_code(:minLength), do: :min
  defp issue_code(:maxLength), do: :max_length
  defp issue_code(:minItems), do: :min
  defp issue_code(:maxItems), do: :max_items
  defp issue_code(:uniqueItems), do: :unique
  defp issue_code(:enum), do: :enum
  defp issue_code(rule) when rule in [:not, :oneOf], do: :conflict
  defp issue_code(_rule), do: :schema
end
