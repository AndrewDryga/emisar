defmodule Emisar.Runbooks.Compiler do
  @moduledoc """
  Deterministic runbook preflight.

  It freezes typed inputs, scoped runner targets, exact trusted packs, common
  action contracts, bindings, and logical items. It has no persistence or
  scheduling behavior.
  """

  alias Emisar.{ActionContract, Catalog, Crypto, JSONValue, Policies, Runners}
  alias Emisar.Auth.Subject
  alias Emisar.Runbooks.Definition

  @type issue :: Definition.issue()

  @doc "Compile one strict definition and typed input object against current trusted facts, using one caller-owned target-selection seed."
  @spec compile(map(), map(), binary(), Subject.t()) ::
          {:ok, map()} | {:error, [issue()]} | {:error, :unauthorized}
  def compile(definition, supplied_inputs, selection_seed, %Subject{} = subject)
      when is_binary(selection_seed) and selection_seed != "" do
    with {:ok, definition} <- Definition.validate(definition),
         {:ok, inputs} <- compile_inputs(definition, supplied_inputs),
         steps = indexed_steps(definition),
         {:ok, target_sets} <- resolve_targets(steps, subject),
         :ok <- validate_fan_out(target_sets),
         :ok <- validate_unsigned_targets(steps, target_sets),
         requests = candidate_requests(steps, target_sets),
         runners = requests |> Enum.map(& &1.runner) |> Enum.uniq_by(& &1.id),
         {:ok, candidates} <- resolve_candidates(requests, runners, subject),
         {:ok, selected} <- select_candidates(steps, target_sets, candidates, selection_seed),
         {:ok, items} <- compile_items(selected, inputs, definition),
         {:ok, items} <- snapshot_policies(items, subject.account.id),
         :ok <- validate_wait_safety(items),
         :ok <- validate_output_correlations(items),
         {:ok, plan} <- build_plan(definition, inputs, items) do
      {:ok,
       %{
         plan: plan,
         items: items,
         inputs_raw: inputs.raw,
         inputs_sha256: inputs.sha256,
         sensitive_input_names: inputs.sensitive_names
       }}
    end
  end

  @doc """
  Validate the current target, trust, pack, action, and signing facts needed
  before exposing a runbook through a model-facing discovery surface.

  Typed input values and bindings remain execution-time concerns.
  """
  @spec validate_availability(map(), Subject.t()) ::
          :ok | {:error, [issue()]} | {:error, :unauthorized}
  def validate_availability(definition, %Subject{} = subject) do
    with {:ok, definition} <- Definition.validate(definition),
         steps = indexed_steps(definition),
         {:ok, target_sets} <- resolve_targets(steps, subject),
         :ok <- validate_fan_out(target_sets),
         :ok <- validate_unsigned_targets(steps, target_sets),
         requests = candidate_requests(steps, target_sets),
         runners = requests |> Enum.map(& &1.runner) |> Enum.uniq_by(& &1.id),
         {:ok, candidates} <- resolve_candidates(requests, runners, subject),
         {:ok, _selected} <- select_candidates(steps, target_sets, candidates, "availability") do
      :ok
    end
  end

  defp resolve_targets(steps, subject) do
    targets = Enum.map(steps, & &1.step["targets"])

    case Runners.resolve_runbook_target_sets(targets, subject) do
      {:ok, target_sets} ->
        {:ok, target_sets}

      {:error, {:unknown_target, index}} ->
        step = Enum.fetch!(steps, index)

        {:error,
         [
           issue(
             "unknown_target",
             "#{step.path}/targets",
             "One or more target refs do not resolve to current in-scope runners."
           )
         ]}

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  defp resolve_candidates(requests, runners, subject) do
    case Catalog.resolve_runbook_candidates(requests, runners, subject) do
      {:error, :candidate_catalog_too_large} ->
        {:error,
         [
           issue(
             "catalog_scope_too_large",
             "/stages",
             "The selected runner deployments exceed the bounded catalog resolution limit."
           )
         ]}

      result ->
        result
    end
  end

  defp compile_inputs(definition, supplied) when is_map(supplied) do
    declarations = Map.new(definition["inputs"], &{&1["id"], &1})
    supplied_names = Map.keys(supplied) |> MapSet.new()
    declared_names = declarations |> Map.keys() |> MapSet.new()

    unknown_issues =
      supplied_names
      |> MapSet.difference(declared_names)
      |> Enum.sort()
      |> Enum.map(
        &issue(
          "invalid_input",
          "/input_values/#{escape(&1)}",
          "Input is not declared by this runbook."
        )
      )

    {values, value_issues} =
      definition["inputs"]
      |> Enum.reduce({%{}, []}, fn declaration, {values, issues} ->
        id = declaration["id"]

        case input_value(declaration, supplied) do
          {:ok, value} ->
            {Map.put(values, id, value), issues}

          :missing ->
            {values, issues}

          {:error, message} ->
            {values, [issue("invalid_input", "/input_values/#{id}", message) | issues]}
        end
      end)

    issues = unknown_issues ++ value_issues

    with [] <- issues,
         :ok <- validate_input_value_shape(values),
         {:ok, raw} <- Jason.encode(values),
         true <- byte_size(raw) <= Definition.limit!(:max_supplied_inputs_bytes) do
      sensitive_names =
        definition["inputs"]
        |> Enum.filter(& &1["sensitive"])
        |> Enum.map(& &1["id"])
        |> Enum.filter(&Map.has_key?(values, &1))
        |> Enum.sort()

      redacted =
        Enum.reduce(sensitive_names, values, &Map.replace!(&2, &1, "[REDACTED]"))

      {:ok,
       %{
         values: values,
         redacted: redacted,
         raw: raw,
         sha256: Crypto.hash_hex(raw),
         sensitive_names: sensitive_names,
         declarations: declarations
       }}
    else
      [_ | _] = issues ->
        {:error, sort_issues(issues)}

      {:error, _reason} ->
        {:error,
         [issue("invalid_input", "/input_values", "Input values exceed the structural budget.")]}

      false ->
        {:error,
         [issue("invalid_input", "/input_values", "Input values exceed the encoded byte limit.")]}
    end
  end

  defp compile_inputs(_definition, _supplied) do
    {:error, [issue("invalid_input", "/input_values", "Input values must be an object.")]}
  end

  defp input_value(declaration, supplied) do
    id = declaration["id"]

    case Map.fetch(supplied, id) do
      {:ok, value} ->
        if valid_input_value?(declaration, value),
          do: {:ok, value},
          else: {:error, "Input does not satisfy its declared type and constraints."}

      :error ->
        cond do
          Map.has_key?(declaration, "default") -> {:ok, declaration["default"]}
          declaration["required"] -> {:error, "Required input is missing."}
          true -> :missing
        end
    end
  end

  defp valid_input_value?(%{"type" => "string"} = declaration, value) when is_binary(value) do
    length = String.length(value)

    within_min?(length, declaration["min_length"]) and
      within_max?(length, declaration["max_length"]) and in_enum?(value, declaration)
  end

  defp valid_input_value?(%{"type" => "integer"} = declaration, value)
       when is_integer(value),
       do: valid_number?(declaration, value)

  defp valid_input_value?(%{"type" => "number"} = declaration, value)
       when is_number(value),
       do: valid_number?(declaration, value)

  defp valid_input_value?(%{"type" => "boolean"} = declaration, value)
       when is_boolean(value),
       do: in_enum?(value, declaration)

  defp valid_input_value?(%{"type" => "enum"} = declaration, value) when is_binary(value),
    do: in_enum?(value, declaration)

  defp valid_input_value?(_declaration, _value), do: false

  defp valid_number?(declaration, value) do
    within_min?(value, declaration["minimum"]) and
      within_max?(value, declaration["maximum"]) and in_enum?(value, declaration)
  end

  defp within_min?(_value, nil), do: true
  defp within_min?(value, minimum), do: value >= minimum
  defp within_max?(_value, nil), do: true
  defp within_max?(value, maximum), do: value <= maximum
  defp in_enum?(_value, %{"enum" => nil}), do: true
  defp in_enum?(value, %{"enum" => enum}), do: value in enum
  defp in_enum?(_value, _declaration), do: true

  defp validate_input_value_shape(values) do
    JSONValue.validate(values,
      max_depth: Definition.limit!(:max_definition_depth),
      max_nodes: Definition.limit!(:max_definition_nodes)
    )
  end

  defp indexed_steps(definition) do
    definition["stages"]
    |> Enum.with_index()
    |> Enum.flat_map(fn {stage, stage_position} ->
      stage["steps"]
      |> Enum.with_index()
      |> Enum.map(fn {step, step_position} ->
        %{
          stage: stage,
          stage_position: stage_position,
          step: step,
          step_position: step_position,
          path: "/stages/#{stage_position}/steps/#{step_position}"
        }
      end)
    end)
  end

  defp validate_fan_out(target_sets) do
    item_count =
      Enum.sum(
        Enum.map(target_sets, fn
          %{selection: "random_one"} -> 1
          %{runners: runners} -> length(runners)
        end)
      )

    if item_count <= Definition.limit!(:max_execution_items) do
      :ok
    else
      {:error,
       [
         issue(
           "fan_out_too_large",
           "/stages",
           "Resolved runbook exceeds the logical execution item limit."
         )
       ]}
    end
  end

  defp validate_unsigned_targets(steps, target_sets) do
    issues =
      steps
      |> Enum.zip(target_sets)
      |> Enum.flat_map(fn {step, target_set} ->
        runners = target_set.runners

        if Enum.any?(runners, & &1.enforce_signatures) do
          [
            issue(
              "signed_runbook_unsupported",
              "#{step.path}/targets",
              "Runbooks cannot dispatch to a signature-enforcing runner."
            )
          ]
        else
          []
        end
      end)

    if issues == [], do: :ok, else: {:error, issues}
  end

  defp candidate_requests(steps, target_sets) do
    steps
    |> Enum.zip(target_sets)
    |> Enum.flat_map(fn {indexed, target_set} ->
      runners = target_set.runners

      Enum.map(runners, fn runner ->
        %{
          runner_id: runner.id,
          runner_ref: runner.runner_ref,
          runner: runner.runner,
          pack_id: indexed.step["pack"]["id"],
          action_id: indexed.step["action"]
        }
      end)
    end)
  end

  defp select_candidates(steps, target_sets, candidates, selection_seed) do
    steps
    |> Enum.zip(target_sets)
    |> Enum.reduce_while({:ok, []}, fn {indexed, target_set}, {:ok, selected_steps} ->
      case select_step_candidates(indexed, target_set, candidates, selection_seed) do
        {:ok, selected} -> {:cont, {:ok, [selected | selected_steps]}}
        {:error, issues} -> {:halt, {:error, issues}}
      end
    end)
    |> case do
      {:ok, selected_steps} -> {:ok, Enum.reverse(selected_steps)}
      {:error, issues} -> {:error, sort_issues(issues)}
    end
  end

  defp select_step_candidates(indexed, target_set, candidates, selection_seed) do
    runners = target_set.runners

    {selected, issues} =
      Enum.reduce(runners, {[], []}, fn runner, {selected, issues} ->
        key = {runner.id, indexed.step["pack"]["id"], indexed.step["action"]}
        available = Map.get(candidates, key, [])

        case select_exact_candidate(available) do
          {:ok, candidate} ->
            {[Map.put(candidate, :runner, runner) | selected], issues}

          {:error, code, message} ->
            {selected, [issue(code, "#{indexed.path}/pack", message) | issues]}
        end
      end)

    with [] <- issues,
         selected <- Enum.reverse(selected),
         :ok <- validate_common_contract(indexed, selected) do
      {:ok,
       %{
         indexed: indexed,
         candidates: select_target_candidates(selected, target_set, indexed, selection_seed),
         target_selection: target_set.selection,
         target_group: target_set.group
       }}
    else
      [_ | _] = issues -> {:error, issues}
      {:error, issues} -> {:error, issues}
    end
  end

  defp select_target_candidates(candidates, %{selection: "all"}, _indexed, _seed),
    do: candidates

  defp select_target_candidates(candidates, %{selection: "random_one"}, indexed, seed) do
    pool_identity = Enum.map_join(candidates, "\0", & &1.runner.runner_ref)
    digest = Crypto.hash_hex(seed <> "\0" <> indexed.path <> "\0" <> pool_identity)
    index = digest |> binary_part(0, 16) |> String.to_integer(16) |> rem(length(candidates))
    [Enum.at(candidates, index)]
  end

  defp select_exact_candidate(candidates) do
    ambiguous? =
      candidates
      |> Enum.group_by(& &1.version, & &1.hash)
      |> Enum.any?(fn {_version, hashes} -> length(Enum.uniq(hashes)) > 1 end)

    cond do
      ambiguous? ->
        {:error, "ambiguous_pack_version", "A compatible pack version has conflicting hashes."}

      candidates == [] ->
        {:error, "pack_unavailable", "This pack and action are not available on the runner."}

      true ->
        {:ok,
         Enum.max_by(
           candidates,
           &Version.parse!(&1.version),
           &(Version.compare(&1, &2) != :lt)
         )}
    end
  end

  defp validate_common_contract(indexed, candidates) do
    contracts = candidates |> Enum.map(&ActionContract.snapshot(&1.descriptor)) |> Enum.uniq()

    if length(contracts) == 1 do
      :ok
    else
      {:error,
       [
         issue(
           "incompatible_action_contracts",
           "#{indexed.path}/action",
           "The selected runners expose incompatible action contracts."
         )
       ]}
    end
  end

  defp compile_items(selected_steps, inputs, definition) do
    output_declarations = output_declarations(definition)

    selected_steps
    |> Enum.reduce_while({:ok, []}, fn selected, {:ok, items} ->
      case compile_step_items(selected, inputs, output_declarations) do
        {:ok, step_items} -> {:cont, {:ok, [step_items | items]}}
        {:error, issues} -> {:halt, {:error, issues}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, items |> Enum.reverse() |> Enum.concat()}
      {:error, issues} -> {:error, sort_issues(issues)}
    end
  end

  defp compile_step_items(selected, inputs, output_declarations) do
    indexed = selected.indexed

    contract =
      selected.candidates
      |> hd()
      |> Map.fetch!(:descriptor)
      |> ActionContract.snapshot()

    arg_specs = get_in(contract, ["args_schema", "args"]) || []
    specs_by_name = Map.new(arg_specs, &{&1["name"], &1})
    binding_names = indexed.step["args"] |> Map.keys() |> MapSet.new()
    known_names = specs_by_name |> Map.keys() |> MapSet.new()

    unknown_issues =
      binding_names
      |> MapSet.difference(known_names)
      |> Enum.sort()
      |> Enum.map(
        &issue(
          "invalid_binding",
          "#{indexed.path}/args/#{escape(&1)}",
          "Binding names an unknown action argument."
        )
      )

    required_issues =
      arg_specs
      |> Enum.filter(
        &(&1["required"] == true and not Map.has_key?(indexed.step["args"], &1["name"]))
      )
      |> Enum.map(
        &issue(
          "invalid_binding",
          "#{indexed.path}/args/#{escape(&1["name"])}",
          "Required action argument has no binding."
        )
      )

    issues =
      unknown_issues ++
        required_issues ++
        binding_contract_issues(
          indexed,
          specs_by_name,
          inputs.declarations,
          output_declarations
        )

    if issues == [] do
      items =
        Enum.map(
          selected.candidates,
          &compile_item(
            selected,
            indexed,
            &1,
            contract,
            specs_by_name,
            inputs,
            output_declarations
          )
        )

      case Enum.flat_map(items, fn
             {:ok, _item} -> []
             {:error, item_issues} -> item_issues
           end) do
        [] -> {:ok, Enum.map(items, fn {:ok, item} -> item end)}
        item_issues -> {:error, item_issues}
      end
    else
      {:error, issues}
    end
  end

  defp binding_contract_issues(indexed, specs, input_declarations, output_declarations) do
    indexed.step["args"]
    |> Enum.flat_map(fn {name, binding} ->
      case Map.get(specs, name) do
        nil ->
          []

        spec ->
          source_sensitive =
            binding_source_sensitive?(binding, input_declarations, output_declarations)

          cond do
            spec["sensitive"] == true and source_sensitive != true ->
              [
                issue(
                  "invalid_binding",
                  "#{indexed.path}/args/#{escape(name)}",
                  "Sensitive action arguments require a sensitive input or output binding."
                )
              ]

            spec["sensitive"] != true and source_sensitive == true ->
              [
                issue(
                  "invalid_binding",
                  "#{indexed.path}/args/#{escape(name)}",
                  "Sensitive values cannot bind to a non-sensitive action argument."
                )
              ]

            not output_binding_type_compatible?(binding, spec, output_declarations) ->
              [
                issue(
                  "invalid_binding",
                  "#{indexed.path}/args/#{escape(name)}",
                  "Output extractor type is incompatible with the action argument."
                )
              ]

            true ->
              []
          end
      end
    end)
  end

  defp binding_source_sensitive?(%{"source" => "literal"}, _inputs, _outputs), do: false

  defp binding_source_sensitive?(%{"source" => "input", "ref" => ref}, inputs, _outputs),
    do: get_in(inputs, [ref, "sensitive"]) == true

  defp binding_source_sensitive?(%{"source" => "output", "ref" => ref}, _inputs, outputs),
    do: get_in(outputs, [ref, "sensitive"]) == true

  defp output_binding_type_compatible?(
         %{"source" => "output", "ref" => ref},
         spec,
         outputs
       ) do
    case get_in(outputs, [ref, "extract", "type"]) do
      "contains" -> spec["type"] == "boolean"
      "grep" -> spec["type"] == "string_array"
      "regex" -> spec["type"] in ["string", "path", "duration"]
      "json_pointer" -> true
    end
  end

  defp output_binding_type_compatible?(_binding, _spec, _outputs), do: true

  defp compile_item(
         selected,
         indexed,
         candidate,
         contract,
         specs,
         inputs,
         _output_declarations
       ) do
    {resolved, deferred_names} =
      Enum.reduce(indexed.step["args"], {%{}, MapSet.new()}, fn
        {name, binding}, {args, deferred_names} ->
          case binding_value(binding, inputs.values) do
            {:ok, value} -> {Map.put(args, name, value), deferred_names}
            :missing -> {args, deferred_names}
            :deferred -> {args, MapSet.put(deferred_names, name)}
          end
      end)

    with :ok <- validate_resolved_bindings(resolved, specs, deferred_names),
         {:ok, args_raw} <- encode_resolved_args(resolved, deferred_names),
         :ok <- validate_args_size(args_raw) do
      sensitive_names =
        specs
        |> Enum.filter(fn {_name, spec} -> spec["sensitive"] == true end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      public_args =
        Enum.reduce(indexed.step["args"], %{}, fn {name, binding}, args ->
          cond do
            binding["source"] == "output" ->
              Map.put(args, name, %{"from_output" => binding["ref"]})

            not Map.has_key?(resolved, name) ->
              args

            name in sensitive_names ->
              Map.put(args, name, "[REDACTED]")

            true ->
              Map.put(args, name, Map.fetch!(resolved, name))
          end
        end)

      {:ok,
       %{
         stage_id: indexed.stage["id"],
         stage_title: indexed.stage["title"],
         stage_position: indexed.stage_position,
         stage_mode: indexed.stage["mode"],
         stage_max_parallel: indexed.stage["max_parallel"] || 1,
         step_id: indexed.step["id"],
         step_position: indexed.step_position,
         runner_id: candidate.runner.id,
         runner_ref: candidate.runner.runner_ref,
         runner_group: candidate.runner.group,
         target_selection: selected.target_selection,
         target_group: selected.target_group,
         action_id: indexed.step["action"],
         pack_id: candidate.pack_id,
         pack_version: candidate.version,
         pack_ref: candidate.pack_ref,
         pack_hash: candidate.hash,
         risk: contract["risk"],
         action_contract: contract,
         contract_digest: ActionContract.digest(contract),
         binding_plan: indexed.step["args"],
         args_raw: args_raw,
         args_sha256: if(args_raw, do: Crypto.hash_hex(args_raw)),
         public_args: public_args,
         sensitive_arg_names: sensitive_names,
         outputs: indexed.step["outputs"],
         success: indexed.step["success"],
         wait: indexed.step["wait"],
         path: indexed.path
       }}
    else
      {:error, %{arg: arg, message: message}} ->
        {:error,
         [
           issue(
             "invalid_binding",
             "#{indexed.path}/args/#{escape(arg)}",
             "Bound action argument #{message}."
           )
         ]}

      {:error, :args_too_large} ->
        {:error,
         [
           issue(
             "invalid_binding",
             "#{indexed.path}/args",
             "Bound action arguments exceed the encoded byte limit."
           )
         ]}
    end
  end

  defp binding_value(%{"source" => "literal", "value" => value}, _inputs), do: {:ok, value}

  defp binding_value(%{"source" => "input", "ref" => ref}, inputs) do
    case Map.fetch(inputs, ref) do
      {:ok, value} -> {:ok, value}
      :error -> :missing
    end
  end

  defp binding_value(%{"source" => "output"}, _inputs), do: :deferred

  defp validate_resolved_bindings(resolved, specs, deferred_names) do
    action_specs =
      Enum.map(specs, fn {name, spec} ->
        if MapSet.member?(deferred_names, name), do: Map.put(spec, "required", false), else: spec
      end)

    ActionContract.validate(resolved, %{"args_schema" => %{"args" => action_specs}})
  end

  defp encode_resolved_args(resolved, deferred_names) do
    if MapSet.size(deferred_names) > 0, do: {:ok, nil}, else: Jason.encode(resolved)
  end

  defp validate_args_size(nil), do: :ok

  defp validate_args_size(raw) do
    if byte_size(raw) <= Definition.limit!(:max_action_args_bytes),
      do: :ok,
      else: {:error, :args_too_large}
  end

  defp output_declarations(definition) do
    definition["stages"]
    |> Enum.flat_map(& &1["steps"])
    |> Enum.flat_map(fn step ->
      Enum.map(step["outputs"], fn output ->
        {"#{step["id"]}.#{output["id"]}", output}
      end)
    end)
    |> Map.new()
  end

  defp validate_output_correlations(items) do
    by_step = Enum.group_by(items, & &1.step_id)

    issues =
      Enum.flat_map(items, fn item ->
        item.binding_plan
        |> Enum.flat_map(fn {name, binding} ->
          output_correlation_issues(item, name, binding, by_step)
        end)
      end)

    if issues == [], do: :ok, else: {:error, sort_issues(issues)}
  end

  defp snapshot_policies(items, account_id) do
    snapshots = Policies.snapshot_runbook_decisions(account_id, items)

    {items, issues} =
      items
      |> Enum.zip(snapshots)
      |> Enum.reduce({[], []}, fn {item, snapshot}, {authorized, issues} ->
        case snapshot do
          %{decision: decision, policy: policy, approval: approval}
          when decision in [:allow, :require_approval] and not is_nil(policy) and
                 approval != :invalid ->
            item =
              Map.merge(item, %{
                policy_id: policy.id,
                policy_version: policy.vsn,
                policy_decision: decision,
                policy_reason: snapshot.reason,
                matched_rules: snapshot.matched_rules,
                approval: approval
              })

            {[item | authorized], issues}

          %{decision: :deny, reason: reason} ->
            issue =
              issue(
                "denied_by_policy",
                "#{item.path}/action",
                "Current policy blocks this action: #{reason}."
              )

            {authorized, [issue | issues]}

          _invalid ->
            issue =
              issue(
                "invalid_policy",
                "#{item.path}/action",
                "The governing policy cannot authorize this action."
              )

            {authorized, [issue | issues]}
        end
      end)

    if issues == [],
      do: {:ok, Enum.reverse(items)},
      else: {:error, sort_issues(issues)}
  end

  defp validate_wait_safety(items) do
    issues =
      items
      |> Enum.filter(&(&1.wait != nil and &1.risk != "low"))
      |> Enum.uniq_by(&{&1.stage_position, &1.step_position})
      |> Enum.map(&wait_safety_issue/1)

    if issues == [], do: :ok, else: {:error, sort_issues(issues)}
  end

  defp wait_safety_issue(item) do
    issue(
      "invalid_definition",
      "#{item.path}/wait",
      "Waits may repeat only low-risk read-only actions."
    )
  end

  defp output_correlation_issues(
         item,
         name,
         %{"source" => "output", "ref" => ref},
         by_step
       ) do
    [producer_step_id, _output_id] = String.split(ref, ".", parts: 2)
    producer_items = Map.fetch!(by_step, producer_step_id)

    correlated =
      case producer_items do
        [_one] -> producer_items
        _many -> Enum.filter(producer_items, &(&1.runner_id == item.runner_id))
      end

    if length(correlated) == 1 do
      []
    else
      [
        issue(
          "ambiguous_output",
          "#{item.path}/args/#{escape(name)}/ref",
          "Output binding does not have exactly one producer for this runner."
        )
      ]
    end
  end

  defp output_correlation_issues(_item, _name, _binding, _by_step), do: []

  defp build_plan(definition, inputs, items) do
    stages =
      definition["stages"]
      |> Enum.with_index()
      |> Enum.map(fn {stage, position} ->
        %{
          "id" => stage["id"],
          "title" => stage["title"],
          "position" => position,
          "mode" => stage["mode"],
          "max_parallel" => stage["max_parallel"] || 1,
          "items" =>
            items
            |> Enum.filter(&(&1.stage_position == position))
            |> Enum.map(&public_item/1)
        }
      end)

    plan = %{
      "schema_version" => 1,
      "inputs" => inputs.redacted,
      "sensitive_input_names" => inputs.sensitive_names,
      "stages" => stages,
      "total_items" => length(items),
      "approval_required" => Enum.any?(items, &(&1.policy_decision == :require_approval)),
      "approval_trigger_count" => Enum.count(items, &(&1.policy_decision == :require_approval))
    }

    with {:ok, encoded} <- Jason.encode(plan),
         true <- byte_size(encoded) <= Definition.limit!(:max_frozen_plan_bytes) do
      {:ok, plan}
    else
      _too_large_or_invalid ->
        {:error,
         [
           issue(
             "fan_out_too_large",
             "/stages",
             "Frozen execution plan exceeds the encoded byte limit."
           )
         ]}
    end
  end

  defp public_item(item) do
    %{
      "step_id" => item.step_id,
      "step_position" => item.step_position,
      "runner_ref" => item.runner_ref,
      "target_selection" => item.target_selection,
      "target_group" => item.target_group,
      "action" => item.action_id,
      "pack_ref" => item.pack_ref,
      "pack_hash" => item.pack_hash,
      "risk" => item.risk,
      "policy" => %{
        "id" => item.policy_id,
        "version" => item.policy_version,
        "decision" => to_string(item.policy_decision),
        "reason" => item.policy_reason,
        "matched_rules" => item.matched_rules
      },
      "contract_digest" => item.contract_digest,
      "args" => item.public_args,
      "outputs" => item.outputs,
      "success" => item.success,
      "wait" => item.wait
    }
  end

  defp sort_issues(issues), do: Enum.sort_by(issues, &{&1.path, &1.code, &1.message})
  defp escape(token), do: token |> String.replace("~", "~0") |> String.replace("/", "~1")
  defp issue(code, path, message), do: %{code: code, path: path, message: message}
end
