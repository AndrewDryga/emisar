defmodule EmisarWeb.RunbookDraft do
  @moduledoc """
  Lossless form state for the structured runbook editor.

  The browser edits strings and ordered rows; `definition/1` is the only
  conversion into the strict JSON-compatible Runbooks contract. No source-text
  definition or alternate persisted shape exists.
  """

  @default_wait %{
    "enabled" => "false",
    "interval_seconds" => "10",
    "timeout_seconds" => "120",
    "max_attempts" => "12"
  }

  def new do
    %{
      "title" => "",
      "slug" => "",
      "description" => "",
      "context_markdown" => default_context(),
      "inputs" => [],
      "stages" => [stage()]
    }
  end

  def from_runbook(runbook) do
    runbook.definition
    |> from_definition()
    |> Map.merge(%{
      "title" => runbook.title || "",
      "slug" => runbook.slug || "",
      "description" => runbook.description || ""
    })
  end

  def from_definition(definition) when is_map(definition) do
    %{
      "title" => "",
      "slug" => "",
      "description" => "",
      "context_markdown" => definition["context_markdown"] || "",
      "inputs" => Enum.map(definition["inputs"] || [], &input_from_definition/1),
      "stages" => Enum.map(definition["stages"] || [], &stage_from_definition/1)
    }
  end

  def from_definition(_definition), do: new()

  def definition(draft) do
    %{
      "schema_version" => 1,
      "context_markdown" => draft["context_markdown"] || "",
      "inputs" => Enum.map(draft["inputs"] || [], &input_to_definition/1),
      "stages" => Enum.map(draft["stages"] || [], &stage_to_definition/1)
    }
  end

  def fingerprint(draft) do
    %{
      "title" => draft["title"] || "",
      "slug" => draft["slug"] || "",
      "description" => draft["description"] || "",
      "definition" => definition(draft)
    }
    |> Jason.encode!()
  end

  def input do
    %{
      "id" => "",
      "description" => "",
      "type" => "string",
      "required" => "true",
      "sensitive" => "false",
      "default" => "",
      "enum_values" => [],
      "minimum" => "",
      "maximum" => "",
      "min_length" => "",
      "max_length" => ""
    }
  end

  def stage do
    %{
      "id" => "stage",
      "title" => "Run actions",
      "mode" => "sequential",
      "max_parallel" => "5",
      "steps" => [step()]
    }
  end

  def step do
    %{
      "id" => "step",
      "pack_id" => "",
      "action" => "",
      "target_refs" => [],
      "args" => [],
      "outputs" => [],
      "success" => [],
      "wait" => @default_wait
    }
  end

  def argument do
    %{
      "name" => "",
      "type" => "json",
      "required" => "false",
      "sensitive" => "false",
      "source" => "omit",
      "value" => "",
      "ref" => ""
    }
  end

  @doc "Align one form binding with its selected trusted action argument descriptor."
  def sync_argument(spec, existing) when is_map(spec) do
    existing? = is_map(existing)
    existing = existing || argument()
    type = spec["type"] || "json"
    required? = spec["required"] == true
    sensitive? = spec["sensitive"] == true

    source = synced_argument_source(existing, existing?, required?, sensitive?)

    %{
      "name" => spec["name"] || "",
      "type" => type,
      "required" => bool_string(required?),
      "sensitive" => bool_string(sensitive?),
      "source" => source,
      "value" => synced_literal_value(spec, existing, type, existing?),
      "ref" => existing["ref"] || ""
    }
  end

  def output do
    %{
      "id" => "",
      "source" => "structured_output",
      "sensitive" => "false",
      "extract_type" => "json_pointer",
      "expression" => "",
      "capture" => "0"
    }
  end

  def success do
    %{"output" => "", "operator" => "equals", "value" => ""}
  end

  defp input_from_definition(input) do
    input()
    |> Map.merge(%{
      "id" => input["id"] || "",
      "description" => input["description"] || "",
      "type" => input["type"] || "string",
      "required" => bool_string(input["required"]),
      "sensitive" => bool_string(input["sensitive"]),
      "default" => typed_value_text(input["default"], input["type"]),
      "enum_values" => Enum.map(input["enum"] || [], &%{"value" => optional_text(&1)}),
      "minimum" => optional_text(input["minimum"]),
      "maximum" => optional_text(input["maximum"]),
      "min_length" => optional_text(input["min_length"]),
      "max_length" => optional_text(input["max_length"])
    })
  end

  defp input_to_definition(input) do
    type = input["type"] || "string"

    %{
      "id" => input["id"] || "",
      "description" => input["description"] || "",
      "type" => type,
      "required" => input["required"] == "true",
      "sensitive" => input["sensitive"] == "true"
    }
    |> maybe_put_nonblank("default", input["default"], &parse_typed_value(&1, type))
    |> maybe_put(
      "enum",
      type == "enum",
      Enum.map(input["enum_values"] || [], &(&1["value"] || ""))
    )
    |> maybe_put_nonblank("minimum", input["minimum"], &parse_number/1)
    |> maybe_put_nonblank("maximum", input["maximum"], &parse_number/1)
    |> maybe_put_nonblank("min_length", input["min_length"], &parse_integer/1)
    |> maybe_put_nonblank("max_length", input["max_length"], &parse_integer/1)
  end

  defp stage_from_definition(stage) do
    %{
      "id" => stage["id"] || "",
      "title" => stage["title"] || "",
      "mode" => stage["mode"] || "sequential",
      "max_parallel" => optional_text(stage["max_parallel"] || 1),
      "steps" => Enum.map(stage["steps"] || [], &step_from_definition/1)
    }
  end

  defp stage_to_definition(stage) do
    stage_definition = %{
      "id" => stage["id"] || "",
      "title" => stage["title"] || "",
      "mode" => stage["mode"] || "sequential",
      "steps" => Enum.map(stage["steps"] || [], &step_to_definition/1)
    }

    if stage_definition["mode"] == "parallel",
      do: Map.put(stage_definition, "max_parallel", parse_integer(stage["max_parallel"])),
      else: stage_definition
  end

  defp step_from_definition(step) do
    %{
      "id" => step["id"] || "",
      "pack_id" => get_in(step, ["pack", "id"]) || "",
      "action" => step["action"] || "",
      "target_refs" => get_in(step, ["targets", "refs"]) || [],
      "args" =>
        step
        |> Map.get("args", %{})
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&argument_from_definition/1),
      "outputs" => Enum.map(step["outputs"] || [], &output_from_definition/1),
      "success" => Enum.map(step["success"] || [], &success_from_definition/1),
      "wait" => wait_from_definition(step["wait"])
    }
  end

  defp step_to_definition(step) do
    %{
      "id" => step["id"] || "",
      "pack" => %{"id" => step["pack_id"] || ""},
      "action" => step["action"] || "",
      "targets" => %{"refs" => step["target_refs"] || []},
      "args" => arguments_to_definition(step["args"] || []),
      "outputs" => Enum.map(step["outputs"] || [], &output_to_definition/1),
      "success" => Enum.map(step["success"] || [], &success_to_definition/1),
      "wait" => wait_to_definition(step["wait"] || @default_wait)
    }
  end

  defp argument_from_definition({name, %{"source" => "literal", "value" => value}}) do
    argument()
    |> Map.merge(%{
      "name" => name,
      "source" => "literal",
      "value" => json_text(value)
    })
  end

  defp argument_from_definition({name, %{"source" => source, "ref" => ref}}) do
    argument()
    |> Map.merge(%{
      "name" => name,
      "source" => source,
      "ref" => ref || ""
    })
  end

  defp argument_from_definition({name, _binding}),
    do: Map.merge(argument(), %{"name" => name})

  defp arguments_to_definition(arguments) do
    Enum.reduce(arguments, %{}, fn argument, bindings ->
      if argument["source"] != "omit" do
        {name, binding} = argument_to_definition(argument)
        Map.put(bindings, name, binding)
      else
        bindings
      end
    end)
  end

  defp argument_to_definition(argument) do
    binding =
      case argument["source"] do
        "input" ->
          %{"source" => "input", "ref" => argument["ref"] || ""}

        "output" ->
          %{"source" => "output", "ref" => argument["ref"] || ""}

        _ ->
          %{"source" => "literal"}
          |> maybe_put_nonblank(
            "value",
            argument["value"],
            &parse_argument_value(&1, argument["type"])
          )
      end

    {argument["name"] || "", binding}
  end

  defp output_from_definition(output) do
    extract = output["extract"] || %{}

    %{
      "id" => output["id"] || "",
      "source" => output["source"] || "structured_output",
      "sensitive" => bool_string(output["sensitive"]),
      "extract_type" => extract["type"] || "json_pointer",
      "expression" => extract["expression"] || "",
      "capture" => extract["capture"] || "0"
    }
  end

  defp output_to_definition(output) do
    extract = %{
      "type" => output["extract_type"] || "json_pointer",
      "expression" => output["expression"] || ""
    }

    extract =
      if extract["type"] == "regex",
        do: Map.put(extract, "capture", output["capture"] || "0"),
        else: extract

    %{
      "id" => output["id"] || "",
      "source" => output["source"] || "structured_output",
      "sensitive" => output["sensitive"] == "true",
      "extract" => extract
    }
  end

  defp success_from_definition(success) do
    %{
      "output" => success["output"] || "",
      "operator" => success["operator"] || "equals",
      "value" => json_text(success["value"])
    }
  end

  defp success_to_definition(success) do
    %{
      "output" => success["output"] || "",
      "operator" => success["operator"] || "equals"
    }
    |> maybe_put_nonblank("value", success["value"], &parse_json/1)
  end

  defp wait_from_definition(nil), do: @default_wait

  defp wait_from_definition(wait) do
    %{
      "enabled" => "true",
      "interval_seconds" => optional_text(wait["interval_seconds"]),
      "timeout_seconds" => optional_text(wait["timeout_seconds"]),
      "max_attempts" => optional_text(wait["max_attempts"])
    }
  end

  defp wait_to_definition(%{"enabled" => "true"} = wait) do
    %{
      "interval_seconds" => parse_integer(wait["interval_seconds"]),
      "timeout_seconds" => parse_integer(wait["timeout_seconds"]),
      "max_attempts" => parse_integer(wait["max_attempts"])
    }
  end

  defp wait_to_definition(_wait), do: nil

  defp default_context do
    """
    ## Before you run

    - State the evidence that makes this run necessary.
    - Confirm the expected result and rollback boundary.
    """
    |> String.trim()
  end

  defp parse_typed_value(value, "string"), do: value || ""
  defp parse_typed_value(value, "enum"), do: value || ""
  defp parse_typed_value(value, "integer"), do: parse_integer(value)
  defp parse_typed_value(value, "number"), do: parse_number(value)
  defp parse_typed_value("true", "boolean"), do: true
  defp parse_typed_value("false", "boolean"), do: false
  defp parse_typed_value(value, "boolean"), do: value

  defp parse_argument_value(value, type) when type in ["string", "path", "duration"],
    do: value || ""

  defp parse_argument_value(value, "integer"), do: parse_integer(value)
  defp parse_argument_value(value, "number"), do: parse_number(value)
  defp parse_argument_value("true", "boolean"), do: true
  defp parse_argument_value("false", "boolean"), do: false
  defp parse_argument_value(value, "boolean"), do: value
  defp parse_argument_value(value, _type), do: parse_json(value)

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp parse_integer(value), do: value

  defp parse_number(value) when is_number(value), do: value

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp parse_number(value), do: value

  defp parse_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp parse_json(value), do: value

  defp typed_value_text(nil, _type), do: ""
  defp typed_value_text(value, "string"), do: value
  defp typed_value_text(value, _type), do: optional_text(value)

  defp json_text(value), do: Jason.encode!(value)

  defp synced_literal_value(spec, existing, type, true) do
    case {existing["type"], existing["value"], type} do
      {"json", value, target} when target in ["string", "path", "duration"] ->
        value
        |> parse_json()
        |> typed_value_text(target)

      {_existing_type, value, _target} ->
        value || default_argument_value(spec, type)
    end
  end

  defp synced_literal_value(spec, _existing, type, false),
    do: default_argument_value(spec, type)

  defp default_argument_value(spec, type) do
    if Map.has_key?(spec, "default") do
      case type do
        target when target in ["string", "path", "duration"] -> spec["default"] || ""
        _target -> json_text(spec["default"])
      end
    else
      case type do
        _target -> ""
      end
    end
  end

  defp synced_argument_source(existing, true, required?, sensitive?) do
    source = existing["source"] || if(required?, do: "literal", else: "omit")

    cond do
      required? and source == "omit" -> if(sensitive?, do: "input", else: "literal")
      sensitive? and source == "literal" -> "input"
      true -> source
    end
  end

  defp synced_argument_source(_existing, false, true, true), do: "input"
  defp synced_argument_source(_existing, false, true, false), do: "literal"
  defp synced_argument_source(_existing, false, false, _sensitive), do: "omit"

  defp optional_text(nil), do: ""
  defp optional_text(value), do: to_string(value)
  defp bool_string(true), do: "true"
  defp bool_string(_value), do: "false"

  defp maybe_put(map, key, true, value), do: Map.put(map, key, value)
  defp maybe_put(map, _key, false, _value), do: map

  defp maybe_put_nonblank(map, key, value, parse) when is_binary(value) do
    if String.trim(value) == "", do: map, else: Map.put(map, key, parse.(value))
  end

  defp maybe_put_nonblank(map, _key, _value, _parse), do: map
end
