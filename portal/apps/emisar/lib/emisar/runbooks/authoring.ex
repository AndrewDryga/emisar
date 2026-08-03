defmodule Emisar.Runbooks.Authoring do
  @moduledoc """
  Canonical construction of the strict v1 definition from typed editor input.

  A boundary owns its own raw representation — the console keeps browser
  strings, an importer keeps its document — and hands this module a typed
  command. Semantic booleans are booleans; every editable scalar stays the
  operator's token, so a malformed number, boolean, or JSON literal survives
  into `Emisar.Runbooks.Definition`'s exact per-path issue instead of being
  dropped or guessed here.
  """

  @typedoc "One lossless editor command for the whole v1 definition."
  @type command :: %{
          context_markdown: String.t(),
          inputs: [input()],
          stages: [stage()]
        }

  @typedoc "One run-time input declaration."
  @type input :: %{
          id: String.t(),
          description: String.t(),
          type: String.t(),
          required?: boolean(),
          sensitive?: boolean(),
          default: String.t(),
          enum_values: [enum_value()],
          minimum: String.t(),
          maximum: String.t(),
          min_length: String.t(),
          max_length: String.t()
        }

  @typedoc "One allowed enum value and whether it is that input's default."
  @type enum_value :: %{value: String.t(), default?: boolean()}

  @typedoc "One ordered workflow stage."
  @type stage :: %{
          id: String.t(),
          title: String.t(),
          mode: String.t(),
          max_parallel: String.t(),
          steps: [step()]
        }

  @typedoc "One action invocation inside a stage."
  @type step :: %{
          id: String.t(),
          pack_id: String.t(),
          action: String.t(),
          target_selection: String.t(),
          target_refs: [String.t()],
          args: [argument()],
          outputs: [output()],
          success: [success()],
          wait: wait()
        }

  @typedoc "One action argument binding, carrying its descriptor metadata."
  @type argument :: %{
          name: String.t(),
          type: String.t(),
          required?: boolean(),
          sensitive?: boolean(),
          source: String.t(),
          value: String.t(),
          ref: String.t()
        }

  @typedoc "One value extracted from a step's result."
  @type output :: %{
          id: String.t(),
          source: String.t(),
          sensitive?: boolean(),
          extract_type: String.t(),
          expression: String.t(),
          capture: String.t()
        }

  @typedoc "One success condition over an extracted output."
  @type success :: %{output: String.t(), operator: String.t(), value: String.t()}

  @typedoc "The step's optional retry-until-success envelope."
  @type wait :: %{
          enabled?: boolean(),
          interval_seconds: String.t(),
          timeout_seconds: String.t(),
          max_attempts: String.t()
        }

  @doc """
  Build the canonical, JSON-compatible v1 definition from one typed command.

  The result is always structurally complete; validity is `Definition`'s call.
  """
  @spec build_v1(command()) :: map()
  def build_v1(command) do
    %{
      "schema_version" => 1,
      "context_markdown" => command.context_markdown,
      "inputs" => Enum.map(command.inputs, &input/1),
      "stages" => Enum.map(command.stages, &stage/1)
    }
  end

  @doc """
  Align one typed argument command with its selected action argument descriptor.

  `existing` is the operator's current binding, or `nil` when the argument row
  is new. A required argument gains a binding, a sensitive one is never left as
  a literal, and a literal carried over from an untyped JSON row is converted to
  the descriptor's text type.
  """
  @spec sync_argument(map(), argument() | nil) :: argument()
  def sync_argument(spec, existing) when is_map(spec) do
    type = spec["type"] || "json"
    required? = spec["required"] == true
    sensitive? = spec["sensitive"] == true

    %{
      name: spec["name"] || "",
      type: type,
      required?: required?,
      sensitive?: sensitive?,
      source: synced_source(existing, required?, sensitive?),
      value: synced_value(spec, existing, type),
      ref: synced_ref(existing)
    }
  end

  defp input(input) do
    %{
      "id" => input.id,
      "description" => input.description,
      "type" => input.type,
      "required" => input.required?,
      "sensitive" => input.sensitive?
    }
    |> put_input_default(input)
    |> maybe_put("enum", input.type == "enum", Enum.map(input.enum_values, & &1.value))
    |> put_nonblank("minimum", input.minimum, &number/1)
    |> put_nonblank("maximum", input.maximum, &number/1)
    |> put_nonblank("min_length", input.min_length, &integer/1)
    |> put_nonblank("max_length", input.max_length, &integer/1)
  end

  # A sensitive input never persists a default — the value would sit in the
  # definition every reader of the runbook can see.
  defp put_input_default(definition, %{sensitive?: true}), do: definition

  defp put_input_default(definition, %{type: "enum"} = input) do
    case Enum.find(input.enum_values, & &1.default?) do
      %{value: value} -> put_nonblank(definition, "default", value, &typed_value(&1, "enum"))
      nil -> definition
    end
  end

  defp put_input_default(definition, input),
    do: put_nonblank(definition, "default", input.default, &typed_value(&1, input.type))

  defp stage(stage) do
    definition = %{
      "id" => stage.id,
      "title" => stage.title,
      "mode" => stage.mode,
      "steps" => Enum.map(stage.steps, &step/1)
    }

    if stage.mode == "parallel",
      do: Map.put(definition, "max_parallel", integer(stage.max_parallel)),
      else: definition
  end

  defp step(step) do
    %{
      "id" => step.id,
      "pack" => %{"id" => step.pack_id},
      "action" => step.action,
      "targets" => %{"selection" => step.target_selection, "refs" => step.target_refs},
      "args" => arguments(step.args),
      "outputs" => Enum.map(step.outputs, &output/1),
      "success" => Enum.map(step.success, &success/1),
      "wait" => wait(step.wait)
    }
  end

  defp arguments(arguments) do
    arguments
    |> Enum.reject(&(&1.source == "omit"))
    |> Map.new(&{&1.name, argument_binding(&1)})
  end

  defp argument_binding(%{source: "input"} = argument),
    do: %{"source" => "input", "ref" => argument.ref}

  defp argument_binding(%{source: "output"} = argument),
    do: %{"source" => "output", "ref" => argument.ref}

  defp argument_binding(argument) do
    put_nonblank(
      %{"source" => "literal"},
      "value",
      argument.value,
      &argument_value(&1, argument.type)
    )
  end

  defp output(output) do
    %{
      "id" => output.id,
      "source" => output.source,
      "sensitive" => output.sensitive?,
      "extract" => extract(output)
    }
  end

  defp extract(%{extract_type: "regex"} = output),
    do: %{"type" => "regex", "expression" => output.expression, "capture" => output.capture}

  defp extract(output),
    do: %{"type" => output.extract_type, "expression" => output.expression}

  defp success(success) do
    %{"output" => success.output, "operator" => success.operator}
    |> put_nonblank("value", success.value, &json/1)
  end

  defp wait(%{enabled?: true} = wait) do
    %{
      "interval_seconds" => integer(wait.interval_seconds),
      "timeout_seconds" => integer(wait.timeout_seconds),
      "max_attempts" => integer(wait.max_attempts)
    }
  end

  defp wait(_wait), do: nil

  defp synced_source(nil, true, true), do: "input"
  defp synced_source(nil, true, false), do: "literal"
  defp synced_source(nil, false, _sensitive?), do: "omit"

  defp synced_source(existing, required?, sensitive?) do
    cond do
      required? and existing.source == "omit" -> if(sensitive?, do: "input", else: "literal")
      sensitive? and existing.source == "literal" -> "input"
      true -> existing.source
    end
  end

  defp synced_value(spec, nil, type), do: descriptor_default(spec, type)

  defp synced_value(_spec, %{type: "json", value: value}, type)
       when type in ["string", "path", "duration"],
       do: value |> json() |> value_text()

  defp synced_value(_spec, existing, _type), do: existing.value

  defp synced_ref(nil), do: ""
  defp synced_ref(existing), do: existing.ref

  defp descriptor_default(spec, type) do
    cond do
      not Map.has_key?(spec, "default") -> ""
      type in ["string", "path", "duration"] -> spec["default"] || ""
      true -> Jason.encode!(spec["default"])
    end
  end

  defp typed_value(value, "integer"), do: integer(value)
  defp typed_value(value, "number"), do: number(value)
  defp typed_value("true", "boolean"), do: true
  defp typed_value("false", "boolean"), do: false
  defp typed_value(value, _type), do: value

  defp argument_value(value, type) when type in ["string", "path", "duration"], do: value
  defp argument_value(value, "integer"), do: integer(value)
  defp argument_value(value, "number"), do: number(value)
  defp argument_value("true", "boolean"), do: true
  defp argument_value("false", "boolean"), do: false
  defp argument_value(value, "boolean"), do: value
  defp argument_value(value, _type), do: json(value)

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp integer(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> value
    end
  end

  defp number(value), do: value

  defp json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp json(value), do: value

  # A decoded literal returns to an editable text field, so a non-string value
  # comes back as the JSON text the operator typed, never a raw term.
  defp value_text(nil), do: ""
  defp value_text(value) when is_binary(value), do: value
  defp value_text(value), do: Jason.encode!(value)

  defp maybe_put(definition, key, true, value), do: Map.put(definition, key, value)
  defp maybe_put(definition, _key, false, _value), do: definition

  defp put_nonblank(definition, key, value, coerce) when is_binary(value) do
    if String.trim(value) == "", do: definition, else: Map.put(definition, key, coerce.(value))
  end

  defp put_nonblank(definition, _key, _value, _coerce), do: definition
end
