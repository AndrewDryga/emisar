defmodule EmisarWeb.MCP.ToolSchema do
  @moduledoc """
  Builds JSON Schema 2020-12 input descriptors for the MCP `/tools`
  endpoint. One descriptor per distinct `action_id`, listing every
  action arg + the universal control fields:

    * `reason` (required) — operator-facing audit string.
    * `runners` (conditional) — fan-out target list; required unless
      exactly one runner advertises the action.
    * `idempotency_key` (optional) — LLM-controlled at-most-once retry
      (Layer 2). See `EmisarWeb.MCP.Idempotency` for the contract.

  Emisar's own arg types (`duration`, `string_array`, `integer_array`)
  don't exist in JSON Schema, so we widen to the underlying primitive
  and carry the constraint via `pattern` / `items`. The runner
  re-validates with the original spec on dispatch — the schema is a
  hint to the LLM, not the security gate.
  """

  @max_runner_fan_out 16

  @doc """
  Returns the full `inputSchema` map (already shaped for JSON encoding)
  for one action, given the list of runner names that advertise it.
  """
  def build(action, runner_names) do
    args = action.args_schema["args"] || []

    arg_properties = Map.new(args, &{&1["name"], arg_property(&1)})
    arg_required = args |> Enum.filter(& &1["required"]) |> Enum.map(& &1["name"])

    {runners_prop, runners_required} = runners_property(runner_names)

    properties =
      arg_properties
      |> Map.put("reason", reason_property())
      |> Map.put("idempotency_key", idempotency_key_property())
      |> put_if_present("runners", runners_prop)

    required =
      ["reason" | arg_required]
      |> then(&if runners_required, do: ["runners" | &1], else: &1)
      |> Enum.uniq()

    %{
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      type: "object",
      properties: properties,
      required: required,
      additionalProperties: false
    }
  end

  # -- Standard control fields -----------------------------------------

  defp reason_property do
    %{
      type: "string",
      description:
        "Why you are running this action — a short freeform sentence. " <>
          "Logged in the audit trail. Required."
    }
  end

  # Exposing this is safe because the asymmetry favors the safer default:
  # omitting it dispatches normally, and the bridge's per-call header
  # still guards transport retries. Setting it only matters on a
  # deliberate re-issue. The description steers the model AWAY from the
  # one dangerous misuse — reusing a key to intentionally run the same
  # thing twice.
  defp idempotency_key_property do
    %{
      type: "string",
      description:
        "Optional. Leave this UNSET for normal calls. Only set it when you are RE-ISSUING " <>
          "a dispatch that may have already gone through (the previous attempt errored, timed " <>
          "out, or returned no run_id) and you want at-most-once execution: reuse the EXACT " <>
          "same string from the prior attempt and the cloud returns the original run instead " <>
          "of dispatching again. A new/different value — or omitting it — always dispatches a " <>
          "fresh run. Never reuse a key to deliberately run the same action a second time."
    }
  end

  defp runners_property([]), do: {nil, false}

  defp runners_property([only]) do
    {%{
       type: "array",
       items: %{type: "string", enum: [only]},
       minItems: 1,
       maxItems: 1,
       default: [only],
       description: "Runners to execute on. Only `#{only}` advertises this action — safe to omit."
     }, false}
  end

  defp runners_property(many) do
    {%{
       type: "array",
       items: %{type: "string", enum: many},
       minItems: 1,
       maxItems: min(length(many), @max_runner_fan_out),
       description:
         "REQUIRED. One or more runner names from the `enum`. " <>
           "The call fans out and each runner runs independently. " <>
           "Pass `[\"runner-1\"]` to target a single host, or " <>
           ~s(`["runner-1","runner-2"]` to run on multiple. ) <>
           "Each returned run carries its own status — some may " <>
           "succeed immediately while others need approval."
     }, true}
  end

  # -- Per-action arg properties ---------------------------------------

  defp arg_property(arg) do
    arg["type"]
    |> base_type()
    |> put_if_present(:description, arg["description"])
    |> put_if_present(:default, arg["default"])
    |> apply_validation(arg["validation"] || %{})
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
    |> put_if_present(:enum, v["enum"] || v["allowed"])
    |> put_if_present(:pattern, v["pattern"])
    |> put_if_present(:minimum, v["min"])
    |> put_if_present(:maximum, v["max"])
    |> put_if_present(:minItems, v["min_items"])
    |> put_if_present(:maxItems, v["max_items"])
  end

  # Single replacement for the 4 prior `maybe_put_*` variants. Empty
  # string / empty list count as "no value", matching Emisar's
  # args_schema convention of omitting empty fields rather than
  # serialising them.
  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, _key, []), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
