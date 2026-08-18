defmodule Emisar.Runbooks.Definition do
  @moduledoc """
  The single strict, versioned authoring contract for runbooks.

  JSON Schema owns the shape. This module adds byte budgets and the semantic
  checks JSON Schema cannot express: stable identity, typed constraints,
  references, bounded patterns, and wait arithmetic. It never resolves current
  runners, packs, or policy; that is execution preflight.
  """

  @schema_path Path.expand("../../../priv/runbooks/definition-v1.schema.json", __DIR__)
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> Jason.decode!()
  @limits Map.fetch!(@schema, "x-emisar-limits")
  @compiled_schema (case JSONSchex.compile(@schema, format_assertion: true) do
                      {:ok, compiled} ->
                        compiled

                      {:error, error} ->
                        raise "invalid runbook definition schema: #{inspect(error)}"
                    end)

  @runner_ref ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}~[0-9a-f]{32}\z/
  @group_ref ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z/
  @numeric_operators ~w[greater_than greater_than_or_equal less_than less_than_or_equal]

  @type issue :: %{code: String.t(), path: String.t(), message: String.t()}

  @doc "The decoded, immutable v1 machine schema."
  @spec schema() :: map()
  def schema, do: @schema

  @doc "The byte, fan-out, wait, and runtime limits owned by the schema."
  @spec limits() :: map()
  def limits, do: @limits

  @doc "Fetch one trusted first-party limit by its atom name."
  @spec limit!(atom()) :: pos_integer()
  def limit!(name) when is_atom(name), do: Map.fetch!(@limits, Atom.to_string(name))

  @doc """
  Decodes and strictly validates one canonical v1 JSON definition.

  The raw document is bounded before decoding. Returns
  `{:ok, definition} | {:error, issues}`.
  """
  @spec decode_json(term()) :: {:ok, map()} | {:error, [issue()]}
  def decode_json(encoded) when is_binary(encoded) do
    max_definition_bytes = limit!(:max_definition_bytes)

    if byte_size(encoded) <= max_definition_bytes do
      case Jason.decode(encoded) do
        {:ok, definition} ->
          validate(definition)

        {:error, _reason} ->
          {:error, [issue("invalid_json", "", "Enter a valid JSON object.")]}
      end
    else
      {:error,
       [
         issue(
           "invalid_definition",
           "",
           "JSON exceeds the #{max_definition_bytes} byte limit."
         )
       ]}
    end
  end

  def decode_json(_encoded) do
    {:error, [issue("invalid_json", "", "Enter a valid JSON object.")]}
  end

  @doc "Validate one already-decoded definition without resolving dynamic infrastructure."
  @spec validate(term()) :: {:ok, map()} | {:error, [issue()]}
  def validate(%{} = definition) do
    with :ok <- validate_json_value(definition),
         :ok <- validate_encoded_size(definition),
         :ok <- validate_context_size(definition),
         :ok <- validate_schema_version(definition),
         :ok <- validate_schema(definition),
         [] <- semantic_issues(definition) do
      {:ok, definition}
    else
      {:error, issues} when is_list(issues) -> {:error, sort_issues(issues)}
      issues when is_list(issues) -> {:error, sort_issues(issues)}
    end
  rescue
    Jason.EncodeError ->
      {:error, [issue("invalid_definition", "", "Definition must contain only JSON values.")]}
  end

  def validate(_definition) do
    {:error, [issue("invalid_definition", "", "Definition must be an object.")]}
  end

  @doc """
  Validate the safety envelope for a persisted draft.

  Drafts may be incomplete, but they remain the one canonical JSON shape and
  cannot exceed the same structural, byte, context, or schema-version bounds as
  a publishable definition. `validate/1` remains the publication and execution
  contract.
  """
  @spec validate_draft(term()) :: {:ok, map()} | {:error, [issue()]}
  def validate_draft(%{} = definition) do
    with :ok <- validate_json_value(definition),
         :ok <- validate_encoded_size(definition),
         :ok <- validate_context_size(definition),
         :ok <- validate_schema_version(definition),
         :ok <- validate_draft_shape(definition) do
      {:ok, definition}
    else
      {:error, issues} when is_list(issues) -> {:error, sort_issues(issues)}
    end
  rescue
    Jason.EncodeError ->
      {:error, [issue("invalid_definition", "", "Definition must contain only JSON values.")]}
  end

  def validate_draft(_definition) do
    {:error, [issue("invalid_definition", "", "Definition must be an object.")]}
  end

  defp validate_draft_shape(%{
         "schema_version" => 1,
         "context_markdown" => context,
         "inputs" => inputs,
         "stages" => stages
       })
       when is_binary(context) and is_list(inputs) and is_list(stages) do
    valid? =
      length(inputs) <= limit!(:max_inputs) and Enum.all?(inputs, &is_map/1) and
        length(stages) <= limit!(:max_stages) and Enum.all?(stages, &draft_stage?/1)

    if valid?,
      do: :ok,
      else: invalid_draft_shape()
  end

  defp validate_draft_shape(_definition), do: invalid_draft_shape()

  defp draft_stage?(%{"steps" => steps}) when is_list(steps) do
    Enum.all?(steps, &draft_step?/1)
  end

  defp draft_stage?(_stage), do: false

  defp draft_step?(%{
         "pack" => pack,
         "targets" => %{"selection" => selection, "refs" => refs},
         "args" => args,
         "outputs" => outputs,
         "success" => success
       })
       when is_map(pack) and selection in ["all", "random_one"] and is_list(refs) and
              is_map(args) and is_list(outputs) and
              is_list(success) do
    length(refs) <= limit!(:max_target_refs_per_step) and
      length(outputs) <= limit!(:max_outputs_per_step) and Enum.all?(outputs, &is_map/1) and
      length(success) <= limit!(:max_success_conditions_per_step) and
      Enum.all?(success, &is_map/1)
  end

  defp draft_step?(_step), do: false

  defp invalid_draft_shape do
    {:error,
     [
       issue(
         "invalid_definition",
         "",
         "Draft must use the canonical runbook object structure."
       )
     ]}
  end

  @doc "Whether a value satisfies the complete static definition contract."
  @spec valid?(term()) :: boolean()
  def valid?(definition), do: match?({:ok, _definition}, validate(definition))

  @doc """
  Stable SHA-256 identity for one JSON-compatible runbook definition. Shares one
  canonical encoding with the action-contract hash.
  """
  @spec digest(map()) :: String.t()
  def digest(definition) when is_map(definition), do: Emisar.CanonicalJSON.digest(definition)

  defp validate_json_value(definition) do
    case Emisar.JSONValue.validate(definition,
           max_depth: limit!(:max_definition_depth),
           max_nodes: limit!(:max_definition_nodes)
         ) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error,
         [issue("invalid_definition", "", "Definition exceeds the structural safety budget.")]}
    end
  end

  defp validate_encoded_size(definition) do
    if Jason.encode_to_iodata!(definition)
       |> IO.iodata_length()
       |> Kernel.<=(limit!(:max_definition_bytes)) do
      :ok
    else
      {:error, [issue("invalid_definition", "", "Definition exceeds the encoded byte limit.")]}
    end
  end

  defp validate_context_size(%{"context_markdown" => context}) when is_binary(context) do
    if byte_size(context) <= limit!(:max_context_markdown_bytes) do
      :ok
    else
      {:error,
       [
         issue(
           "invalid_definition",
           "/context_markdown",
           "Context exceeds the UTF-8 byte limit."
         )
       ]}
    end
  end

  defp validate_context_size(_definition), do: :ok

  defp validate_schema_version(%{"schema_version" => 1}), do: :ok

  defp validate_schema_version(%{"schema_version" => _version}) do
    {:error,
     [
       issue(
         "unsupported_schema_version",
         "/schema_version",
         "Only runbook definition schema version 1 is supported."
       )
     ]}
  end

  defp validate_schema_version(_definition), do: :ok

  defp validate_schema(definition) do
    case JSONSchex.validate(@compiled_schema, definition) do
      :ok ->
        :ok

      {:error, errors} ->
        issues =
          errors
          |> prefer_concrete_schema_errors()
          |> Enum.flat_map(&schema_error_issues/1)
          |> Enum.uniq()

        {:error, issues}
    end
  end

  defp prefer_concrete_schema_errors(errors) do
    concrete = Enum.reject(errors, &(&1.rule in [:allOf, :anyOf, :oneOf, :not]))
    if concrete == [], do: errors, else: concrete
  end

  defp schema_error_issues(%{rule: :required, path: path, context: %{contrast: fields}})
       when is_list(fields) do
    base = schema_path(path)

    Enum.map(fields, &required_schema_issue(base, &1))
  end

  defp schema_error_issues(%{
         rule: :additionalProperties,
         path: path,
         context: %{contrast: fields}
       })
       when is_list(fields) do
    base = schema_path(path)

    Enum.map(fields, &unsupported_schema_issue(base, &1))
  end

  defp schema_error_issues(error) do
    [
      issue(
        "invalid_definition",
        pointer(schema_path(error.path)),
        schema_error_message(error.rule)
      )
    ]
  end

  defp required_schema_issue(base, field) do
    issue(
      "invalid_definition",
      pointer(base ++ [field]),
      "A required definition field is missing."
    )
  end

  defp unsupported_schema_issue(base, field) do
    issue(
      "invalid_definition",
      pointer(base ++ [field]),
      "This definition field is not supported."
    )
  end

  defp schema_path(path), do: Enum.reverse(path)

  defp schema_error_message(:type), do: "Definition value has the wrong type."
  defp schema_error_message(:const), do: "Definition value is not supported."
  defp schema_error_message(:enum), do: "Definition value is not one of the supported choices."
  defp schema_error_message(:pattern), do: "Definition value has an invalid format."
  defp schema_error_message(:minItems), do: "Definition list has too few entries."
  defp schema_error_message(:maxItems), do: "Definition list has too many entries."
  defp schema_error_message(:uniqueItems), do: "Definition list entries must be unique."
  defp schema_error_message(:minLength), do: "Definition text is too short."
  defp schema_error_message(:maxLength), do: "Definition text is too long."
  defp schema_error_message(:minimum), do: "Definition number is below the allowed minimum."
  defp schema_error_message(:maximum), do: "Definition number exceeds the allowed maximum."
  defp schema_error_message(_rule), do: "Definition does not match the v1 contract."

  defp semantic_issues(definition) do
    inputs = definition["inputs"]
    stages = definition["stages"]
    input_ids = MapSet.new(inputs, & &1["id"])
    step_index = build_step_index(stages)

    duplicate_issues(inputs, "/inputs", "Input") ++
      duplicate_issues(stages, "/stages", "Stage") ++
      duplicate_step_issues(stages) ++
      input_issues(inputs) ++
      stage_issues(stages, input_ids, step_index)
  end

  defp duplicate_issues(values, base_path, label) do
    values
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn {value, index}, {seen, issues} ->
      id = value["id"]

      if MapSet.member?(seen, id) do
        {seen,
         [
           issue(
             "invalid_definition",
             "#{base_path}/#{index}/id",
             "#{label} IDs must be unique."
           )
           | issues
         ]}
      else
        {MapSet.put(seen, id), issues}
      end
    end)
    |> elem(1)
  end

  defp duplicate_step_issues(stages) do
    stages
    |> Enum.with_index()
    |> Enum.flat_map(fn {stage, stage_index} ->
      Enum.with_index(stage["steps"], &{&1, stage_index, &2})
    end)
    |> Enum.reduce({MapSet.new(), []}, fn {step, stage_index, step_index}, {seen, issues} ->
      id = step["id"]

      if MapSet.member?(seen, id) do
        path = "/stages/#{stage_index}/steps/#{step_index}/id"
        {seen, [issue("invalid_definition", path, "Step IDs must be unique.") | issues]}
      else
        {MapSet.put(seen, id), issues}
      end
    end)
    |> elem(1)
  end

  defp input_issues(inputs) do
    inputs
    |> Enum.with_index()
    |> Enum.flat_map(fn {input, index} ->
      base = "/inputs/#{index}"
      input_constraint_issues(input, base) ++ input_value_issues(input, base)
    end)
  end

  defp input_constraint_issues(input, base) do
    type = input["type"]

    irrelevant =
      case type do
        "string" -> ["minimum", "maximum"]
        type when type in ["integer", "number"] -> ["min_length", "max_length"]
        "boolean" -> ["minimum", "maximum", "min_length", "max_length"]
        "enum" -> ["minimum", "maximum", "min_length", "max_length"]
      end

    Enum.flat_map(irrelevant, fn field ->
      if Map.has_key?(input, field) do
        [
          issue(
            "invalid_input",
            "#{base}/#{field}",
            "This constraint does not apply to the input type."
          )
        ]
      else
        []
      end
    end) ++ ordered_bound_issues(input, base)
  end

  defp ordered_bound_issues(input, base) do
    numeric =
      if is_number(input["minimum"]) and is_number(input["maximum"]) and
           input["minimum"] > input["maximum"] do
        [
          issue(
            "invalid_input",
            "#{base}/maximum",
            "Maximum must be greater than or equal to minimum."
          )
        ]
      else
        []
      end

    strings =
      if is_integer(input["min_length"]) and is_integer(input["max_length"]) and
           input["min_length"] > input["max_length"] do
        [
          issue(
            "invalid_input",
            "#{base}/max_length",
            "Maximum length must be greater than or equal to minimum length."
          )
        ]
      else
        []
      end

    numeric ++ strings
  end

  defp input_value_issues(input, base) do
    sensitive_default =
      if input["sensitive"] and Map.has_key?(input, "default") do
        [
          issue(
            "invalid_input",
            "#{base}/default",
            "Sensitive inputs cannot persist a default."
          )
        ]
      else
        []
      end

    default =
      if Map.has_key?(input, "default") and not valid_input_value?(input, input["default"]) do
        [
          issue(
            "invalid_input",
            "#{base}/default",
            "Default does not satisfy the input's type and constraints."
          )
        ]
      else
        []
      end

    enum =
      input
      |> Map.get("enum", [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, index} ->
        if valid_input_value?(Map.delete(input, "enum"), value) do
          []
        else
          [
            issue(
              "invalid_input",
              "#{base}/enum/#{index}",
              "Enum value does not satisfy the input's type and constraints."
            )
          ]
        end
      end)

    sensitive_default ++ default ++ enum
  end

  defp valid_input_value?(%{"type" => "string"} = input, value) when is_binary(value) do
    length = String.length(value)

    within_optional_min?(length, input["min_length"]) and
      within_optional_max?(length, input["max_length"]) and in_optional_enum?(value, input)
  end

  defp valid_input_value?(%{"type" => "integer"} = input, value) when is_integer(value),
    do: valid_number?(input, value)

  defp valid_input_value?(%{"type" => "number"} = input, value) when is_number(value),
    do: valid_number?(input, value)

  defp valid_input_value?(%{"type" => "boolean"} = input, value) when is_boolean(value),
    do: in_optional_enum?(value, input)

  defp valid_input_value?(%{"type" => "enum"} = input, value) when is_binary(value),
    do: in_optional_enum?(value, input)

  defp valid_input_value?(_input, _value), do: false

  defp valid_number?(input, value) do
    within_optional_min?(value, input["minimum"]) and
      within_optional_max?(value, input["maximum"]) and in_optional_enum?(value, input)
  end

  defp within_optional_min?(_value, nil), do: true
  defp within_optional_min?(value, minimum), do: value >= minimum
  defp within_optional_max?(_value, nil), do: true
  defp within_optional_max?(value, maximum), do: value <= maximum
  defp in_optional_enum?(_value, %{"enum" => nil}), do: true
  defp in_optional_enum?(value, %{"enum" => enum}), do: value in enum
  defp in_optional_enum?(_value, _input), do: true

  defp build_step_index(stages) do
    stages
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {stage, stage_index}, index ->
      Enum.reduce(stage["steps"], index, fn step, acc ->
        outputs = MapSet.new(step["outputs"], & &1["id"])
        Map.put_new(acc, step["id"], %{stage_index: stage_index, outputs: outputs})
      end)
    end)
  end

  defp stage_issues(stages, input_ids, step_index) do
    stages
    |> Enum.with_index()
    |> Enum.flat_map(fn {stage, stage_position} ->
      stage["steps"]
      |> Enum.with_index()
      |> Enum.flat_map(fn {step, step_position} ->
        step_issues(step, stage_position, step_position, input_ids, step_index)
      end)
    end)
  end

  defp step_issues(step, stage_position, step_position, input_ids, step_index) do
    base = "/stages/#{stage_position}/steps/#{step_position}"

    target_issues(step["targets"], "#{base}/targets") ++
      duplicate_issues(step["outputs"], "#{base}/outputs", "Output") ++
      binding_issues(step["args"], base, stage_position, input_ids, step_index) ++
      output_issues(step["outputs"], base) ++
      success_issues(step, base) ++
      wait_issues(step["wait"], base)
  end

  defp target_issues(%{"selection" => selection, "refs" => refs}, base) do
    ref_issues =
      refs
      |> Enum.with_index()
      |> Enum.flat_map(fn {ref, index} ->
        if valid_target_ref?(ref) do
          []
        else
          [issue("invalid_definition", "#{base}/refs/#{index}", "Target ref is invalid.")]
        end
      end)

    selection_issues =
      if selection == "random_one" and not match?(["group:" <> _group], refs) do
        [
          issue(
            "invalid_definition",
            "#{base}/refs",
            "One online runner requires exactly one runner group."
          )
        ]
      else
        []
      end

    ref_issues ++ selection_issues
  end

  defp valid_target_ref?("group:" <> ref),
    do: byte_size(ref) <= 80 and Regex.match?(@group_ref, ref)

  defp valid_target_ref?("runner:" <> ref), do: Regex.match?(@runner_ref, ref)
  defp valid_target_ref?(_ref), do: false

  defp binding_issues(args, base, stage_position, input_ids, step_index) do
    args
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn
      {name, %{"source" => "input", "ref" => ref}} ->
        if MapSet.member?(input_ids, ref) do
          []
        else
          [
            issue(
              "invalid_binding",
              "#{base}/args/#{escape(name)}/ref",
              "Input binding does not reference a declared input."
            )
          ]
        end

      {name, %{"source" => "output", "ref" => ref}} ->
        output_binding_issues(ref, "#{base}/args/#{escape(name)}/ref", stage_position, step_index)

      {_name, _literal} ->
        []
    end)
  end

  defp output_binding_issues(ref, path, stage_position, step_index) do
    [producer_id, output_id] = String.split(ref, ".", parts: 2)

    case Map.get(step_index, producer_id) do
      %{stage_index: producer_stage, outputs: outputs}
      when producer_stage < stage_position ->
        if MapSet.member?(outputs, output_id) do
          []
        else
          [issue("invalid_binding", path, "Output binding references an unknown output.")]
        end

      _other ->
        [
          issue(
            "invalid_binding",
            path,
            "Output binding must reference a declared output from an earlier stage."
          )
        ]
    end
  end

  defp output_issues(outputs, base) do
    outputs
    |> Enum.with_index()
    |> Enum.flat_map(fn {output, index} ->
      extract = output["extract"]
      path = "#{base}/outputs/#{index}/extract/expression"

      source_issues(output, "#{base}/outputs/#{index}/source") ++
        expression_size_issues(extract["expression"], path) ++
        extractor_expression_issues(extract, path)
    end)
  end

  defp source_issues(%{"source" => "structured_output", "extract" => %{"type" => type}}, path)
       when type != "json_pointer" do
    [
      issue(
        "invalid_definition",
        path,
        "Structured output requires a JSON Pointer extractor."
      )
    ]
  end

  defp source_issues(_output, _path), do: []

  defp expression_size_issues(expression, path) do
    if byte_size(expression) <= limit!(:max_expression_bytes) do
      []
    else
      [issue("invalid_definition", path, "Extractor expression exceeds the UTF-8 byte limit.")]
    end
  end

  defp extractor_expression_issues(%{"type" => "json_pointer", "expression" => expression}, path) do
    if ExJSONPointer.valid_json_pointer?(expression) do
      []
    else
      [issue("invalid_definition", path, "Extractor is not a valid JSON Pointer.")]
    end
  end

  defp extractor_expression_issues(%{"type" => type, "expression" => ""}, path)
       when type in ["contains", "grep", "regex"] do
    [issue("invalid_definition", path, "Text extractor expression cannot be empty.")]
  end

  defp extractor_expression_issues(%{"type" => "regex", "expression" => expression}, path),
    do: regex_issues(expression, path)

  defp extractor_expression_issues(_extract, _path), do: []

  defp success_issues(step, base) do
    output_ids = MapSet.new(step["outputs"], & &1["id"])

    step["success"]
    |> Enum.with_index()
    |> Enum.flat_map(fn {condition, index} ->
      condition_base = "#{base}/success/#{index}"

      known_output_issues(condition["output"], output_ids, "#{condition_base}/output") ++
        condition_value_issues(condition, "#{condition_base}/value")
    end)
  end

  defp known_output_issues(output, output_ids, path) do
    if MapSet.member?(output_ids, output) do
      []
    else
      [issue("invalid_definition", path, "Success condition references an unknown output.")]
    end
  end

  defp condition_value_issues(%{"operator" => operator, "value" => value}, path)
       when operator in @numeric_operators do
    if is_number(value) do
      []
    else
      [issue("invalid_definition", path, "Numeric comparison requires a number.")]
    end
  end

  defp condition_value_issues(%{"operator" => "one_of", "value" => value}, path) do
    if is_list(value) and value != [] and Enum.all?(value, &json_scalar?/1) do
      []
    else
      [issue("invalid_definition", path, "Membership requires a non-empty scalar list.")]
    end
  end

  defp condition_value_issues(%{"operator" => "matches", "value" => value}, path)
       when is_binary(value) do
    expression_size_issues(value, path) ++ regex_issues(value, path)
  end

  defp condition_value_issues(%{"operator" => "matches"}, path),
    do: [issue("invalid_definition", path, "Regex comparison requires a string pattern.")]

  defp condition_value_issues(_condition, _path), do: []

  defp regex_issues(expression, path) do
    case :re.compile(expression, [:unicode]) do
      {:ok, _compiled} -> []
      {:error, _reason} -> [issue("invalid_definition", path, "Regex pattern is invalid.")]
    end
  end

  defp json_scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp wait_issues(nil, _base), do: []

  defp wait_issues(wait, base) do
    observations = wait["max_attempts"] - 1

    if observations * wait["interval_seconds"] <= wait["timeout_seconds"] do
      []
    else
      [
        issue(
          "invalid_definition",
          "#{base}/wait/timeout_seconds",
          "Wait timeout cannot cover the configured observations."
        )
      ]
    end
  end

  defp sort_issues(issues),
    do: Enum.sort_by(issues, &{&1.path, &1.code, &1.message})

  defp pointer([]), do: ""
  defp pointer(tokens), do: "/" <> Enum.map_join(tokens, "/", &escape/1)

  defp escape(token),
    do: token |> to_string() |> String.replace("~", "~0") |> String.replace("/", "~1")

  defp issue(code, path, message), do: %{code: code, path: path, message: message}
end
