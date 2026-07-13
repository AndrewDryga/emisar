defmodule EmisarWeb.MCP.ToolSchema do
  @moduledoc """
  Builds JSON Schema 2020-12 input descriptors for the MCP `/tools`
  endpoint. One descriptor per distinct `action_id`, listing every
  action arg + the universal control fields:

    * `reason` (required) — operator-facing audit string.
    * `runners` (required) — explicit fan-out target list. ALWAYS
      required: emisar never auto-targets, even when exactly one runner
      advertises the action (implicit targeting is a security footgun —
      no audit-visible intent about which host, and it silently
      retargets as the fleet changes).
    * `idempotency_key` (optional) — LLM-controlled at-most-once retry
      (Layer 2). See `EmisarWeb.MCP.Idempotency` for the contract.
    * `wait` (optional) — bounded result wait; omitted defaults to 60s and
      zero is explicit fire-and-forget.

  Emisar's own arg types (`duration`, `string_array`, `integer_array`)
  don't exist in JSON Schema, so we widen to the underlying primitive
  and carry the constraint via `pattern` / `items`. The runner
  re-validates with the original spec on dispatch — the schema is a
  hint to the LLM, not the security gate.
  """

  alias EmisarWeb.MCP.Idempotency

  @max_runner_fan_out 16
  @reserved_arg_names ~w(action_id runner runners reason wait idempotency_key attestation)

  @doc """
  Returns the full `inputSchema` map (already shaped for JSON encoding)
  for one action, given the stable id + display name of each runner that
  advertises it.
  """
  def build(action, runner_targets) do
    args = action_args(action)

    arg_properties = Map.new(args, &{&1["name"], arg_property(&1)})
    arg_required = args |> Enum.filter(& &1["required"]) |> Enum.map(& &1["name"])

    {control_properties, runners_required} = control_properties(runner_targets)

    required =
      ["reason" | arg_required]
      |> then(&if runners_required, do: ["runners" | &1], else: &1)
      |> Enum.uniq()

    schema_object(Map.merge(arg_properties, control_properties), required, false)
  end

  @doc """
  Input schema for an action whose reachable runners advertise DIFFERENT
  argument schemas (e.g. two pack versions). We can't present one accurate
  arg list, so we expose only the universal control fields and allow
  `additionalProperties` — the runner the caller selects re-validates the
  real arguments on dispatch. Fail-closed: never a misleading arg contract.
  """
  def build_ambiguous(runner_targets) do
    {control_properties, runners_required} = control_properties(runner_targets)
    required = if runners_required, do: ["runners", "reason"], else: ["reason"]
    schema_object(control_properties, required, true)
  end

  defp control_properties(runner_targets) do
    {runners_prop, runners_required} = runners_property(normalize_runner_targets(runner_targets))

    properties =
      %{
        "reason" => reason_property(),
        "wait" => wait_property(),
        "idempotency_key" => idempotency_key_property()
      }
      |> put_if_present("runners", runners_prop)

    {properties, runners_required}
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

  # -- Standard control fields -----------------------------------------

  defp reason_property do
    %{
      type: "string",
      description:
        "Why you are running this action — a short freeform sentence. " <>
          "Logged in the audit trail. Required."
    }
  end

  defp wait_property do
    %{
      type: "string",
      pattern: "^[0-9]{1,8}(ms|s|m)?$",
      description:
        "Optional result wait. Use a duration such as `500ms`, `30s`, or `1m`; a bare number " <>
          "means seconds. Values above 60s are capped at 60s. Omit to wait up to 60s for the " <>
          "action result, or set `0` for fire-and-forget and use `wait_for_run` later."
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
      maxLength: Idempotency.max_length(),
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

  # `runners` is ALWAYS required — emisar never auto-targets, even when a
  # single runner advertises the action. Implicit targeting is a footgun:
  # it carries no audit-visible intent about WHICH host the operator meant
  # and silently retargets as the fleet changes. The enum still narrows the
  # choice (one stable id when only one advertises), but selecting it is mandatory —
  # no `default`, no "safe to omit".
  defp runners_property(runner_targets) do
    runner_ids = Enum.map(runner_targets, & &1.id)

    choices =
      Enum.map_join(runner_targets, "\n", fn target ->
        "- `#{target.id}` — #{target.name}"
      end)

    {%{
       type: "array",
       items: %{type: "string", enum: runner_ids},
       minItems: 1,
       maxItems: min(length(runner_ids), @max_runner_fan_out),
       uniqueItems: true,
       description:
         "REQUIRED — select the target runner(s) explicitly; emisar never picks for you. " <>
           "Use one or more stable ids from the `enum`; the labels below identify the hosts. " <>
           "The signed dispatch binds these ids, so the control plane cannot redirect or widen " <>
           "the selected set. The call fans out and each runner runs independently. " <>
           "Each returned run carries its own status — some may succeed immediately " <>
           "while others need approval.\n\nRunner ids:\n" <> choices
     }, true}
  end

  defp normalize_runner_targets(targets) do
    Enum.map(targets, fn
      %{id: id, name: name} -> %{id: id, name: name}
      name when is_binary(name) -> %{id: name, name: name}
    end)
  end

  # -- Per-action arg properties ---------------------------------------

  defp action_args(%{args_schema: %{"args" => args}}) when is_list(args) do
    Enum.filter(args, &valid_arg?/1)
  end

  defp action_args(_), do: []

  defp valid_arg?(%{"name" => name}) when is_binary(name) and name != "",
    do: name not in @reserved_arg_names

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
