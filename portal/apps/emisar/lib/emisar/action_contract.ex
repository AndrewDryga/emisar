defmodule Emisar.ActionContract do
  @moduledoc """
  Validates the portable part of a trusted runner action contract.

  The runner remains authoritative for action regexes, host-dependent path
  resolution, and execution-time state. This boundary rejects portable,
  deterministic contract failures before Emisar creates a run, approval,
  draft, or operation record.
  """

  alias Emisar.JSONNumber
  alias Emisar.SafeText

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
  @max_duration_magnitude 9_223_372_036_854_775_808
  @max_duration_nanoseconds @max_duration_magnitude - 1
  @max_float_scale_before_multiply 1.797_693_134_862_315_7e307

  @type issue :: %{
          arg: String.t(),
          code: String.t(),
          message: String.t(),
          path: [String.t() | non_neg_integer()]
        }

  @doc """
  Normalize the trusted fields whose equality makes one authored runbook step
  safe across every selected pack version and runner.
  """
  def snapshot(descriptor) when is_map(descriptor) do
    %{
      "contract_version" => 1,
      "args_schema" => descriptor["args_schema"] || %{"args" => []},
      "output_schema" => descriptor["output_schema"],
      "risk" => descriptor["risk"],
      "execution_limits" => descriptor["execution_limits"] || %{}
    }
  end

  @doc """
  Stable SHA-256 identity for a normalized action-contract snapshot. Shares one
  canonical encoding with the runbook definition hash, because a client compares
  this value to decide `target_contract_changed`.
  """
  def digest(snapshot) when is_map(snapshot), do: Emisar.CanonicalJSON.digest(snapshot)

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

  @doc """
  Render a trusted descriptor's declared defaults as browser form parameters.

  Every declared argument gets a string value: arrays join on `", "`, booleans
  render `"true"`/`"false"`, and an argument with no default renders blank.
  """
  @spec form_values(map()) :: %{optional(String.t()) => String.t()}
  def form_values(action) when is_map(action) do
    action
    |> action_args()
    |> Map.new(fn spec -> {spec["name"], form_value(spec["type"], spec["default"])} end)
  end

  @doc """
  Cast a browser form's string-keyed arguments against a trusted descriptor.

  Arguments the form did not submit fall back to `form_values/1`, blank optional
  values are omitted, and the coerced values satisfy the same portable contract
  `validate/2` enforces. Returns `{:ok, args}` (JSON-encodable) or
  `{:error, issues}` with every failing argument in schema order.
  """
  @spec cast_form(map(), map()) :: {:ok, map()} | {:error, [issue()]}
  def cast_form(raw, action) when is_map(raw) and is_map(action) do
    specs = action_args(action)

    case unknown_form_args(specs, raw) do
      [] ->
        values = Map.merge(form_values(action), raw)
        cast_form_specs(specs, values)

      unknown ->
        {:error, Enum.map(unknown, &arg_issue(&1, "unknown_arg", "unknown argument"))}
    end
  end

  def cast_form(_raw, _action), do: {:error, [arg_issue("args", "type", "expected object")]}

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
         :ok <- validate_string_bytes(spec, normalized),
         :ok <- validate_safe_strings(spec, normalized) do
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
    case exact_number(value) do
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
        {:ok, coerced} ->
          {:cont, {:ok, [coerced | normalized]}}

        :error ->
          {:halt, element_issue(name, index, "type", "element #{index} is not #{expected}")}
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
          element_issue(
            spec["name"],
            index,
            "max_length",
            "element #{index} exceeds #{limit} bytes"
          )

        _ ->
          issue(spec["name"], "max_length", "exceeds #{limit} bytes")
      end
    else
      :ok
    end
  end

  # At approval time nothing has executed yet, so these values ARE the artifact
  # the human checks. Jason emits U+202E verbatim and HEEx escaping does not
  # touch `\p{Cf}`, so a bidi override reverses the argument line the approver
  # reads while the runner receives the true bytes. Reject rather than strip —
  # the caller is an LLM that can retry, and stripping at the projection would
  # make the rendered args disagree with the `args_sha256` the approver is told
  # to verify. `unsafe_multiline?` because 48 shipped actions take a multi-line
  # shell program.
  defp validate_safe_strings(spec, value) do
    if spec["type"] in ["string", "path", "string_array"] do
      values = if is_list(value), do: value, else: [value]

      unsafe =
        values
        |> Enum.with_index()
        |> Enum.find(fn {item, _index} -> SafeText.unsafe_multiline?(item) end)

      safe_string_result(spec, value, unsafe)
    else
      :ok
    end
  end

  defp safe_string_result(_spec, _value, nil), do: :ok

  defp safe_string_result(spec, value, {_item, index}) when is_list(value) do
    element_issue(
      spec["name"],
      index,
      "format",
      "element #{index} contains control or formatting characters"
    )
  end

  defp safe_string_result(spec, _value, _unsafe),
    do: issue(spec["name"], "format", "contains control or formatting characters")

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
          element = %{
            issue
            | message: "element #{index}: #{issue.message}",
              path: [issue.arg, index]
          }

          {:halt, {:error, element}}
      end
    end)
  end

  defp validate_each(spec, value, validation), do: validate_scalar(spec, value, validation)

  defp validate_scalar(spec, value, validation) do
    with :ok <- validate_membership(spec, value, validation, "enum"),
         :ok <- validate_membership(spec, value, validation, "allowed"),
         :ok <- validate_numeric_bounds(spec, value, validation) do
      validate_duration_bounds(spec, value, validation)
    end
  end

  defp validate_membership(%{"name" => name, "type" => type}, value, validation, key) do
    case validation[key] do
      candidates when is_list(candidates) and candidates != [] ->
        matches? =
          if type in ["integer", "number", "integer_array"],
            do: Enum.any?(candidates, &numeric_equal?(value, &1)),
            else: Enum.any?(candidates, &(&1 == value))

        if matches?,
          do: :ok,
          else: issue(name, key, "is not an allowed value")

      _ ->
        :ok
    end
  end

  defp validate_numeric_bounds(%{"name" => name, "type" => type}, value, validation)
       when type in ["integer", "number", "integer_array"] do
    cond do
      numeric_compare(value, validation["min"]) == :lt ->
        issue(name, "min", "is below the minimum")

      numeric_compare(value, validation["max"]) == :gt ->
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
        if value < limit,
          do: issue(name, "min_duration", "is below the minimum duration"),
          else: :ok

      {:ok, limit} ->
        if value > limit,
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

  defp form_value(type, default) when type in ["string_array", "integer_array"] do
    case default do
      list when is_list(list) -> Enum.map_join(list, ", ", &to_string/1)
      nil -> ""
      other -> to_string(other)
    end
  end

  defp form_value("boolean", true), do: "true"
  defp form_value("boolean", _default), do: "false"
  defp form_value(_type, nil), do: ""
  defp form_value(_type, default), do: to_string(default)

  defp unknown_form_args(specs, raw) do
    known = MapSet.new(specs, & &1["name"])

    raw
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reject(&MapSet.member?(known, &1))
  end

  defp cast_form_specs(specs, values) do
    {args, issues} =
      Enum.reduce(specs, {%{}, []}, fn spec, {args, issues} ->
        case cast_form_value(spec, values[spec["name"]]) do
          :skip -> {args, issues}
          {:ok, value} -> {Map.put(args, spec["name"], value), issues}
          {:error, issue} -> {args, [issue | issues]}
        end
      end)

    if issues == [], do: {:ok, args}, else: {:error, Enum.reverse(issues)}
  end

  defp cast_form_value(%{"required" => true, "name" => name}, value) when value in [nil, ""],
    do: issue(name, "required", "is required")

  defp cast_form_value(_spec, value) when value in [nil, ""], do: :skip

  defp cast_form_value(spec, value) do
    with {:ok, coerced} <- coerce_form(spec, value),
         :ok <- validate_value(spec, coerced) do
      {:ok, coerced}
    end
  end

  defp coerce_form(%{"type" => "boolean"}, value) when value in ["true", "on", true],
    do: {:ok, true}

  defp coerce_form(%{"type" => "boolean"}, value) when value in ["false", false], do: {:ok, false}

  defp coerce_form(%{"name" => name, "type" => "boolean"}, _value),
    do: issue(name, "type", "expected boolean")

  defp coerce_form(%{"type" => type}, value)
       when type in ["string", "path", "duration"] and is_binary(value),
       do: {:ok, value}

  defp coerce_form(%{"name" => name, "type" => "integer"}, value) when is_binary(value) do
    case exact_integer(String.trim(value)) do
      {:ok, integer} -> {:ok, integer}
      :error -> issue(name, "type", "expected integer")
    end
  end

  # Keep the operator's exact digits: a float round-trip would silently change
  # the value the runner receives, so the token rides through as-is and Jason
  # emits it verbatim.
  defp coerce_form(%{"name" => name, "type" => "number"}, value) when is_binary(value) do
    number = %JSONNumber{raw: String.trim(value)}

    case exact_number(number) do
      {:ok, _number} -> {:ok, number}
      :error -> issue(name, "type", "expected number")
    end
  end

  defp coerce_form(%{"type" => "string_array"}, value) when is_binary(value),
    do: {:ok, split_items(value)}

  defp coerce_form(%{"name" => name, "type" => "integer_array"}, value) when is_binary(value),
    do: coerce_array(name, split_items(value), &exact_integer/1, "integer")

  # Every form field arrives as text; a crafted payload can still submit a list
  # or a map, which no portable type accepts.
  defp coerce_form(%{"name" => name}, value) when not is_binary(value),
    do: issue(name, "type", "expected text")

  defp coerce_form(%{"name" => name}, _value),
    do: issue(name, "type", "unsupported argument type")

  defp split_items(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807
  # JSON's own number grammar; an integer is that grammar without a fraction or
  # exponent, so `1e3` and `1000.0` are numbers, never integers — the runner
  # draws the same line, and both sides keep the token verbatim.
  @integer_literal ~r/\A-?(?:0|[1-9][0-9]*)\z/
  @number_literal ~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/

  defp exact_integer(%JSONNumber{raw: raw}), do: exact_integer(raw)

  defp exact_integer(value) when is_integer(value) and value in @int64_min..@int64_max,
    do: {:ok, value}

  defp exact_integer(value) when is_binary(value) do
    if Regex.match?(@integer_literal, value),
      do: exact_integer(String.to_integer(value)),
      else: :error
  end

  defp exact_integer(_value), do: :error

  # Integers stay exact; anything with a fraction or exponent compares as a
  # float64, the way the runner validates it.
  defp exact_number(%JSONNumber{raw: raw}) do
    cond do
      Regex.match?(@integer_literal, raw) -> {:ok, String.to_integer(raw)}
      Regex.match?(@number_literal, raw) -> parse_float(raw)
      true -> :error
    end
  end

  defp exact_number(value) when is_integer(value) or is_float(value), do: {:ok, value}
  defp exact_number(_value), do: :error

  defp parse_float(raw) do
    case Float.parse(raw) do
      {float, ""} -> {:ok, float}
      _ -> :error
    end
  end

  defp numeric_equal?(left, right) do
    with {:ok, left} <- exact_number(left),
         {:ok, right} <- exact_number(right) do
      left == right
    else
      _ -> false
    end
  end

  defp numeric_compare(_value, nil), do: :not_numeric

  defp numeric_compare(left, right) do
    with {:ok, left} <- exact_number(left),
         {:ok, right} <- exact_number(right) do
      cond do
        left < right -> :lt
        left > right -> :gt
        true -> :eq
      end
    else
      _ -> :not_numeric
    end
  end

  defp duration_nanoseconds(value) when is_binary(value) do
    if Regex.match?(@duration, value) do
      {sign, parts} =
        if String.starts_with?(value, "-"),
          do: {-1, String.trim_leading(value, "-")},
          else: {1, String.trim_leading(value, "+")}

      result =
        @duration_part
        |> Regex.scan(parts, capture: :all_but_first)
        |> Enum.reduce_while({:ok, 0}, fn [amount, unit], {:ok, total} ->
          with {:ok, nanoseconds} <- duration_part_nanoseconds(amount, @duration_units[unit]),
               true <- total <= @max_duration_magnitude - nanoseconds do
            {:cont, {:ok, total + nanoseconds}}
          else
            _ -> {:halt, :error}
          end
        end)

      apply_duration_sign(result, sign)
    else
      :error
    end
  end

  defp duration_nanoseconds(_value), do: :error

  defp duration_part_nanoseconds(amount, unit) do
    {whole_digits, fraction_digits} = split_duration_amount(amount)

    with {:ok, whole} <- duration_whole(whole_digits),
         true <- whole <= div(@max_duration_magnitude, unit) do
      {fraction, scale} = duration_fraction(fraction_digits, 0, 1.0)
      nanoseconds = whole * unit + fractional_nanoseconds(fraction, scale, unit)

      if nanoseconds <= @max_duration_magnitude, do: {:ok, nanoseconds}, else: :error
    else
      _ -> :error
    end
  end

  defp split_duration_amount(amount) do
    case String.split(amount, ".", parts: 2) do
      [whole] -> {whole, ""}
      [whole, fraction] -> {whole, fraction}
    end
  end

  defp duration_whole(digits) do
    significant = String.trim_leading(digits, "0")

    cond do
      significant == "" ->
        {:ok, 0}

      byte_size(significant) > 19 ->
        :error

      true ->
        integer = String.to_integer(significant)
        if integer <= @max_duration_magnitude, do: {:ok, integer}, else: :error
    end
  end

  defp duration_fraction(<<>>, value, scale), do: {value, scale}

  defp duration_fraction(<<digit, rest::binary>>, value, scale) do
    if value > div(@max_duration_nanoseconds, 10) do
      {value, scale}
    else
      next = value * 10 + digit - ?0

      if next > @max_duration_magnitude,
        do: {value, scale},
        else: duration_fraction(rest, next, next_duration_scale(scale))
    end
  end

  defp next_duration_scale(:too_small), do: :too_small

  defp next_duration_scale(scale) when scale > @max_float_scale_before_multiply,
    do: :too_small

  defp next_duration_scale(scale), do: scale * 10.0

  defp fractional_nanoseconds(_fraction, :too_small, _unit), do: 0
  defp fractional_nanoseconds(fraction, scale, unit), do: trunc(fraction * (unit / scale))

  defp apply_duration_sign(:error, _sign), do: :error
  defp apply_duration_sign({:ok, total}, -1), do: {:ok, -total}

  defp apply_duration_sign({:ok, total}, 1) when total <= @max_duration_nanoseconds,
    do: {:ok, total}

  defp apply_duration_sign({:ok, _total}, 1), do: :error

  defp validation(%{"validation" => %{} = validation}), do: validation
  defp validation(_spec), do: %{}

  defp action_args(%{args_schema: %{"args" => args}}) when is_list(args), do: args
  defp action_args(%{"args_schema" => %{"args" => args}}) when is_list(args), do: args
  defp action_args(_action), do: []

  defp issue(arg, code, message), do: {:error, arg_issue(arg, code, message)}

  defp element_issue(arg, index, code, message),
    do: {:error, %{arg_issue(arg, code, message) | path: [arg, index]}}

  defp arg_issue(arg, code, message), do: %{arg: arg, code: code, message: message, path: [arg]}
end
