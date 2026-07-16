defmodule EmisarWeb.MCP.ActionContract do
  @moduledoc """
  Validates the portable part of a trusted runner action contract.

  The runner remains authoritative for host-dependent path resolution and
  execution-time state. This boundary rejects deterministic contract failures
  before Emisar creates a run, approval, draft, or operation record.
  """

  alias EmisarWeb.MCP.RawJSON.Number

  @default_max_string_bytes 32_768
  @duration ~r/\A[+-]?(?:0|(?:(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:ns|us|µs|μs|ms|s|m|h))+)\z/u
  @duration_part ~r/([0-9]+(?:\.[0-9]*)?|\.[0-9]+)(ns|us|µs|μs|ms|s|m|h)/u
  @duration_units %{
    "ns" => 1,
    "us" => 1_000,
    "µs" => 1_000,
    "μs" => 1_000,
    "ms" => 1_000_000,
    "s" => 1_000_000_000,
    "m" => 60_000_000_000,
    "h" => 3_600_000_000_000
  }
  @min_duration_nanoseconds Decimal.new(-9_223_372_036_854_775_808)
  @max_duration_nanoseconds Decimal.new(9_223_372_036_854_775_807)

  @type issue :: %{arg: String.t(), code: String.t(), message: String.t()}

  @doc "Validate one action argument map against its trusted manifest descriptor."
  @spec validate(map(), map()) :: :ok | {:error, issue()}
  def validate(args, action) when is_map(args) and is_map(action) do
    specs = action_args(action)
    known = MapSet.new(specs, & &1["name"])
    unknown = args |> Map.keys() |> Enum.sort() |> Enum.find(&(!MapSet.member?(known, &1)))

    case unknown do
      nil -> validate_specs(specs, args)
      name -> issue(name, "unknown_arg", "unknown argument")
    end
  end

  def validate(_args, _action), do: issue("args", "type", "expected object")

  defp validate_specs(specs, args) do
    Enum.reduce_while(specs, :ok, fn spec, :ok ->
      name = spec["name"]

      case Map.fetch(args, name) do
        {:ok, value} ->
          reduce_result(validate_value(spec, value))

        :error ->
          if spec["required"] == true,
            do: reduce_result(issue(name, "required", "is required")),
            else: {:cont, :ok}
      end
    end)
  end

  defp reduce_result(:ok), do: {:cont, :ok}
  defp reduce_result({:error, _issue} = error), do: {:halt, error}

  defp validate_value(spec, value) do
    with {:ok, normalized} <- coerce(spec, value),
         :ok <- validate_string_bytes(spec, normalized) do
      validate_constraints(spec, normalized)
    end
  end

  defp coerce(%{"name" => name, "type" => type}, value) when type in ["string", "path"] do
    if is_binary(value), do: {:ok, value}, else: issue(name, "type", "expected string")
  end

  defp coerce(%{"name" => name, "type" => "integer"}, value) do
    case exact_integer(value) do
      {:ok, integer} -> {:ok, integer}
      :error -> issue(name, "type", "expected integer")
    end
  end

  defp coerce(%{"name" => name, "type" => "number"}, value) do
    case finite_float(value) do
      {:ok, number} -> {:ok, number}
      :error -> issue(name, "type", "expected number")
    end
  end

  defp coerce(%{"name" => name, "type" => "boolean"}, value) do
    if is_boolean(value), do: {:ok, value}, else: issue(name, "type", "expected boolean")
  end

  defp coerce(%{"name" => name, "type" => "duration"}, value) do
    case duration_nanoseconds(value) do
      {:ok, nanoseconds} -> {:ok, {:duration, nanoseconds}}
      :error -> issue(name, "type", "expected Go duration string")
    end
  end

  defp coerce(%{"name" => name, "type" => "string_array"}, value) do
    coerce_array(name, value, &if(is_binary(&1), do: {:ok, &1}, else: :error), "string")
  end

  defp coerce(%{"name" => name, "type" => "integer_array"}, value) do
    coerce_array(name, value, &exact_integer/1, "integer")
  end

  defp coerce(%{"name" => name}, _value), do: issue(name, "type", "unsupported argument type")

  defp coerce_array(name, value, coercer, expected) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, normalized} ->
      case coercer.(item) do
        {:ok, coerced} -> {:cont, {:ok, [coerced | normalized]}}
        :error -> {:halt, issue(name, "type", "element #{index} is not #{expected}")}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _issue} = error -> error
    end
  end

  defp coerce_array(name, _value, _coercer, expected),
    do: issue(name, "type", "expected #{expected} array")

  defp validate_string_bytes(spec, value) do
    type = spec["type"]

    if type in ["string", "path", "string_array"] do
      limit = get_in(spec, ["validation", "max_length"]) || @default_max_string_bytes
      values = if is_list(value), do: value, else: [value]

      oversized =
        values
        |> Enum.with_index()
        |> Enum.find(fn {item, _index} -> byte_size(item) > limit end)

      case oversized do
        nil ->
          :ok

        {_item, index} when is_list(value) ->
          issue(spec["name"], "max_length", "element #{index} exceeds #{limit} bytes")

        _ ->
          issue(spec["name"], "max_length", "exceeds #{limit} bytes")
      end
    else
      :ok
    end
  end

  defp validate_constraints(spec, value) do
    validation = validation(spec)

    with :ok <- validate_max_items(spec, value, validation),
         :ok <- validate_each(spec, value, validation) do
      validate_portable_paths(spec, value, validation)
    end
  end

  defp validate_max_items(%{"name" => name, "type" => type}, value, %{"max_items" => max})
       when type in ["string_array", "integer_array"] and is_integer(max) do
    if length(value) <= max, do: :ok, else: issue(name, "max_items", "has more than #{max} items")
  end

  defp validate_max_items(_spec, _value, _validation), do: :ok

  defp validate_each(%{"type" => type} = spec, value, validation)
       when type in ["string_array", "integer_array"] do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case validate_scalar(spec, item, validation) do
        :ok ->
          {:cont, :ok}

        {:error, issue} ->
          {:halt, {:error, %{issue | message: "element #{index}: #{issue.message}"}}}
      end
    end)
  end

  defp validate_each(spec, value, validation), do: validate_scalar(spec, value, validation)

  defp validate_scalar(spec, value, validation) do
    with :ok <- validate_membership(spec, value, validation, "enum"),
         :ok <- validate_membership(spec, value, validation, "allowed"),
         :ok <- validate_pattern(spec, value, validation),
         :ok <- validate_numeric_bounds(spec, value, validation) do
      validate_duration_bounds(spec, value, validation)
    end
  end

  defp validate_membership(%{"name" => name}, value, validation, key) do
    case validation[key] do
      candidates when is_list(candidates) and candidates != [] ->
        if Enum.any?(candidates, &(&1 == value)),
          do: :ok,
          else: issue(name, key, "is not an allowed value")

      _ ->
        :ok
    end
  end

  defp validate_pattern(%{"name" => name}, value, %{"pattern" => pattern})
       when is_binary(pattern) and is_binary(value) do
    case :re.compile(pattern, [:unicode, :dollar_endonly]) do
      {:ok, regex} ->
        if :re.run(value, regex, capture: :none) == :match,
          do: :ok,
          else: issue(name, "pattern", "does not match the required pattern")

      {:error, _reason} ->
        issue(name, "pattern", "trusted manifest contains an invalid pattern")
    end
  end

  defp validate_pattern(_spec, _value, _validation), do: :ok

  defp validate_numeric_bounds(%{"name" => name}, value, validation) when is_number(value) do
    cond do
      is_number(validation["min"]) and value < validation["min"] ->
        issue(name, "min", "is below the minimum")

      is_number(validation["max"]) and value > validation["max"] ->
        issue(name, "max", "is above the maximum")

      true ->
        :ok
    end
  end

  defp validate_numeric_bounds(_spec, _value, _validation), do: :ok

  defp validate_duration_bounds(%{"name" => name}, {:duration, value}, validation) do
    with :ok <- compare_duration(name, value, validation["min_duration"], :min) do
      compare_duration(name, value, validation["max_duration"], :max)
    end
  end

  defp validate_duration_bounds(_spec, _value, _validation), do: :ok

  defp compare_duration(_name, _value, nil, _bound), do: :ok

  defp compare_duration(name, value, encoded, bound) do
    case duration_nanoseconds(encoded) do
      {:ok, limit} when bound == :min ->
        if Decimal.compare(value, limit) == :lt,
          do: issue(name, "min_duration", "is below the minimum duration"),
          else: :ok

      {:ok, limit} ->
        if Decimal.compare(value, limit) == :gt,
          do: issue(name, "max_duration", "is above the maximum duration"),
          else: :ok

      :error ->
        issue(name, "duration", "trusted manifest contains an invalid duration bound")
    end
  end

  defp validate_portable_paths(%{"name" => name, "type" => type}, value, validation)
       when type in ["path", "string_array"] do
    if path_constraints?(validation) do
      values = if is_list(value), do: value, else: [value]

      if Enum.all?(values, &String.starts_with?(&1, "/")),
        do: :ok,
        else: issue(name, "path", "must be absolute when path constraints are declared")
    else
      :ok
    end
  end

  defp validate_portable_paths(_spec, _value, _validation), do: :ok

  defp path_constraints?(validation) do
    Enum.any?(~w(allowed_paths denied_paths allowed_prefixes denied_prefixes), fn key ->
      is_list(validation[key]) and validation[key] != []
    end)
  end

  defp exact_integer(%Number{raw: raw}), do: exact_integer(raw)

  defp exact_integer(value)
       when is_integer(value) and value in -9_223_372_036_854_775_808..9_223_372_036_854_775_807,
       do: {:ok, value}

  defp exact_integer(value) when is_binary(value) do
    with {decimal, ""} <- Decimal.parse(value),
         true <- Decimal.equal?(decimal, Decimal.round(decimal, 0)),
         true <- Decimal.compare(decimal, Decimal.new(-9_223_372_036_854_775_808)) != :lt,
         true <- Decimal.compare(decimal, Decimal.new(9_223_372_036_854_775_807)) != :gt do
      {:ok, Decimal.to_integer(decimal)}
    else
      _ -> :error
    end
  end

  defp exact_integer(_value), do: :error

  defp finite_float(%Number{raw: raw}), do: finite_float(raw)

  defp finite_float(value) when is_integer(value), do: finite_float(Integer.to_string(value))
  defp finite_float(value) when is_float(value), do: {:ok, value}

  defp finite_float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} ->
        {:ok, number}

      _ ->
        :error
    end
  end

  defp finite_float(_value), do: :error

  defp duration_nanoseconds(value) when is_binary(value) do
    if Regex.match?(@duration, value) do
      {sign, parts} =
        if String.starts_with?(value, "-"),
          do: {-1, String.trim_leading(value, "-")},
          else: {1, String.trim_leading(value, "+")}

      total =
        @duration_part
        |> Regex.scan(parts, capture: :all_but_first)
        |> Enum.reduce(Decimal.new(0), fn [amount, unit], acc ->
          nanoseconds =
            amount
            |> normalize_decimal()
            |> Decimal.new()
            |> Decimal.mult(Decimal.new(@duration_units[unit]))
            |> Decimal.round(0, :down)

          Decimal.add(acc, nanoseconds)
        end)

      signed = Decimal.mult(total, Decimal.new(sign))

      if Decimal.compare(signed, @min_duration_nanoseconds) != :lt and
           Decimal.compare(signed, @max_duration_nanoseconds) != :gt,
         do: {:ok, signed},
         else: :error
    else
      :error
    end
  end

  defp duration_nanoseconds(_value), do: :error

  defp normalize_decimal("." <> rest), do: "0." <> rest
  defp normalize_decimal(value), do: String.trim_trailing(value, ".")

  defp validation(%{"validation" => %{} = validation}), do: validation
  defp validation(_spec), do: %{}

  defp action_args(%{args_schema: %{"args" => args}}) when is_list(args), do: args
  defp action_args(%{"args_schema" => %{"args" => args}}) when is_list(args), do: args
  defp action_args(%{"args" => args}) when is_list(args), do: args
  defp action_args(_action), do: []

  defp issue(arg, code, message), do: {:error, %{arg: arg, code: code, message: message}}
end
