defmodule EmisarWeb.RunbookDraft do
  @moduledoc """
  Lossless form state for the structured runbook editor.

  The browser edits strings and ordered rows. `command/1` is the only
  conversion out of that state — into the typed command
  `Emisar.Runbooks.Authoring` canonicalizes — and `from_definition/1` is its
  inverse projection. No source-text definition or alternate persisted shape
  exists.
  """
  alias Emisar.Runbooks

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

  @doc """
  Coerce one browser-supplied scalar into the form text this module owns.

  A crafted request can post a map or list where the form has a text field, so
  a composite value becomes its compact JSON text instead of a raw term.
  """
  def text(nil), do: ""
  def text(value) when is_binary(value), do: value
  def text(value) when is_number(value) or is_atom(value), do: to_string(value)
  def text(value), do: Jason.encode!(value)

  @doc "Project the whole browser draft onto the domain's typed authoring command."
  def command(draft) do
    %{
      context_markdown: text_field(draft, "context_markdown"),
      inputs: Enum.map(rows(draft["inputs"]), &input_command/1),
      stages: Enum.map(rows(draft["stages"]), &stage_command/1)
    }
  end

  @doc "Project one browser argument row onto its typed argument command."
  def argument_command(nil), do: nil

  def argument_command(argument) when is_map(argument) do
    %{
      name: text_field(argument, "name"),
      type: text_field(argument, "type", "json"),
      required?: argument["required"] == "true",
      sensitive?: argument["sensitive"] == "true",
      source: text_field(argument, "source", "omit"),
      value: text_field(argument, "value"),
      ref: text_field(argument, "ref")
    }
  end

  def argument_command(_argument), do: argument_command(argument())

  @doc "Project one typed argument command back onto its browser row."
  def argument_from_command(argument) do
    %{
      "name" => argument.name,
      "type" => argument.type,
      "required" => bool_string(argument.required?),
      "sensitive" => bool_string(argument.sensitive?),
      "source" => argument.source,
      "value" => argument.value,
      "ref" => argument.ref
    }
  end

  def fingerprint(draft) do
    %{
      "title" => draft["title"] || "",
      "slug" => draft["slug"] || "",
      "description" => draft["description"] || "",
      "definition" => draft |> command() |> Runbooks.build_definition_v1()
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

  def enum_value(value \\ "", default? \\ false) do
    %{"value" => value, "default" => bool_string(default?)}
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
      "target_selection" => "all",
      "target_refs" => [],
      "args" => [],
      "outputs" => [],
      "success" => [],
      "wait" => @default_wait,
      "collapsed" => "false"
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

  defp input_command(input) when is_map(input) do
    %{
      id: text_field(input, "id"),
      description: text_field(input, "description"),
      type: text_field(input, "type", "string"),
      required?: input["required"] == "true",
      sensitive?: input["sensitive"] == "true",
      default: text_field(input, "default"),
      enum_values: Enum.map(rows(input["enum_values"]), &enum_value_command/1),
      minimum: text_field(input, "minimum"),
      maximum: text_field(input, "maximum"),
      min_length: text_field(input, "min_length"),
      max_length: text_field(input, "max_length")
    }
  end

  defp input_command(_input), do: input_command(input())

  defp enum_value_command(value) when is_map(value),
    do: %{value: text_field(value, "value"), default?: value["default"] == "true"}

  defp enum_value_command(_value), do: enum_value_command(enum_value())

  defp stage_command(stage) when is_map(stage) do
    %{
      id: text_field(stage, "id"),
      title: text_field(stage, "title"),
      mode: text_field(stage, "mode", "sequential"),
      max_parallel: text_field(stage, "max_parallel"),
      steps: Enum.map(rows(stage["steps"]), &step_command/1)
    }
  end

  defp stage_command(_stage), do: stage_command(stage())

  defp step_command(step) when is_map(step) do
    %{
      id: text_field(step, "id"),
      pack_id: text_field(step, "pack_id"),
      action: text_field(step, "action"),
      target_selection: text_field(step, "target_selection", "all"),
      target_refs: step["target_refs"] |> List.wrap() |> Enum.map(&text/1),
      args: Enum.map(rows(step["args"]), &argument_command/1),
      outputs: Enum.map(rows(step["outputs"]), &output_command/1),
      success: Enum.map(rows(step["success"]), &success_command/1),
      wait: wait_command(step["wait"] || @default_wait)
    }
  end

  defp step_command(_step), do: step_command(step())

  defp output_command(output) when is_map(output) do
    %{
      id: text_field(output, "id"),
      source: text_field(output, "source", "structured_output"),
      sensitive?: output["sensitive"] == "true",
      extract_type: text_field(output, "extract_type", "json_pointer"),
      expression: text_field(output, "expression"),
      capture: text_field(output, "capture", "0")
    }
  end

  defp output_command(_output), do: output_command(output())

  defp success_command(success) when is_map(success) do
    %{
      output: text_field(success, "output"),
      operator: text_field(success, "operator", "equals"),
      value: text_field(success, "value")
    }
  end

  defp success_command(_success), do: success_command(success())

  defp wait_command(wait) when is_map(wait) do
    %{
      enabled?: wait["enabled"] == "true",
      interval_seconds: text_field(wait, "interval_seconds"),
      timeout_seconds: text_field(wait, "timeout_seconds"),
      max_attempts: text_field(wait, "max_attempts")
    }
  end

  defp wait_command(_wait), do: wait_command(@default_wait)

  defp input_from_definition(input) do
    input()
    |> Map.merge(%{
      "id" => input["id"] || "",
      "description" => input["description"] || "",
      "type" => input["type"] || "string",
      "required" => bool_string(input["required"]),
      "sensitive" => bool_string(input["sensitive"]),
      "default" => input_default_text(input),
      "enum_values" => enum_values_from_definition(input),
      "minimum" => text(input["minimum"]),
      "maximum" => text(input["maximum"]),
      "min_length" => text(input["min_length"]),
      "max_length" => text(input["max_length"])
    })
  end

  defp enum_values_from_definition(input) do
    input["enum"]
    |> List.wrap()
    |> Enum.map_reduce(false, fn value, selected? ->
      default? =
        not selected? and Map.has_key?(input, "default") and value == input["default"]

      {enum_value(text(value), default?), selected? or default?}
    end)
    |> elem(0)
  end

  defp stage_from_definition(stage) do
    %{
      "id" => stage["id"] || "",
      "title" => stage["title"] || "",
      "mode" => stage["mode"] || "sequential",
      "max_parallel" => text(stage["max_parallel"] || 1),
      "steps" => Enum.map(stage["steps"] || [], &step_from_definition/1)
    }
  end

  # A step that was already authored opens as a summary, so loading a saved
  # runbook reads as a workflow rather than a wall of controls. The flag rides
  # the row itself so reordering and removal carry it; `command/1` ignores it.
  defp step_from_definition(step) do
    %{
      "collapsed" => "true",
      "id" => step["id"] || "",
      "pack_id" => get_in(step, ["pack", "id"]) || "",
      "action" => step["action"] || "",
      "target_selection" => get_in(step, ["targets", "selection"]) || "all",
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

  defp argument_from_definition({name, %{"source" => "literal", "value" => value}}),
    do: %{loaded_argument(name) | "source" => "literal", "value" => json_text(value)}

  defp argument_from_definition({name, %{"source" => source, "ref" => ref}}),
    do: %{loaded_argument(name) | "source" => source, "ref" => ref || ""}

  defp argument_from_definition({name, _binding}), do: loaded_argument(name)

  # A persisted binding carries no descriptor metadata, so the row must show it
  # missing — that is what makes the catalog restore type/required/sensitive on
  # load. The type stays `json` because the literal text below IS JSON, and the
  # descriptor sync uses that to decode it back to a typed field's plain text.
  defp loaded_argument(name),
    do: %{argument() | "name" => name, "required" => "", "sensitive" => ""}

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

  defp success_from_definition(success) do
    %{
      "output" => success["output"] || "",
      "operator" => success["operator"] || "equals",
      "value" => json_text(success["value"])
    }
  end

  defp wait_from_definition(nil), do: @default_wait

  defp wait_from_definition(wait) do
    %{
      "enabled" => "true",
      "interval_seconds" => text(wait["interval_seconds"]),
      "timeout_seconds" => text(wait["timeout_seconds"]),
      "max_attempts" => text(wait["max_attempts"])
    }
  end

  defp default_context do
    """
    ## Before you run

    - State the evidence that makes this run necessary.
    - Confirm the expected result and rollback boundary.
    """
    |> String.trim()
  end

  defp typed_value_text(nil, _type), do: ""
  defp typed_value_text(value, "string"), do: value
  defp typed_value_text(value, _type), do: text(value)

  defp input_default_text(%{"type" => "enum"}), do: ""
  defp input_default_text(input), do: typed_value_text(input["default"], input["type"])

  defp json_text(value), do: Jason.encode!(value)

  # Every editable scalar reaches the typed command as text, so the domain sees
  # the operator's token and reports its own per-path issue.
  defp text_field(row, key, default \\ "")

  defp text_field(row, key, default) when is_map(row) do
    case row[key] do
      nil -> default
      value -> text(value)
    end
  end

  defp text_field(_row, _key, default), do: default

  defp rows(nil), do: []
  defp rows(values) when is_list(values), do: values
  defp rows(value), do: [value]

  defp bool_string(true), do: "true"
  defp bool_string(_value), do: "false"
end
