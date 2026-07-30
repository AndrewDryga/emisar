defmodule EmisarWeb.RunbookWorkflowComponents do
  @moduledoc false

  use EmisarWeb, :html

  defp target_options("runner", _groups, runner_options, selected),
    do: preserve_selected(runner_options, selected)

  defp target_options(_kind, groups, _runner_options, selected),
    do: preserve_selected(Enum.map(groups, &{&1, &1}), selected)

  defp preserve_selected(options, selected) do
    known = MapSet.new(options, &elem(&1, 1))

    selected =
      Enum.reject(selected, fn value ->
        is_nil(value) or (is_binary(value) and String.trim(value) == "")
      end)

    options ++ for(value <- selected, not MapSet.member?(known, value), do: {value, value})
  end

  defp available_output_refs(draft, stage_index) do
    draft["stages"]
    |> Enum.take(stage_index)
    |> Enum.flat_map(fn stage ->
      Enum.flat_map(stage["steps"], fn step ->
        Enum.map(step["outputs"], &"#{step["id"]}.#{&1["id"]}")
      end)
    end)
    |> Enum.reject(&String.ends_with?(&1, "."))
  end

  defp reference_options("input", draft, _stage_index),
    do: Enum.map(draft["inputs"], &{&1["id"], &1["id"]})

  defp reference_options("output", draft, stage_index),
    do: Enum.map(available_output_refs(draft, stage_index), &{&1, &1})

  defp reference_options(_source, _draft, _stage_index), do: []

  defp step_risk(catalog, step), do: get_in(catalog, [step["action"], :risk])

  defp action_options(catalog, pack_id, selected) do
    options =
      catalog
      |> Enum.filter(fn {_action_id, action} -> Enum.any?(action.packs, &(&1.id == pack_id)) end)
      |> Enum.map(fn {action_id, action} ->
        label = if action.title, do: "#{action.title} · #{action_id}", else: action_id
        {label, action_id}
      end)
      |> Enum.sort()

    preserve_selected(options, List.wrap(selected))
  end

  defp argument_label(argument) do
    suffix = if argument["required"] == "true", do: "", else: " · optional"
    "#{argument["name"]} · #{argument["type"]}#{suffix}"
  end

  defp argument_source_options(%{"sensitive" => "true"}),
    do: [{"Run-time input", "input"}, {"Prior output", "output"}]

  defp argument_source_options(_argument),
    do: [{"Literal", "literal"}, {"Run-time input", "input"}, {"Prior output", "output"}]

  defp pack_options(pack_ids, selected),
    do: pack_ids |> Enum.map(&{&1, &1}) |> preserve_selected(List.wrap(selected))

  defp populated_step?(step) do
    String.trim(step["action"] || "") != "" or step["target_refs"] != [] or step["args"] != [] or
      step["outputs"] != [] or step["success"] != []
  end

  defp populated_stage?(stage), do: Enum.any?(stage["steps"], &populated_step?/1)

  attr :stage, :map, required: true
  attr :stage_index, :integer, required: true
  attr :total_stages, :integer, required: true
  attr :draft, :map, required: true
  attr :catalog, :map, required: true
  attr :pack_ids, :list, required: true
  attr :groups, :list, required: true
  attr :runner_options, :list, required: true
  attr :read_only?, :boolean, required: true

  def stage_editor(assigns) do
    ~H"""
    <article
      id={"runbook-stage-#{@stage_index}"}
      class="rounded-2xl border border-zinc-800 p-5 sm:p-6"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
          Stage {@stage_index + 1}
        </span>
        <div class="flex items-center gap-1">
          <.icon_button
            icon="hero-arrow-up"
            label="Move stage up"
            phx-click="move_stage"
            phx-value-index={@stage_index}
            phx-value-direction="up"
            disabled={@read_only? or @stage_index == 0}
          />
          <.icon_button
            icon="hero-arrow-down"
            label="Move stage down"
            phx-click="move_stage"
            phx-value-index={@stage_index}
            phx-value-direction="down"
            disabled={@read_only? or @stage_index == @total_stages - 1}
          />
          <.icon_button
            icon="hero-trash"
            label="Remove stage"
            phx-click="remove_stage"
            phx-value-index={@stage_index}
            disabled={@read_only?}
            data-confirm={if populated_stage?(@stage), do: "Remove this populated stage?"}
          />
        </div>
      </div>

      <div class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <.input
          name={"draft[stages][#{@stage_index}][title]"}
          value={@stage["title"]}
          label="Title"
          label_variant={:eyebrow}
          disabled={@read_only?}
        />
        <.input
          type="select"
          name={"draft[stages][#{@stage_index}][mode]"}
          value={@stage["mode"]}
          label="Execution"
          label_variant={:eyebrow}
          disabled={@read_only?}
          options={[{"Sequential", "sequential"}, {"Parallel", "parallel"}]}
        />
        <div>
          <.input
            type="number"
            min="1"
            max="16"
            name={"draft[stages][#{@stage_index}][max_parallel]"}
            value={@stage["max_parallel"]}
            label="Max concurrent runs"
            label_variant={:eyebrow}
            disabled={@read_only?}
          />
          <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
            Caps runner fan-out. Sequential mode still keeps step order.
          </p>
        </div>
        <.input
          type="select"
          name={"draft[stages][#{@stage_index}][approval]"}
          value={@stage["approval"]}
          label="Before stage"
          label_variant={:eyebrow}
          disabled={@read_only?}
          options={[{"No stage approval", "none"}, {"Require approval", "required"}]}
        />
      </div>

      <details class="mt-3">
        <summary class="cursor-pointer text-xs font-medium text-zinc-400 hover:text-zinc-200">
          Stage identifier
        </summary>
        <div class="mt-3 max-w-sm">
          <.input
            name={"draft[stages][#{@stage_index}][id]"}
            value={@stage["id"]}
            label="Stage ID"
            label_variant={:eyebrow}
            disabled={@read_only?}
            class="font-mono text-xs"
          />
        </div>
      </details>

      <div class="mt-6 space-y-4">
        <.step_editor
          :for={{step, step_index} <- Enum.with_index(@stage["steps"])}
          step={step}
          step_index={step_index}
          total_steps={length(@stage["steps"])}
          stage_index={@stage_index}
          draft={@draft}
          catalog={@catalog}
          pack_ids={@pack_ids}
          groups={@groups}
          runner_options={@runner_options}
          read_only?={@read_only?}
        />
      </div>

      <.add_row
        label="Add step"
        class="mt-6"
        phx-click="add_step"
        phx-value-stage={@stage_index}
        disabled={@read_only?}
      />
    </article>
    """
  end

  attr :step, :map, required: true
  attr :step_index, :integer, required: true
  attr :total_steps, :integer, required: true
  attr :stage_index, :integer, required: true
  attr :draft, :map, required: true
  attr :catalog, :map, required: true
  attr :pack_ids, :list, required: true
  attr :groups, :list, required: true
  attr :runner_options, :list, required: true
  attr :read_only?, :boolean, required: true

  defp step_editor(assigns) do
    assigns =
      assigns
      |> assign(:risk, step_risk(assigns.catalog, assigns.step))
      |> assign(
        :targets,
        target_options(
          assigns.step["target_kind"],
          assigns.groups,
          assigns.runner_options,
          assigns.step["target_refs"]
        )
      )
      |> assign(
        :pack_options,
        pack_options(assigns.pack_ids, assigns.step["pack_id"])
      )
      |> assign(
        :action_options,
        action_options(assigns.catalog, assigns.step["pack_id"], assigns.step["action"])
      )

    ~H"""
    <section
      id={"runbook-stage-#{@stage_index}-step-#{@step_index}"}
      class="rounded-xl border border-dashed border-zinc-800 p-5"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
            Step {@step_index + 1}
          </span>
          <.risk_pill :if={@risk} risk={@risk} />
        </div>
        <div class="flex items-center gap-1">
          <.icon_button
            icon="hero-arrow-up"
            label="Move step up"
            phx-click="move_step"
            phx-value-stage={@stage_index}
            phx-value-step={@step_index}
            phx-value-direction="up"
            disabled={@read_only? or @step_index == 0}
          />
          <.icon_button
            icon="hero-arrow-down"
            label="Move step down"
            phx-click="move_step"
            phx-value-stage={@stage_index}
            phx-value-step={@step_index}
            phx-value-direction="down"
            disabled={@read_only? or @step_index == @total_steps - 1}
          />
          <.icon_button
            icon="hero-trash"
            label="Remove step"
            phx-click="remove_step"
            phx-value-stage={@stage_index}
            phx-value-step={@step_index}
            disabled={@read_only?}
            data-confirm={if populated_step?(@step), do: "Remove this populated step?"}
          />
        </div>
      </div>

      <div class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        <.input
          type="select"
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][pack_id]"}
          value={@step["pack_id"]}
          label="Pack"
          label_variant={:eyebrow}
          disabled={@read_only?}
          options={@pack_options}
          prompt="Choose pack"
        />
        <div class="sm:col-span-2">
          <.input
            type="select"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][action]"}
            value={@step["action"]}
            label="Action"
            label_variant={:eyebrow}
            disabled={@read_only? or @step["pack_id"] == ""}
            options={@action_options}
            prompt="Choose action"
            class="font-mono text-xs"
          />
        </div>
        <.input
          type="select"
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][target_kind]"}
          value={@step["target_kind"]}
          label="Target by"
          label_variant={:eyebrow}
          disabled={@read_only?}
          options={[{"Runner group", "group"}, {"Exact runner", "runner"}]}
        />
        <div class="sm:col-span-2">
          <.label variant={:eyebrow}>Targets</.label>
          <.checkbox_list
            id={"stage-#{@stage_index}-step-#{@step_index}-targets"}
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][target_refs][]"}
            options={
              Enum.map(@targets, fn {label, value} ->
                %{
                  label: label,
                  value: value,
                  selected: value in @step["target_refs"],
                  disabled: @read_only?
                }
              end)
            }
            class="mt-1"
          />
          <p :if={@targets == []} class="mt-1 text-[11px] text-zinc-400">
            No matching runners are currently visible.
          </p>
        </div>
      </div>

      <details class="mt-4">
        <summary class="cursor-pointer text-xs font-medium text-zinc-400 hover:text-zinc-200">
          Version and identifiers
        </summary>
        <div class="mt-3 grid gap-3 sm:grid-cols-2">
          <.input
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][id]"}
            value={@step["id"]}
            label="Step ID"
            label_variant={:eyebrow}
            disabled={@read_only?}
            class="font-mono text-xs"
          />
          <div>
            <.input
              name={"draft[stages][#{@stage_index}][steps][#{@step_index}][pack_requirement]"}
              value={@step["pack_requirement"]}
              label="Version requirement"
              label_variant={:eyebrow}
              disabled={@read_only?}
              class="font-mono text-xs"
              placeholder="~> 1.4.0"
            />
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
              Examples: <code>== 1.4.2</code>, <code>~&gt; 1.4.0</code>, or <code>&gt;= 1.4.0 and &lt; 2.0.0</code>.
            </p>
          </div>
        </div>
      </details>

      <.bindings_editor
        step={@step}
        stage_index={@stage_index}
        step_index={@step_index}
        draft={@draft}
        read_only?={@read_only?}
      />
      <.outputs_editor
        step={@step}
        stage_index={@stage_index}
        step_index={@step_index}
        read_only?={@read_only?}
      />
      <.success_editor
        step={@step}
        stage_index={@stage_index}
        step_index={@step_index}
        read_only?={@read_only?}
      />
      <.wait_editor
        wait={@step["wait"]}
        stage_index={@stage_index}
        step_index={@step_index}
        read_only?={@read_only?}
      />
    </section>
    """
  end

  attr :step, :map, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :draft, :map, required: true
  attr :read_only?, :boolean, required: true

  defp bindings_editor(assigns) do
    ~H"""
    <div class="mt-6 border-t border-zinc-800/70 pt-5">
      <div class="flex items-center justify-between gap-3">
        <div>
          <p class="text-xs font-semibold text-zinc-200">Arguments and bindings</p>
          <p class="mt-0.5 text-[11px] text-zinc-400">
            Bind a whole literal, run-time input, or earlier-stage output.
          </p>
        </div>
      </div>

      <p :if={@step["action"] == ""} class="mt-3 text-xs text-zinc-500">
        Choose an action to configure its arguments.
      </p>

      <p :if={@step["action"] != "" and @step["args"] == []} class="mt-3 text-xs text-zinc-500">
        This action has no arguments.
      </p>

      <div class="mt-3 space-y-3">
        <div
          :for={{argument, index} <- Enum.with_index(@step["args"])}
          class="rounded-lg border border-zinc-800/70 p-3"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <p class="font-mono text-xs font-medium text-zinc-200">
              {argument_label(argument)}
            </p>
            <.input
              :if={argument["required"] != "true"}
              type="select"
              size={:compact}
              name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][enabled]"}
              value={argument["enabled"]}
              aria-label={"Use optional argument #{argument["name"]}"}
              disabled={@read_only?}
              options={[{"Not used", "false"}, {"Use", "true"}]}
            />
          </div>

          <input
            type="hidden"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][name]"}
            value={argument["name"]}
          />
          <input
            type="hidden"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][type]"}
            value={argument["type"]}
          />
          <input
            type="hidden"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][required]"}
            value={argument["required"]}
          />
          <input
            type="hidden"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][sensitive]"}
            value={argument["sensitive"]}
          />
          <input
            :if={argument["required"] == "true"}
            type="hidden"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][enabled]"}
            value="true"
          />

          <div
            :if={argument["enabled"] == "true"}
            class="mt-3 grid gap-2 sm:grid-cols-[10rem_minmax(0,1fr)]"
          >
            <.input
              type="select"
              name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][source]"}
              value={argument["source"]}
              aria-label={"#{argument["name"]} binding source"}
              disabled={@read_only?}
              options={argument_source_options(argument)}
            />
            <.argument_value_input
              argument={argument}
              index={index}
              stage_index={@stage_index}
              step_index={@step_index}
              draft={@draft}
              read_only?={@read_only?}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :argument, :map, required: true
  attr :index, :integer, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :draft, :map, required: true
  attr :read_only?, :boolean, required: true

  defp argument_value_input(assigns) do
    name =
      "draft[stages][#{assigns.stage_index}][steps][#{assigns.step_index}]" <>
        "[args][#{assigns.index}]"

    assigns = assign(assigns, :name, name)

    ~H"""
    <div>
      <input
        :if={@argument["source"] != "literal"}
        type="hidden"
        name={"#{@name}[value]"}
        value={@argument["value"]}
      />
      <input
        :if={@argument["source"] == "literal"}
        type="hidden"
        name={"#{@name}[ref]"}
        value={@argument["ref"]}
      />

      <.input
        :if={@argument["source"] == "literal" and @argument["type"] == "boolean"}
        type="select"
        name={"#{@name}[value]"}
        value={@argument["value"]}
        aria-label={"#{@argument["name"]} literal value"}
        disabled={@read_only?}
        options={[{"False", "false"}, {"True", "true"}]}
      />
      <.input
        :if={@argument["source"] == "literal" and @argument["type"] in ["integer", "number"]}
        type="number"
        step={if @argument["type"] == "number", do: "any", else: "1"}
        name={"#{@name}[value]"}
        value={@argument["value"]}
        aria-label={"#{@argument["name"]} literal value"}
        disabled={@read_only?}
      />
      <.input
        :if={
          @argument["source"] == "literal" and
            @argument["type"] not in ["boolean", "integer", "number"]
        }
        name={"#{@name}[value]"}
        value={@argument["value"]}
        aria-label={"#{@argument["name"]} literal value"}
        placeholder={
          if @argument["type"] in ["string_array", "integer_array"],
            do: "JSON array",
            else: "Value"
        }
        disabled={@read_only?}
        class={if @argument["type"] in ["string_array", "integer_array"], do: "font-mono text-xs"}
      />
      <.input
        :if={@argument["source"] != "literal"}
        type="select"
        name={"#{@name}[ref]"}
        value={@argument["ref"]}
        aria-label={"#{@argument["name"]} reference"}
        disabled={@read_only?}
        options={reference_options(@argument["source"], @draft, @stage_index)}
        prompt="Choose value"
      />
    </div>
    """
  end

  attr :step, :map, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :read_only?, :boolean, required: true

  defp outputs_editor(assigns) do
    ~H"""
    <div class="mt-6 border-t border-zinc-800/70 pt-5">
      <div class="flex items-center justify-between gap-3">
        <div>
          <p class="text-xs font-semibold text-zinc-200">Extracted outputs</p>
          <p class="mt-0.5 text-[11px] text-zinc-400">
            JSON Pointer, contains, grep, or bounded regex.
          </p>
        </div>
        <.button
          type="button"
          variant={:secondary}
          size={:sm}
          icon="hero-plus"
          phx-click="add_output"
          phx-value-stage={@stage_index}
          phx-value-step={@step_index}
          disabled={@read_only?}
        >
          Add
        </.button>
      </div>

      <div class="mt-3 space-y-4">
        <div
          :for={{output, index} <- Enum.with_index(@step["outputs"])}
          class="grid gap-2 sm:grid-cols-2 xl:grid-cols-6"
        >
          <.input
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][id]"}
            value={output["id"]}
            label="Output ID"
            label_variant={:eyebrow}
            aria-label={"Output #{index + 1} ID"}
            placeholder="output_id"
            disabled={@read_only?}
            class="font-mono text-xs"
          />
          <.input
            type="select"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][source]"}
            value={output["source"]}
            label="Read from"
            label_variant={:eyebrow}
            aria-label={"Output #{index + 1} source"}
            disabled={@read_only?}
            options={[
              {"Structured output", "structured_output"},
              {"stdout", "stdout"},
              {"stderr", "stderr"}
            ]}
          />
          <.input
            type="select"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][extract_type]"}
            value={output["extract_type"]}
            label="Extract with"
            label_variant={:eyebrow}
            aria-label={"Output #{index + 1} extractor"}
            disabled={@read_only?}
            options={[
              {"JSON Pointer", "json_pointer"},
              {"Contains", "contains"},
              {"Grep", "grep"},
              {"Regex", "regex"}
            ]}
          />
          <.input
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][expression]"}
            value={output["expression"]}
            label="Expression"
            label_variant={:eyebrow}
            aria-label={"Output #{index + 1} expression"}
            placeholder={if output["extract_type"] == "json_pointer", do: "/status", else: "pattern"}
            disabled={@read_only?}
            class="font-mono text-xs xl:col-span-2"
          />
          <div class="flex items-center gap-2">
            <.input
              :if={output["extract_type"] == "regex"}
              name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][capture]"}
              value={output["capture"]}
              label="Capture"
              label_variant={:eyebrow}
              aria-label={"Output #{index + 1} regex capture"}
              placeholder="0"
              disabled={@read_only?}
              class="font-mono text-xs"
            />
            <.input
              type="select"
              name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][sensitive]"}
              value={output["sensitive"]}
              label="Visibility"
              label_variant={:eyebrow}
              aria-label={"Output #{index + 1} sensitivity"}
              disabled={@read_only?}
              options={[{"Visible", "false"}, {"Sensitive", "true"}]}
            />
            <.icon_button
              icon="hero-trash"
              label="Remove output"
              phx-click="remove_output"
              phx-value-stage={@stage_index}
              phx-value-step={@step_index}
              phx-value-index={index}
              disabled={@read_only?}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :read_only?, :boolean, required: true

  defp success_editor(assigns) do
    ~H"""
    <div class="mt-6 border-t border-zinc-800/70 pt-5">
      <div class="flex items-center justify-between gap-3">
        <div>
          <p class="text-xs font-semibold text-zinc-200">Success conditions</p>
          <p class="mt-0.5 text-[11px] text-zinc-400">
            All conditions must pass. Conditions read only extracted outputs.
          </p>
        </div>
        <.button
          type="button"
          variant={:secondary}
          size={:sm}
          icon="hero-plus"
          phx-click="add_success"
          phx-value-stage={@stage_index}
          phx-value-step={@step_index}
          disabled={@read_only?}
        >
          Add
        </.button>
      </div>

      <div class="mt-3 space-y-3">
        <div
          :for={{condition, index} <- Enum.with_index(@step["success"])}
          class="grid gap-2 sm:grid-cols-[1fr_12rem_1fr_auto]"
        >
          <.input
            type="select"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][success][#{index}][output]"}
            value={condition["output"]}
            label="Output"
            label_variant={:eyebrow}
            aria-label={"Condition #{index + 1} output"}
            disabled={@read_only?}
            options={Enum.map(@step["outputs"], &{&1["id"], &1["id"]})}
          />
          <.input
            type="select"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][success][#{index}][operator]"}
            value={condition["operator"]}
            label="Must be"
            label_variant={:eyebrow}
            aria-label={"Condition #{index + 1} operator"}
            disabled={@read_only?}
            options={[
              {"Equals", "equals"},
              {"Not equal", "not_equals"},
              {"Greater than", "greater_than"},
              {"Greater than or equal", "greater_than_or_equal"},
              {"Less than", "less_than"},
              {"Less than or equal", "less_than_or_equal"},
              {"Contains", "contains"},
              {"One of", "one_of"},
              {"Matches regex", "matches"}
            ]}
          />
          <.input
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][success][#{index}][value]"}
            value={condition["value"]}
            label="Value"
            label_variant={:eyebrow}
            aria-label={"Condition #{index + 1} JSON value"}
            placeholder="JSON value"
            disabled={@read_only?}
            class="font-mono text-xs"
          />
          <.icon_button
            icon="hero-trash"
            label="Remove condition"
            phx-click="remove_success"
            phx-value-stage={@stage_index}
            phx-value-step={@step_index}
            phx-value-index={index}
            disabled={@read_only?}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :wait, :map, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :read_only?, :boolean, required: true

  defp wait_editor(assigns) do
    ~H"""
    <div class="mt-6 border-t border-zinc-800/70 pt-5">
      <div class="grid gap-3 sm:grid-cols-4">
        <.input
          type="select"
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][wait][enabled]"}
          value={@wait["enabled"]}
          label="When conditions do not pass"
          label_variant={:eyebrow}
          disabled={@read_only?}
          options={[{"Fail the item", "false"}, {"Wait and observe again", "true"}]}
          class="sm:col-span-4"
        />
        <.input
          :if={@wait["enabled"] == "true"}
          type="number"
          min="5"
          max="3600"
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][wait][interval_seconds]"}
          value={@wait["interval_seconds"]}
          label="Interval (seconds)"
          label_variant={:eyebrow}
          disabled={@read_only?}
        />
        <.input
          :if={@wait["enabled"] == "true"}
          type="number"
          min="5"
          max="86400"
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][wait][timeout_seconds]"}
          value={@wait["timeout_seconds"]}
          label="Timeout (seconds)"
          label_variant={:eyebrow}
          disabled={@read_only?}
        />
        <.input
          :if={@wait["enabled"] == "true"}
          type="number"
          min="2"
          max="100"
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][wait][max_attempts]"}
          value={@wait["max_attempts"]}
          label="Maximum observations"
          label_variant={:eyebrow}
          disabled={@read_only?}
        />
      </div>
    </div>
    """
  end
end
